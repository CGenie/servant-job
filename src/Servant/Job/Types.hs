{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
module Servant.Job.Types where

import Control.Applicative
import Control.Concurrent.Chan
import Control.Concurrent.MVar (MVar)
import Control.Lens
import Control.Exception
import Data.Aeson
import qualified Data.HashMap.Strict as H
import Data.Set (Set)
import Data.Swagger hiding (url, URL)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics hiding (to)
import Network.HTTP.Client hiding (Proxy, path)
import Prelude hiding (log)
import Servant
import Servant.API.Flatten
import Servant.Job.Core as Core
import Servant.Job.Utils (jsonOptions, swaggerOptions, (</>))
import Servant.Client hiding (manager, ClientEnv)
import Web.FormUrlEncoded

data JobServerAPI = Sync | Async | Callback
  deriving (Eq, Ord, Generic)

instance ToJSON JobServerAPI

instance FromHttpApiData JobServerAPI where
  parseUrlPiece "sync"     = pure Sync
  parseUrlPiece "async"    = pure Async
  parseUrlPiece "callback" = pure Callback
  parseUrlPiece _          = Left "Unexpected value of type JobServerAPI. Expecting sync, async, or stream"

instance ToHttpApiData JobServerAPI where
  toUrlPiece Sync     = "sync"
  toUrlPiece Async    = "async"
  toUrlPiece Callback = "callback"

-----------
--- URL ---
-----------

newtype URL = URL { _base_url :: BaseUrl } deriving (Eq, Ord)

makeLenses ''URL

instance ToJSON URL where
  toJSON url = toJSON (showBaseUrl (url ^. base_url))

instance FromJSON URL where
  parseJSON = withText "URL" $ \t ->
    either (fail . displayException) (pure . URL) $ parseBaseUrl (T.unpack t)

instance FromHttpApiData URL where
  parseUrlPiece t =
    parseBaseUrl (T.unpack t) & _Left  %~ T.pack . displayException
                              & _Right %~ URL

instance ToHttpApiData URL where
  toUrlPiece = toUrlPiece . showBaseUrl . _base_url

mkURL :: BaseUrl -> String -> URL
mkURL url path = URL $ url { baseUrlPath = baseUrlPath url </> path }

data JobServerURL e i o = JobServerURL
  { _job_server_url :: !URL
  , _job_server_api :: !JobServerAPI
  }
  deriving (Eq, Ord, Generic)

makeLenses ''JobServerURL

instance ToJSON (JobServerURL e i o) where
  toJSON = genericToJSON $ jsonOptions "_job_server_"

data JobInput a = JobInput
  { _job_input    :: !a
  , _job_callback :: !(Maybe URL)
  }
  deriving Generic

makeLenses ''JobInput

instance ToJSON i => ToJSON (JobInput i) where
  toJSON = genericToJSON $ jsonOptions "_job_"

instance FromJSON i => FromJSON (JobInput i) where
  parseJSON v =  genericParseJSON (jsonOptions "_job_") v
             <|> JobInput <$> parseJSON v <*> pure Nothing

instance ToForm i => ToForm (JobInput i) where
  toForm i =
    Form . H.insert "callback" (i ^.. job_callback . to toUrlPiece)
         $ unForm (toForm (i ^. job_input))

instance FromForm i => FromForm (JobInput i) where
  fromForm f =
    JobInput <$> fromForm (Form (H.delete "input" (unForm f)))
             <*> parseMaybe "callback" f

newtype JobOutput a = JobOutput
  { _job_output :: a }
  deriving Generic

makeLenses ''JobOutput

instance ToJSON o => ToJSON (JobOutput o) where
  toJSON = genericToJSON $ jsonOptions "_job_"

instance FromJSON o => FromJSON (JobOutput o) where
  parseJSON = genericParseJSON $ jsonOptions "_job_"

type JobID safety = ID safety "job"

data JobStatus safety e = JobStatus
  { _job_id     :: !(JobID safety)
  , _job_log    :: ![e]
  , _job_status :: !Text -- TODO: should be a type Started | Finished ...
  }
  deriving Generic

newtype Limit  = Limit  { unLimit  :: Int } deriving (ToHttpApiData, FromHttpApiData)
newtype Offset = Offset { unOffset :: Int } deriving (ToHttpApiData, FromHttpApiData)

type JobStatusAPI meth safetyO e =
  QueryParam "limit"  Limit  :>
  QueryParam "offset" Offset :>
  meth '[JSON] (JobStatus safetyO e)

type AsyncJobAPI' safetyO ctO e o
    =  "kill" :> JobStatusAPI Post safetyO e
  :<|> "poll" :> JobStatusAPI Get  safetyO e
  :<|> "wait" :> Get ctO (JobOutput o)

type AsyncJobsAPI' safetyI safetyO ctI ctO e i o
    =  ReqBody ctI (JobInput i)     :> Post '[JSON] (JobStatus safetyO e)
  :<|> Capture "id" (JobID safetyI) :> AsyncJobAPI' safetyO ctO e o

type AsyncJobAPI event output = AsyncJobAPI' 'Safe '[JSON] event output

type AsyncJobsAPI event input output = Flat (AsyncJobsAPI' 'Unsafe 'Safe '[JSON] '[JSON] event input output)

type AsyncJobsServer' ctI ctO e i o =
  Server (Flat (AsyncJobsAPI' 'Unsafe 'Safe ctI ctO e i o))

type AsyncJobsServer e i o = AsyncJobsServer' '[JSON] '[JSON] e i o

makeLenses ''JobStatus

instance (safety ~ 'Safe, ToJSON e) => ToJSON (JobStatus safety e) where
  toJSON = genericToJSON $ jsonOptions "_job_"

instance (safety ~ 'Unsafe, FromJSON e) => FromJSON (JobStatus safety e) where
  parseJSON = genericParseJSON $ jsonOptions "_job_"

instance ToSchema e => ToSchema (JobStatus safety e) where
  declareNamedSchema = genericDeclareNamedSchema $ swaggerOptions "_job_"

data JobFrame e o = JobFrame
  { _job_frame_event  :: Maybe e
  , _job_frame_output :: Maybe o
  }
  deriving (Generic)

instance (FromJSON e, FromJSON o) => FromJSON (JobFrame e o) where
  parseJSON = genericParseJSON $ jsonOptions "_job_frame_"

instance (ToJSON e, ToJSON o) => ToJSON (JobFrame e o) where
  toJSON = genericToJSON $ jsonOptions "_job_frame_"

data ClientOrServer = Client | Server

type family StreamFunctor (c :: ClientOrServer) :: * -> *
type instance StreamFunctor 'Client = ResultStream
type instance StreamFunctor 'Server = StreamGenerator

type StreamJobsAPI' f ctI ctO e i o =
  ReqBody ctI i :>
      StreamPost NewlineFraming ctO (f (JobFrame e o))

type StreamJobsAPI c e i o =
  StreamJobsAPI' (StreamFunctor c) '[JSON, FormUrlEncoded] JSON e i o

type SyncJobsAPI' f ctI ctO e i o =
  QueryFlag "stream" :> StreamJobsAPI' f ctI ctO e i o
-- Post '[ctO] (JobOutput o)

type SyncJobsAPI c e i o = SyncJobsAPI' (StreamFunctor c) '[JSON] JSON e i o

syncJobsAPIClient :: proxy e i o -> Proxy (SyncJobsAPI 'Client e i o)
syncJobsAPIClient _ = Proxy

type ChanID safety = ID safety "chan"

type CallbackAPI e o
    =  "event"  :> ReqBody '[JSON] e :> Post '[JSON] ()
  :<|> "error"  :> ReqBody '[JSON] String :> Post '[JSON] ()
  :<|> "output" :> ReqBody '[JSON] o :> Post '[JSON] ()

newtype AnyEvent  = AnyEvent  Value
  deriving (FromJSON, ToJSON)
newtype AnyInput  = AnyInput  Value
  deriving (FromJSON, ToJSON)
newtype AnyOutput = AnyOutput Value
  deriving (FromJSON, ToJSON)

type CallbacksAPI = Capture "id" (ChanID 'Unsafe) :> CallbackAPI AnyEvent AnyOutput

type CallbacksServer = Server (Flat CallbacksAPI)

-- This is internally almost equivalent to JobInput
-- in JobInput the callback is optional.
data CallbackInput e i o = CallbackInput
  { _cbi_input    :: !i
  , _cbi_callback :: !URL
  } deriving (Generic)

makeLenses ''CallbackInput

instance FromJSON i => FromJSON (CallbackInput e i o) where
  parseJSON = genericParseJSON $ jsonOptions "_cbi_"

instance ToJSON i => ToJSON (CallbackInput e i o) where
  toJSON = genericToJSON $ jsonOptions "_cbi_"

instance ToForm i => ToForm (CallbackInput e i o) where
  toForm cbi =
    Form . H.insert "callback" (cbi ^.. cbi_callback . to toUrlPiece)
         $ unForm (toForm (cbi ^. cbi_input))

instance FromForm i => FromForm (CallbackInput e i o) where
  fromForm f =
    CallbackInput
      <$> fromForm (Form (H.delete "callback" (unForm f)))
      <*> parseUnique "callback" f

type CallbackJobsAPI' ctI ctO e i o =
  ReqBody ctI (CallbackInput e i o) :> Post ctO ()

type CallbackJobsAPI e i o =
  CallbackJobsAPI' '[JSON, FormUrlEncoded] '[JSON] e i o

type family   JobsAPI' (sas :: JobServerAPI)
                       (cs  :: ClientOrServer)
                       (ctI :: [*]) ctO e i o
type instance JobsAPI' 'Sync     cs ctI ctO e i o = SyncJobsAPI' (StreamFunctor cs) ctI ctO e i o
type instance JobsAPI' 'Async    _  ctI ctO e i o = AsyncJobsAPI' 'Unsafe 'Safe ctI '[ctO] e i o
type instance JobsAPI' 'Callback _  ctI ctO e i o = CallbackJobsAPI' ctI '[ctO] e i o

type JobsAPI sas cs ctI ctO e i o = Flat (JobsAPI' sas cs ctI ctO e i o)

data ChanMessage e i o = ChanMessage
  { _msg_event  :: !(Maybe e)
  , _msg_result :: !(Maybe o)
  , _msg_error  :: !(Maybe String)
  }
  deriving (Generic)

makeLenses ''ChanMessage

{-
_ChanEvent  :: Prism' (ChanMessage e i o) e
_ChanEvent =
_ChanResult :: Prism' (ChanMessage e i o) o
_ChanResult =
_ChanError  :: Prism' (ChanMessage e i o) String
_ChanError =
-}
mkChanEvent  :: e -> ChanMessage e i o
mkChanEvent e = ChanMessage (Just e) Nothing Nothing
mkChanResult :: o -> ChanMessage e i o
mkChanResult o = ChanMessage Nothing (Just o) Nothing
mkChanError  :: String -> ChanMessage e i o
mkChanError m = ChanMessage Nothing Nothing (Just m)

instance (ToJSON e, ToJSON o) => ToJSON (ChanMessage e i o) where
  toJSON = genericToJSON $ jsonOptions "_msg_"

instance (FromJSON e, FromJSON o) => FromJSON (ChanMessage e i o) where
  parseJSON = genericParseJSON $ jsonOptions "_msg_"

type instance SymbolOf (Chan Value) = "chan"

type ChansEnv = Core.Env (Chan Value)

data Chans = Chans
  { _chans_env :: !ChansEnv
  , _chans_url :: !URL
  }

makeLenses ''Chans

data RunningJob e i o = PrivateRunningJob
  { _running_job_url :: URL
  , _running_job_api :: JobServerAPI
  , _running_job_id  :: JobID 'Unsafe
  }
  deriving (Eq, Ord, Generic)

makeLenses ''RunningJob

data Event e i o
  = NewTask  { _event_server :: JobServerURL e i o }
  | Started  { _event_server :: JobServerURL e i o
             , _event_job_id :: Maybe (JobID 'Unsafe) }
  | Finished { _event_server :: JobServerURL e i o
             , _event_job_id :: Maybe (JobID 'Unsafe) }
  | Event    { _event_server :: JobServerURL e i o
             , _event_job_id :: Maybe (JobID 'Unsafe)
             , _event_event  :: e }
  | BadEvent { _event_server :: JobServerURL e i o
             , _event_job_id :: Maybe (JobID 'Unsafe)
             , _event_event_value :: Value }
  | Debug e
  deriving (Generic)

instance ToJSON e => ToJSON (Event e i o) where
  toJSON = genericToJSON $ jsonOptions "_event_"

newtype LogEvent = LogEvent
  { unLogEvent :: forall e i o. ToJSON e => Event e i o -> IO () }

data ClientEnv = ClientEnv
  { _cenv_manager          :: !Manager
  , _cenv_polling_delay_ms :: !Int
  , _cenv_log_event        :: !LogEvent
  , _cenv_jobs_mvar        :: !(MVar (Set (RunningJob Value Value Value)))
  , _cenv_chans            :: !Chans
  }

makeLenses ''ClientEnv