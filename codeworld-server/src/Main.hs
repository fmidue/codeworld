{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns
    -fno-warn-name-shadowing
    -fno-warn-unused-imports
    -fno-warn-unused-matches #-}

{-
  Copyright 2020 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}
module Main where

import CodeWorld.Compile (CompileStatus (..), Stage (..), compileSource)
import CodeWorld.Compile.Base (baseVersion, generateBaseBundle)
import Config (CompilerConfig (..), Config (..), PreviewConfig (..), loadConfig)
import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.MSem (MSem)
import qualified Control.Concurrent.MSem as MSem (new, peekAvail, with)
import Control.Exception (SomeException, bracket_, catch)
import qualified Control.Exception.Lifted as CE (catch)
import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import qualified Data.ByteString as B (ByteString, empty, hPutStr, readFile, writeFile)
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as LB (fromStrict)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.List.Extra (replace)
import qualified Data.Map as M (Map, lookup)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T (drop, intercalate, lines, pack, splitAt, splitOn, unlines, unpack)
import qualified Data.Text.Encoding as T (decodeUtf8, encodeUtf8)
import qualified Data.Text.IO as T (writeFile)
import Ormolu (OrmoluException, defaultConfig, ormolu)
import Snap.Core (Snap, addHeader, getParam, modifyRequest, modifyResponse, redirect, route, setContentType, setResponseCode, writeBS, writeLBS)
import Snap.Http.Server (ConfigLog (ConfigIoLog), httpServe)
import qualified Snap.Http.Server.Config as S (commandLineConfig, defaultConfig, setErrorLog, setPort)
import Snap.Util.FileServe (DirectoryConfig (..), defaultDirectoryConfig, serveDirectory, serveFile)
import Snap.Util.FileUploads (UploadPolicy, defaultUploadPolicy, handleMultipart, setMaximumFormInputSize)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Text.Read (readMaybe)
import Text.Regex.TDFA (getAllMatches, (=~))
import Util (BuildMode (..), baseCodeFile, baseSymbolFile)

data Context = Context
  { compileSem :: MSem Int,
    errorSem :: MSem Int,
    baseSem :: MSem Int,
    config :: Config
  }

customErrorLog :: ConfigLog
customErrorLog = ConfigIoLog $ B.hPutStr stderr

main :: IO ()
main = do
  cfg <- loadConfig
  ctx <- makeContext cfg
  port <- maybe Nothing readMaybe <$> lookupEnv "PORT" :: IO (Maybe Int)
  let customDefaultConfig = S.setErrorLog customErrorLog ((maybe id (\p -> S.setPort p) port) S.defaultConfig)
  cfg <- S.commandLineConfig customDefaultConfig
  forkIO $ baseVersion >>= buildBaseIfNeeded ctx >> return ()
  httpServe cfg $ (processBody >> site ctx) <|> site ctx

makeContext :: Config -> IO Context
makeContext cfg = do
  ctx <-
    Context
      <$> MSem.new (maxSimultaneousCompiles $ compilerConfig cfg)
      <*> MSem.new (maxSimultaneousErrorChecks $ compilerConfig cfg)
      <*> MSem.new 1
      <*> pure cfg
  return ctx

-- | A CodeWorld Snap API action
type CodeWorldHandler = Context -> Snap ()

-- A revised upload policy that allows up to 8 MB of uploaded data in a
-- request.  This is needed to handle uploads of projects including editor
-- history.
codeworldUploadPolicy :: UploadPolicy
codeworldUploadPolicy =
  setMaximumFormInputSize (2 ^ (23 :: Int)) defaultUploadPolicy

-- Processes the body of a multipart request.
#if MIN_VERSION_snap_core(1,0,0)
processBody :: Snap ()
processBody = do
    handleMultipart codeworldUploadPolicy (\x y -> return ())
    return ()
#else
processBody :: Snap ()
processBody = do
    handleMultipart codeworldUploadPolicy (\x -> return ())
    return ()
#endif

getBuildMode :: Snap BuildMode
getBuildMode =
  getParam "mode" >>= \case
    Just "haskell" -> return (BuildMode "haskell")
    Just "blocklyXML" -> return (BuildMode "blocklyXML")
    _ -> return (BuildMode "codeworld")

site :: CodeWorldHandler
site ctx =
  let routes =
        [ 
          ("compile", compileHandler ctx),
          ("errorCheck", errorCheckHandler ctx),
          ("runBaseJS", runBaseHandler ctx),
          ("haskell", serveEditor ctx),
          ("indent", indentHandler ctx),
          ("run", runHandler ctx),
          ("run.html", redirect "/run"),
          ("env.html", redirect "/")
        ]
   in route routes <|> serveDirectory "web"

assert :: Bool -> IO ()
assert p =
  if p
    then pure ()
    else fail "assert failed"

tryOr :: a -> IO a -> IO a
tryOr fallback action = 
  catch action (\(_ :: SomeException) -> pure fallback)

-- A DirectoryConfig that sets the cache-control header to avoid errors when new
-- changes are made to JavaScript.
dirConfig :: DirectoryConfig Snap
dirConfig = defaultDirectoryConfig {preServeHook = disableCache}
  where
    disableCache _ = modifyRequest (addHeader "Cache-control" "no-cache")


runCompile :: Context -> BuildMode -> Text -> IO (CompileStatus, Either Text (Text,Text))
runCompile ctx mode source = withSystemTempDirectory "codeworld" $ \tempDir -> do
    let sourceDir = tempDir </> "source"
        buildDir = tempDir </> "build"
    createDirectoryIfMissing True sourceDir
    createDirectoryIfMissing True buildDir

    status <- do
      T.writeFile (sourceDir </> "program.hs") source
      compileIfNeeded ctx tempDir mode

    hasResultFile <- doesFileExist (buildDir </> "err.txt")

    case status of
      CompileSuccess | hasResultFile -> do
        content <- readFile (buildDir </> "err.txt")
        target <- readFile (buildDir </> "program.js")
        pure (status, Right (T.pack content,T.pack target))
      _ | hasResultFile -> do
        content <- readFile (buildDir </> "err.txt")
        pure (status, Left $ T.pack content)
      _ -> pure (status, Left "Something went wrong")

replaceUndefinedWithHole :: Text -> (Int, Text)
replaceUndefinedWithHole txt = (length matches, replace matches 0 txt)
  where
    undefinedRegex = "\\bundefined\\b" :: Text
    matches = getAllMatches (txt =~ undefinedRegex) :: [(Int,Int)]

    replace [] _ t = t
    replace ((targetIndex,_):xs) cursor t = 
      let (before, rest) = T.splitAt (targetIndex - cursor) t
       in before <> "_" <> replace xs (targetIndex + 9) (T.drop 9 rest)

replaceHolesWithDefaultValue :: [(Int,Int,Text)] -> M.Map Text Text -> Text -> Maybe Text
replaceHolesWithDefaultValue holes defaults input = T.unlines <$> replaceHolesInLines lines
  where 
    lines = zip [1 :: Int ..] $ T.lines input

    replaceHolesInLines lines = traverse (\(num,line) -> replaceHolesInLine (filter (\(r,_,_) -> r == num) holes) 1 line) lines

    replaceHolesInLine [] _ line = Just line
    replaceHolesInLine ((_,c,ty):xs) cursor line = 
      let (before,rest) = T.splitAt (c - cursor) line
       in case M.lookup ty defaults of
        Nothing -> Nothing
        Just defaultValue -> do
          newRest <- replaceHolesInLine xs (c + 1) (T.drop 9 rest)
          pure $ before <> "(" <> defaultValue <> ")" <> newRest

extractHolesFromErrorText :: Text -> [(Int,Int,Text)]
extractHolesFromErrorText error =
  let errorSplit = T.splitOn "\n\n" error
      regex = "^program\\.hs:([[:digit:]]+):([[:digit:]]+): error:[[:cntrl:]] +[^F]+Found hole: _ :: ([[:print:]]+)[[:cntrl:]]" :: Text
      matches = concatMap (\block -> block =~ regex :: [[Text]]) errorSplit
      textToInt = read . T.unpack
   in mapMaybe (\input -> case input of { [_,line,col,ty] -> Just (textToInt line, textToInt col, ty); _ -> Nothing } ) matches

compileHandler :: CodeWorldHandler
compileHandler ctx = do
  mode <- getBuildMode
  let previewConf = previewConfig $ config ctx
  Just source <- (T.decodeUtf8 <$>) <$> getParam "source"
  mPreview <- getParam "enablePreview"
  let previewsEnabled = case mPreview of
        Just "True" -> True
        Just "true" -> True
        Just "False" -> False
        Just "false" -> False
        _ -> enabledByDefault previewConf

  (compileStatus, result) <- liftIO $ do 
    (originalStatus, originalResult) <- runCompile ctx mode source

    tryOr (originalStatus, originalResult) $ do
      assert previewsEnabled
      assert $ originalStatus == CompileSuccess
      
      let (replaceCount, sourceWithHolePlaceholders) = replaceUndefinedWithHole source
      assert $ replaceCount > 0

      (_,Left error) <- runCompile ctx mode sourceWithHolePlaceholders

      let holes = extractHolesFromErrorText error
          replacementMap = defaultHoleValues previewConf
          Just withDefaultValues = replaceHolesWithDefaultValue holes replacementMap source

      (status', res') <- runCompile ctx mode withDefaultValues

      assert $ status' == CompileSuccess

      pure (status', res')

  let responseBody = T.intercalate "\n=======================\n" $ case result of 
          Right (content, target) -> [content,target]
          Left errorMessage -> [errorMessage]

  modifyResponse $ setResponseCode (responseCodeFromCompileStatus compileStatus)
  modifyResponse $ setContentType "text/plain"
  writeBS $ T.encodeUtf8 responseBody

errorCheckHandler :: CodeWorldHandler
errorCheckHandler ctx = do
  mode <- getBuildMode
  Just source <- getParam "source"
  (status, output) <- liftIO $ errorCheck ctx mode source
  modifyResponse $ setResponseCode (responseCodeFromCompileStatus status)
  modifyResponse $ setContentType "text/plain"
  case status of
    CompileSuccess -> writeBS ""
    _ -> writeBS output

runBaseHandler :: CodeWorldHandler
runBaseHandler ctx = do
  maybeVer <- fmap T.decodeUtf8 <$> getParam "version"
  hasProgram <-
    (\mode hash dhash -> mode && (hash || dhash))
      <$> hasParam "mode" <*> hasParam "hash" <*> hasParam "dhash"
  case maybeVer of
    Just ver -> serveFile (baseCodeFile ver)
    Nothing -> do
      ver <- liftIO baseVersion
      liftIO $ buildBaseIfNeeded ctx ver
      serveFile (baseCodeFile ver)
  where
    hasParam name = (/= Nothing) <$> getParam name

escapeCode :: String -> String
escapeCode input = foldr
  (\r -> replace r ('\\':r))
  (escapeBackslashes input)
  toBeEscaped
  where 
    escapeBackslashes = replace "\\" "\\\\"
    toBeEscaped = ["${","`"]

serveEditor :: CodeWorldHandler
serveEditor ctx = do
  msource <- getParam "source"
  modifyResponse $ setContentType "text/html"
  template <- liftIO $ readFile "web/env.html"
  let code = maybe "" (T.unpack . T.decodeUtf8) msource
  let content = replace "/*CODE_TO_BE_LOADED_BY_DEFAULT*/" (escapeCode code) template 
  writeBS $ T.encodeUtf8 $ T.pack content

indentHandler :: CodeWorldHandler
indentHandler ctx = do
  mode <- getBuildMode
  Just source <- getParam "source"
  reformat source `CE.catch` handleError
  where
    reformat source = do
      result <- ormolu defaultConfig "program.hs" (T.unpack (T.decodeUtf8 source))
      modifyResponse $ setContentType "text/x-haskell"
      writeBS $ T.encodeUtf8 result
    handleError (e :: OrmoluException) = do
      modifyResponse $ setResponseCode 500 . setContentType "text/plain"
      writeLBS $ LB.fromStrict $ T.encodeUtf8 $ T.pack (show e)

runHandler :: CodeWorldHandler
runHandler ctx = do
  msource <- getParam "source"
  modifyResponse $ setContentType "text/html"
  template <- liftIO $ readFile "web/run.html"
  let code = maybe "" (T.unpack . T.decodeUtf8) msource
  let content = replace "/*CODE_TO_BE_LOADED_BY_DEFAULT*/" (escapeCode code) template 
  writeBS $ T.encodeUtf8 $ T.pack content

responseCodeFromCompileStatus :: CompileStatus -> Int
responseCodeFromCompileStatus CompileSuccess = 200
responseCodeFromCompileStatus CompileError = 400
responseCodeFromCompileStatus CompileAborted = 503

waitAndLogExhausted :: String -> MSem Int -> IO b -> IO b
waitAndLogExhausted name sem action = do
  open <- MSem.peekAvail sem
  when (open < 1) $
    hPutStrLn stderr $ name ++ " has exhausted its available resources, but there is further demand." 
  MSem.with sem action

compileIfNeeded :: Context -> FilePath -> BuildMode -> IO CompileStatus
compileIfNeeded ctx basePath mode = do
  hasResult <- doesFileExist (basePath </> "build" </> "err.txt")
  hasTarget <- doesFileExist (basePath </> "build" </> "program.js")
  if
      | hasResult && hasTarget -> return CompileSuccess
      | hasResult -> return CompileError
      | otherwise ->
        waitAndLogExhausted "Compile" (compileSem ctx) $ compileProgram ctx basePath mode

compileProgram :: Context -> FilePath -> BuildMode -> IO CompileStatus
compileProgram ctx basePath mode = do
  ver <- baseVersion
  baseStatus <- buildBaseIfNeeded ctx ver

  case baseStatus of
    CompileSuccess -> do
      status <- compileIncrementally ctx basePath mode ver
      T.writeFile (basePath </> "build" </> "basever") ver

      -- It's possible that a new library was built during the compile.  If so, then the code
      -- we've just built is suspect, and it's better to just build it anew!
      checkVer <- baseVersion
      if ver == checkVer
        then return status
        else compileProgram ctx basePath mode
    _ -> return CompileAborted

compileIncrementally :: Context -> FilePath -> BuildMode -> Text -> IO CompileStatus
compileIncrementally ctx basePath mode ver =
  compileSource stage source (projectModuleFinder (Just sourceDir) mode) extraExt result (getMode mode) False
  where
    sourceDir = basePath </> "source"
    source = sourceDir </> "program.hs"
    target = basePath </> "build" </> "program.js"
    result = basePath </> "build" </> "err.txt"
    baseURL = "runBaseJS?version=" ++ T.unpack ver
    stage = UseBase target (baseSymbolFile ver) baseURL
    extraExt = extraExtensions $ config ctx

projectModuleFinder :: Maybe FilePath -> BuildMode -> String -> IO (Maybe FilePath)
projectModuleFinder mSourceDir mode modName
  | length modName /= 23 || '.' `elem` modName = return Nothing
  | "P" `isPrefixOf` modName = go
  | otherwise = return Nothing
  where
    go = do
      case mSourceDir of
        Nothing -> return Nothing
        Just sourceDir -> do 
          let path = sourceDir </> "program.hs"
          exists <- doesFileExist path
          if exists then return (Just path) else return Nothing

noModuleFinder :: String -> IO (Maybe FilePath)
noModuleFinder _ = return Nothing

buildBaseIfNeeded :: Context -> Text -> IO CompileStatus
buildBaseIfNeeded ctx ver = do
  codeExists <- doesFileExist (baseCodeFile ver)
  symbolsExist <- doesFileExist (baseSymbolFile ver)
  if not codeExists || not symbolsExist
    then waitAndLogExhausted "Base" (baseSem ctx) $ withSystemTempDirectory "genbase" $ \tmpdir -> do
      let linkMain = tmpdir </> "LinkMain.hs"
      let linkBase = tmpdir </> "LinkBase.hs"
      let err = tmpdir </> "output.txt"
      generateBaseBundle basePaths baseIgnore "codeworld" linkMain linkBase
      let stage = GenBase "LinkBase" linkBase (baseCodeFile ver) (baseSymbolFile ver)
      let extraExt = extraExtensions $ config ctx
      compileSource stage linkMain noModuleFinder extraExt err "codeworld" False
    else return CompileSuccess

basePaths :: [FilePath]
basePaths = ["codeworld-base/dist/doc/html/codeworld-base/codeworld-base.txt"]

baseIgnore :: [Text]
baseIgnore = ["fromCWText", "toCWText", "randomsFrom"]

errorCheck :: Context -> BuildMode -> B.ByteString -> IO (CompileStatus, B.ByteString)
errorCheck ctx mode source = withSystemTempDirectory "cw_errorCheck" $ \dir -> do
  let srcFile = dir </> "program.hs"
  let errFile = dir </> "output.txt"
  B.writeFile srcFile source
  let extraExt = extraExtensions $ config ctx
  status <-
    waitAndLogExhausted "Error" (errorSem ctx) $ waitAndLogExhausted "Compile" (compileSem ctx) $
      compileSource ErrorCheck srcFile (projectModuleFinder Nothing mode) extraExt errFile (getMode mode) False
  hasOutput <- doesFileExist errFile
  output <- if hasOutput then B.readFile errFile else return B.empty
  return (status, output)

getMode :: BuildMode -> String
getMode (BuildMode m) = m
