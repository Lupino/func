{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Data.Default.Class              (def)
import           Data.Streaming.Network.Internal (HostPreference (Host))
import           Network.HTTP.Types              (status404, status500)
import           Network.Wai.Handler.Warp        (setHost, setPort)
import           Web.Scotty                      (ActionM, ScottyM, body, param,
                                                  post, raw, scottyOpts,
                                                  setHeader, settings, status)
import qualified Web.Scotty                      as S (header)

import           Data.Aeson                      (FromJSON, parseJSON,
                                                  withObject, (.!=), (.:),
                                                  (.:?))
import qualified Data.ByteString.Lazy            as LB (ByteString, empty)
import           Data.Foldable                   (forM_)
import qualified Data.Text.Lazy                  as LT (Text, empty, length)
import           System.Exit                     (ExitCode (..))
import           System.Process.ByteString.Lazy  (readProcessWithExitCode)

import           Control.Concurrent              (forkIO)
import           Control.Concurrent.MVar         (MVar, newEmptyMVar, putMVar,
                                                  takeMVar)
import           Control.Concurrent.STM          (TVar, atomically, newTVarIO,
                                                  readTVar, retry, writeTVar)
import           Control.Monad                   (forever, void)
import           Data.Yaml                       (decodeFileEither)
import           System.Posix.Signals            (Handler (Catch),
                                                  installHandler, sigHUP,
                                                  sigINT, sigTERM)

import           Control.Monad.IO.Class          (liftIO)
import           Data.IORef                      (IORef, atomicWriteIORef,
                                                  newIORef, readIORef)

import           Prelude
import qualified System.Logger                   as L (DateFormat (..), Logger,
                                                       Output (StdErr),
                                                       defSettings, err, info,
                                                       msg, new, setFormat,
                                                       setOutput)

import           Data.UnixTime                   (formatUnixTime)
import           System.IO.Unsafe                (unsafePerformIO)


import           Data.Semigroup                  ((<>))
import           Options.Applicative

data Options = Options { getHost       :: String
                       , getPort       :: Int
                       , getConfigPath :: String
                       }

parser :: Parser Options
parser = Options <$> strOption (long "host"
                                <> short 'H'
                                <> metavar "HOST"
                                <> help "func server host."
                                <> value "127.0.0.1")
                 <*> option auto (long "port"
                                  <> short 'p'
                                  <> metavar "PORT"
                                  <> help "func server port."
                                  <> value 3000)
                 <*> strOption (long "config"
                                <> short 'c'
                                <> metavar "FILE"
                                <> help "func config file."
                                <> value "config.yaml")

main :: IO ()
main = execParser opts >>= program
  where
    opts = info (helper <*> parser)
      ( fullDesc
     <> progDesc "func server"
     <> header "func - Function as a service" )

program :: Options -> IO ()
program Options{getHost = host, getPort = port, getConfigPath = configPath} = do
  handle <- newProcHandle
  void . forkIO $ scottyOpts opts (application handle)

  processSignal configPath handle

  where opts = def { settings = setPort port $ setHost (Host host) (settings def) }

application :: ProcHandle -> ScottyM ()
application handle =
  post "/function/:func" (processHandler handle)

type FuncName = String

data Proc = Proc { procFuncName    :: FuncName
                 , procName        :: String
                 , procArgv        :: [String]
                 , procContentType :: LT.Text
                 }

instance FromJSON Proc where
  parseJSON = withObject "Proc" $ \o -> do
    procFuncName    <- o .:  "func"
    procName        <- o .:  "proc"
    procArgv        <- o .:? "argv"         .!= []
    procContentType <- o .:? "content-type" .!= LT.empty
    return Proc {..}

runProc :: Proc -> LB.ByteString -> IO (Either LB.ByteString LB.ByteString)
runProc Proc{procName = name, procArgv = argv} rb = do
  (code, out, err) <- readProcessWithExitCode name argv rb
  case code of
    ExitSuccess   -> return (Right out)
    ExitFailure _ -> return (Left err)

newtype ProcHandle = ProcHandle (IORef [Proc])

newProcHandle :: IO ProcHandle
newProcHandle = ProcHandle <$> newIORef []

getProc :: ProcHandle -> FuncName -> IO (Maybe Proc)
getProc (ProcHandle ref) func = go <$> readIORef ref

  where go :: [Proc] -> Maybe Proc
        go [] = Nothing
        go (x:xs) | func == procFuncName x = Just x
                  | otherwise              = go xs

updateProcHandle :: ProcHandle -> [Proc] -> IO ()
updateProcHandle (ProcHandle ref) = atomicWriteIORef ref


processHandler :: ProcHandle -> ActionM ()
processHandler handle = do
  func  <- param "func"
  wb    <- body
  proc_ <- liftIO $ getProc handle func

  case proc_ of
    Nothing -> do
      status status404
      raw LB.empty

    Just p -> do
      ret   <- liftIO $ runProc p wb
      case ret of
        Left err -> do
          status status500
          raw err
        Right dat -> do
          if LT.length (procContentType p) > 0 then
            setHeader "Content-Type" (procContentType p)
          else do
            ct <- S.header "Content-Type"
            forM_ ct (setHeader "Content-Type")
          raw dat

-- |read the config file, update shared state with current spec,
-- |re-sync running supervisors, wait for the HUP TVar, then repeat!
monitorConfig :: L.Logger -> String -> ProcHandle -> TVar (Maybe Int) -> IO ()
monitorConfig logger configPath handle wakeSig = do
  L.info logger (L.msg ("HUP caught, reloading config" :: String))
  mspec <- decodeFileEither configPath
  case mspec of
    Left e      -> L.err logger (L.msg ("<<<< Config Error >>>>" ++ show e))
    Right procs -> updateProcHandle handle procs

  waitForWake wakeSig

-- |wait for the STM TVar to be non-nothing
waitForWake :: TVar (Maybe Int) -> IO ()
waitForWake wakeSig = atomically $ do
  state <- readTVar wakeSig
  case state of
      Just _  -> writeTVar wakeSig Nothing
      Nothing -> retry

-- |Signal handler: when a HUP is trapped, write to the wakeSig Tvar
-- |to make the configuration monitor loop cycle/reload
handleHup :: TVar (Maybe Int) -> IO ()
handleHup wakeSig = atomically $ writeTVar wakeSig $ Just 1

handleExit :: MVar Bool -> IO ()
handleExit mv = putMVar mv True

format :: L.DateFormat
format = L.DateFormat $ \u -> unsafePerformIO $ formatUnixTime "%Y-%m-%d %H:%M:%S" u

processSignal :: String -> ProcHandle -> IO ()
processSignal configPath handle = do
  -- The wake signal, set by the HUP handler to wake the monitor loop
  wakeSig <- newTVarIO Nothing
  void $ installHandler sigHUP (Catch $ handleHup wakeSig) Nothing

  -- Handle dying
  bye <- newEmptyMVar
  void $ installHandler sigTERM (Catch $ handleExit bye) Nothing
  void $ installHandler sigINT (Catch $ handleExit bye) Nothing

  logger <- L.new . L.setOutput L.StdErr . L.setFormat (Just format) $ L.defSettings
  -- Finally, run the config load/monitor thread
  void . forkIO $ forever $ monitorConfig logger configPath handle wakeSig

  void $ takeMVar bye

  L.info logger (L.msg ("INT | TERM received; initiating shutdown..." :: String))
