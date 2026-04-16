{-# LANGUAGE OverloadedStrings #-}
module Config
  ( Config (..)
  , CompilerConfig (..)
  , PreviewConfig (..)
  , loadConfig
  ) 
where

import CodeWorld.Compile (ExtraExtensions(..))
import Data.Map (Map, fromAscList)
import Data.Text (Text)
import Data.Yaml (FromJSON(..), withObject, (.:?), (.!=), decodeFileEither, prettyPrintParseException)
import System.Environment (lookupEnv, getExecutablePath)
import System.FilePath (FilePath, takeDirectory)
import System.IO (hPutStrLn, stderr)

data Config = Config 
  { compilerConfig :: CompilerConfig
  , previewConfig :: PreviewConfig
  , extraExtensions :: ExtraExtensions
  } deriving Show

data CompilerConfig = CompilerConfig
  { maxSimultaneousCompiles :: Int
  , maxSimultaneousErrorChecks :: Int
  } deriving Show

data PreviewConfig = PreviewConfig
  { enabledByDefault :: Bool
  , defaultHoleValues :: Map Text Text
  } deriving Show

defaultConfig :: Config
defaultConfig = Config
  { compilerConfig = defaultCompilerConfig
  , previewConfig = defaultPreviewConfig
  , extraExtensions = ExtraExtensions [] []
  }

defaultCompilerConfig :: CompilerConfig
defaultCompilerConfig = CompilerConfig
  { maxSimultaneousCompiles = 4
  , maxSimultaneousErrorChecks = 2
  }

defaultPreviewConfig :: PreviewConfig
defaultPreviewConfig = PreviewConfig
  { enabledByDefault = False
  , defaultHoleValues = fromAscList []
  }

instance FromJSON Config where
  parseJSON = withObject "Config" $ \v -> Config
    <$> v .:? "compile" .!= defaultCompilerConfig
    <*> v .:? "preview" .!= defaultPreviewConfig
    <*> v .:? "extraExtensions" .!= ExtraExtensions [] []

instance FromJSON CompilerConfig where
  parseJSON = withObject "CompilerConfig" $ \v -> CompilerConfig
    <$> v .:? "maxSimultaneousCompiles" .!= 4
    <*> v .:? "maxSimultaneousErrorChecks" .!= 2

instance FromJSON PreviewConfig where
  parseJSON = withObject "PreviewConfig" $ \v -> PreviewConfig
    <$> v .:? "enabledByDefault" .!= False
    <*> v .:? "defaultHoleValues" .!= fromAscList []

determineConfigPath :: IO FilePath
determineConfigPath = do
  configPathFromEnv <- lookupEnv "CONFIG_PATH" :: IO (Maybe FilePath)
  case configPathFromEnv of
    Just path -> pure path
    Nothing -> do
      exePath <- getExecutablePath
      pure (takeDirectory exePath ++ "/config.yaml")


loadConfig :: IO Config
loadConfig = do
  configPath <- determineConfigPath
  parseResult <- decodeFileEither configPath
  case parseResult of
    Left err -> do
      hPutStrLn stderr ("Warning: Failed to load CodeWorld config from " ++ configPath ++ ". Resuming with default config. ")
      hPutStrLn stderr $ prettyPrintParseException err
      pure defaultConfig
    Right cfg -> do 
      putStrLn "Successfully loaded CodeWorld config."
      print cfg
      pure cfg
