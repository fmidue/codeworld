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

import CodeWorld.Account (UserId)
import CodeWorld.Auth
  ( AuthConfig,
    authMethod,
    authRoutes,
    authenticated,
    getAuthConfig,
  )
import CodeWorld.Compile
import CodeWorld.Compile.Base
import Control.Applicative
import Control.Concurrent (forkIO)
import Control.Concurrent.MSem (MSem)
import qualified Control.Concurrent.MSem as MSem
import Control.Exception (bracket_)
import Control.Exception.Lifted (catch)
import Control.Monad
import Control.Monad.Trans
import Data.Aeson
import qualified Data.ByteString as B
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Char (isSpace)
import Data.List
import Data.List.Extra (replace)
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import Model
import Network.HTTP.Simple
import Ormolu (OrmoluException, defaultConfig, ormolu)
import Snap.Core
import Snap.Http.Server (httpServe)
import qualified Snap.Http.Server.Config as S (commandLineConfig, defaultConfig, setPort)
import Snap.Util.FileServe
import Snap.Util.FileUploads
import System.Directory
import System.FileLock
import System.FilePath
import System.IO.Temp
import System.Environment (lookupEnv)
import Util
import Text.Read (readMaybe)

maxSimultaneousCompiles :: Int
maxSimultaneousCompiles = 4

maxSimultaneousErrorChecks :: Int
maxSimultaneousErrorChecks = 2

data Context = Context
  { authConfig :: AuthConfig,
    compileSem :: MSem Int,
    errorSem :: MSem Int,
    baseSem :: MSem Int
  }

main :: IO ()
main = do
  ctx <- makeContext
  port <- maybe Nothing readMaybe <$> lookupEnv "PORT" :: IO (Maybe Int)
  cfg <- S.commandLineConfig ((maybe id (\p -> S.setPort p) port) S.defaultConfig)
  forkIO $ baseVersion >>= buildBaseIfNeeded ctx >> return ()
  httpServe cfg $ (processBody >> site ctx) <|> site ctx

makeContext :: IO Context
makeContext = do
  ctx <-
    Context <$> (getAuthConfig =<< getCurrentDirectory)
      <*> MSem.new maxSimultaneousCompiles
      <*> MSem.new maxSimultaneousErrorChecks
      <*> MSem.new 1
  putStrLn $ "Authentication method: " ++ authMethod (authConfig ctx)
  return ctx

-- | A CodeWorld Snap API action
type CodeWorldHandler = Context -> Snap ()

-- | A public handler that can be called from both authenticated and
--  unauthenticated clients and that does not need access to the user
--  ID.
public :: CodeWorldHandler -> CodeWorldHandler
public = id

-- | A private handler that can only be called from authenticated
--  clients and needs access to the user ID.
private :: (UserId -> CodeWorldHandler) -> CodeWorldHandler
private handler ctx = authenticated (flip handler ctx) (authConfig ctx)

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
          -- ("loadProject", loadProjectHandler ctx),
          -- ("saveProject", saveProjectHandler ctx),
          -- ("deleteProject", deleteProjectHandler ctx),
          -- ("createFolder", createFolderHandler ctx),
          -- ("deleteFolder", deleteFolderHandler ctx),
          -- ("listFolder", listFolderHandler False ctx),
          -- ("listFolders", listFolderHandler True ctx),
          -- ("updateChildrenIndexes", updateChildrenIndexesHandler ctx),
          -- ("shareFolder", shareFolderHandler ctx),
          -- ("shareContent", shareContentHandler ctx),
          -- ("moveProject", moveProjectHandler ctx),
          ("compile", compileHandler ctx),
          ("errorCheck", errorCheckHandler ctx),
          -- ("saveXMLhash", saveXMLHashHandler ctx),
          -- ("loadXML", loadXMLHandler ctx),
          ("loadSource", loadSourceHandler ctx),
          ("run", runHandler ctx),
          ("runJS", runHandler ctx),
          ("runBaseJS", runBaseHandler ctx),
          ("runMsg", runMessageHandler ctx),
          -- ("haskell", serveFile "web/env.html"),
          ("haskell", serveEditor ctx),
          -- ("blocks", serveFile "web/blocks.html"),
          -- ("funblocks", serveFile "web/blocks.html"),
          ("indent", indentHandler ctx),
          -- ("gallery/:shareHash", galleryHandler ctx),
          ("log", logHandler ctx)
        ]
          ++ authRoutes (authConfig ctx)
   in route routes <|> serveDirectory "web"

-- A DirectoryConfig that sets the cache-control header to avoid errors when new
-- changes are made to JavaScript.
dirConfig :: DirectoryConfig Snap
dirConfig = defaultDirectoryConfig {preServeHook = disableCache}
  where
    disableCache _ = modifyRequest (addHeader "Cache-control" "no-cache")

createFolderHandler :: CodeWorldHandler
createFolderHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let pathText = map T.pack path
      dirIds = map nameToDirId pathText
      finalDir = joinPath $ map dirBase dirIds
      name = last pathText
  liftIO $ ensureUserBaseDir mode userId finalDir
  liftIO $ createDirectory $ userProjectDir mode userId </> finalDir
  modifyResponse $ setContentType "text/plain"
  liftIO $
    T.writeFile
      (userProjectDir mode userId </> finalDir </> "dir.info")
      name

deleteFolderHandler :: CodeWorldHandler
deleteFolderHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  liftIO $ ensureUserDir mode userId finalDir
  let dir = userProjectDir mode userId </> finalDir
  liftIO $ removeDirectoryIfExists dir

loadProjectHandler :: CodeWorldHandler
loadProjectHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just name <- getParam "name"
  let projectName = T.decodeUtf8 name
  let projectId = nameToProjectId projectName
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  liftIO $ ensureProjectDir mode userId finalDir projectId
  let file =
        userProjectDir mode userId </> finalDir
          </> projectFile projectId
  modifyResponse $ setContentType "application/json"
  serveFile file

saveProjectHandler :: CodeWorldHandler
saveProjectHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  Just project <- decode . LB.fromStrict . fromJust <$> getParam "project"
  let projectId = nameToProjectId (projectName project)
  liftIO $ ensureProjectDir mode userId finalDir projectId
  let file =
        userProjectDir mode userId </> finalDir
          </> projectFile projectId
  liftIO $ LB.writeFile file $ encode project

deleteProjectHandler :: CodeWorldHandler
deleteProjectHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just name <- getParam "name"
  let projectName = T.decodeUtf8 name
  let projectId = nameToProjectId projectName
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  liftIO $ ensureProjectDir mode userId finalDir projectId
  let file =
        userProjectDir mode userId </> finalDir
          </> projectFile projectId
  liftIO $ removeFileIfExists file

listFolderHandler :: Bool -> CodeWorldHandler
listFolderHandler recurse = private $ \userId ctx -> do
  mode <- getBuildMode
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  liftIO $ ensureUserBaseDir mode userId finalDir
  liftIO $ ensureUserDir mode userId finalDir
  let projectDir = userProjectDir mode userId
  entries <- liftIO $ fsEntries recurse (projectDir </> finalDir)
  modifyResponse $ setContentType "application/json"
  writeLBS (encode entries)

-- | Update order of elements inside of given directory
updateChildrenIndexesHandler :: CodeWorldHandler
updateChildrenIndexesHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  let projectDir = userProjectDir mode userId
  Just path <-
    fmap
      ( (\p -> projectDir </> p </> "order.info")
          . joinPath
          . (map (dirBase . nameToDirId . T.pack))
          . splitDirectories
          . T.unpack
          . T.decodeUtf8
      )
      <$> getParam "path"
  param <- getParam "entries"
  -- Encoding just to check if request param is correct
  Just entries <- decodeStrict . fromJust <$> getParam "entries" :: Snap (Maybe [FileSystemEntry])
  liftIO $ LB.writeFile path $ encode entries

shareFolderHandler :: CodeWorldHandler
shareFolderHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just path <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "path"
  let dirIds = map (nameToDirId . T.pack) path
  let finalDir = joinPath $ map dirBase dirIds
  checkSum <-
    liftIO $ dirToCheckSum $ userProjectDir mode userId </> finalDir
  liftIO $ ensureShareDir mode $ ShareId checkSum
  liftIO
    $ B.writeFile (shareRootDir mode </> shareLink (ShareId checkSum))
    $ T.encodeUtf8 (T.pack (userProjectDir mode userId </> finalDir))
  modifyResponse $ setContentType "text/plain"
  writeBS $ T.encodeUtf8 checkSum

shareContentHandler :: CodeWorldHandler
shareContentHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just shash <- getParam "shash"
  sharingFolder <-
    liftIO $
      B.readFile
        (shareRootDir mode </> shareLink (ShareId $ T.decodeUtf8 shash))
  Just name <- fmap T.decodeUtf8 <$> getParam "name"
  let dirPath = dirBase $ nameToDirId name
  liftIO $ ensureUserBaseDir mode userId dirPath
  liftIO
    $ copyDirIfExists (T.unpack (T.decodeUtf8 sharingFolder))
    $ userProjectDir mode userId </> dirPath
  liftIO $
    T.writeFile
      (userProjectDir mode userId </> dirPath </> "dir.info")
      name

moveProjectHandler :: CodeWorldHandler
moveProjectHandler = private $ \userId ctx -> do
  mode <- getBuildMode
  Just moveTo <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "moveTo"
  let moveToDir = joinPath $ map (dirBase . nameToDirId . T.pack) moveTo
  Just moveFrom <- fmap (splitDirectories . T.unpack . T.decodeUtf8) <$> getParam "moveFrom"
  let projectDir = userProjectDir mode userId
  let moveFromDir =
        projectDir
          </> joinPath (map (dirBase . nameToDirId . T.pack) moveFrom)
  let parentFrom =
        if moveFrom == []
          then []
          else init moveFrom
  Just isFile <- getParam "isFile"
  case (moveTo == moveFrom, moveTo == parentFrom, isFile) of
    (False, _, "true") -> do
      Just name <- getParam "name"
      let projectId = nameToProjectId $ T.decodeUtf8 name
          file = moveFromDir </> projectFile projectId
          toFile = projectDir </> moveToDir </> projectFile projectId
      liftIO $ ensureProjectDir mode userId moveToDir projectId
      liftIO $ copyFile file toFile
      liftIO $ removeFileIfExists file
    (_, False, "false") -> do
      let dirName = last $ splitDirectories moveFromDir
      let dir = moveToDir </> dirName
      liftIO $ ensureUserBaseDir mode userId dir
      liftIO $ copyDirIfExists moveFromDir $ projectDir </> dir
      liftIO $ removeDirectoryIfExists moveFromDir
    (_, _, _) -> return ()

withProgramLock :: BuildMode -> ProgramId -> IO a -> IO a
withProgramLock (BuildMode mode) (ProgramId hash) action = do
  tmpDir <- getTemporaryDirectory
  let tmpFile = tmpDir </> "codeworld" <.> T.unpack hash <.> mode
  withFileLock tmpFile Exclusive (const action)

saveXMLHashHandler :: CodeWorldHandler
saveXMLHashHandler = public $ \ctx -> do
  mode <- getBuildMode
  unless (mode == BuildMode "blocklyXML")
    $ modifyResponse
    $ setResponseCode 500
  Just source <- getParam "source"
  let programId = sourceToProgramId source
  liftIO $ withProgramLock mode programId $ do
    ensureSourceDir mode programId
    B.writeFile (sourceRootDir mode </> sourceXML programId) source
  modifyResponse $ setContentType "text/plain"
  writeBS (T.encodeUtf8 (unProgramId programId))

compileHandler :: CodeWorldHandler
compileHandler = public $ \ctx -> do
  mode <- getBuildMode
  Just source <- getParam "source"
  let programId = sourceToProgramId source
      deployId = sourceToDeployId source
  status <- liftIO $ withProgramLock mode programId $ do
    ensureSourceDir mode programId
    B.writeFile (sourceRootDir mode </> sourceFile programId) source
    writeDeployLink mode deployId programId
    compileIfNeeded ctx mode programId
  modifyResponse $ setResponseCode (responseCodeFromCompileStatus status)
  modifyResponse $ setContentType "text/plain"
  let id = unProgramId programId
  let did = unDeployId deployId
  hasResultFile <- liftIO $ doesFileExist (buildRootDir mode </> resultFile programId)
  when (status == CompileSuccess && hasResultFile) $ do
    content <- liftIO $ readFile (buildRootDir mode </> resultFile programId)
    target <- liftIO $ readFile (buildRootDir mode </> targetFile programId)
    let body = T.intercalate "\n=======================\n" [id,did,T.pack content,T.pack target]
    writeBS $ T.encodeUtf8 body
  when (status /= CompileSuccess && hasResultFile) $ do
    content <- liftIO $ readFile (buildRootDir mode </> resultFile programId)
    let body = T.intercalate "\n=======================\n" [id,did,T.pack content]
    writeBS $ T.encodeUtf8 body
  unless (hasResultFile) $ do
    writeBS $ T.encodeUtf8 "Something went wrong"
  liftIO $ removeDirectoryIfExists (sourceRootDir mode)
  liftIO $ removeDirectoryIfExists (buildRootDir mode)
  liftIO $ removeDirectoryIfExists (projectRootDir mode)
  liftIO $ removeDirectoryIfExists (deployRootDir mode)

errorCheckHandler :: CodeWorldHandler
errorCheckHandler = public $ \ctx -> do
  mode <- getBuildMode
  Just source <- getParam "source"
  (status, output) <- liftIO $ errorCheck ctx mode source
  modifyResponse $ setResponseCode (responseCodeFromCompileStatus status)
  modifyResponse $ setContentType "text/plain"
  writeBS output

getHashParam :: Bool -> BuildMode -> Snap ProgramId
getHashParam allowDeploy mode = do
  maybeHash <- getParam "hash"
  case maybeHash of
    Just h -> return (ProgramId (T.decodeUtf8 h))
    Nothing
      | allowDeploy -> do
        Just dh <- getParam "dhash"
        let deployId = DeployId (T.decodeUtf8 dh)
        liftIO $ resolveDeployId mode deployId
      | otherwise -> pass

loadXMLHandler :: CodeWorldHandler
loadXMLHandler = public $ \ctx -> do
  mode <- getBuildMode
  unless (mode == BuildMode "blocklyXML")
    $ modifyResponse
    $ setResponseCode 500
  programId <- getHashParam False mode
  modifyResponse $ setContentType "text/plain"
  serveFile (sourceRootDir mode </> sourceXML programId)

loadSourceHandler :: CodeWorldHandler
loadSourceHandler = public $ \ctx -> do
  mode <- getBuildMode
  programId <- getHashParam False mode
  modifyResponse $ setContentType "text/x-haskell"
  serveFile (sourceRootDir mode </> sourceFile programId)

runHandler :: CodeWorldHandler
runHandler = public $ \ctx -> do
  mode <- getBuildMode
  programId <- getHashParam True mode
  result <-
    liftIO
      $ withProgramLock mode programId
      $ compileIfNeeded ctx mode programId
  modifyResponse $ setResponseCode (responseCodeFromCompileStatus result)
  when (result == CompileSuccess) $ do
    modifyResponse $ setContentType "text/javascript"
    serveFile (buildRootDir mode </> targetFile programId)

runBaseHandler :: CodeWorldHandler
runBaseHandler = public $ \ctx -> do
  maybeVer <- fmap T.decodeUtf8 <$> getParam "version"
  hasProgram <-
    (\mode hash dhash -> mode && (hash || dhash))
      <$> hasParam "mode" <*> hasParam "hash" <*> hasParam "dhash"
  case maybeVer of
    Just ver -> serveFile (baseCodeFile ver)
    Nothing | hasProgram -> do
      mode <- getBuildMode
      programId <- getHashParam True mode
      result <-
        liftIO
          $ withProgramLock mode programId
          $ compileIfNeeded ctx mode programId
      modifyResponse $ setResponseCode (responseCodeFromCompileStatus result)
      when (result == CompileSuccess) $ do
        ver <-
          liftIO $
            B.readFile (buildRootDir mode </> baseVersionFile programId)
        impliedVersion ver
    _ -> do
      ver <- liftIO baseVersion
      liftIO $ buildBaseIfNeeded ctx ver
      impliedVersion (T.encodeUtf8 ver)
  where
    impliedVersion ver = redirect $ "/runBaseJS?version=" <> ver
    hasParam name = (/= Nothing) <$> getParam name

runMessageHandler :: CodeWorldHandler
runMessageHandler = public $ \ctx -> do
  mode <- getBuildMode
  programId <- getHashParam False mode
  modifyResponse $ setContentType "text/plain"
  serveFile (buildRootDir mode </> resultFile programId)

serveEditor :: CodeWorldHandler
serveEditor = public $ \ctx -> do
  msource <- getParam "source"
  modifyResponse $ setContentType "text/html"
  template <- liftIO $ readFile "web/env.html"
  let content = replace "/*CODE_TO_BE_LOADED_BY_DEFAULT*/" (maybe "" (T.unpack . T.decodeUtf8) msource) template 
  writeBS $ T.encodeUtf8 $ T.pack content

indentHandler :: CodeWorldHandler
indentHandler = public $ \ctx -> do
  mode <- getBuildMode
  Just source <- getParam "source"
  reformat source `catch` handleError
  where
    reformat source = do
      result <- ormolu defaultConfig "program.hs" (T.unpack (T.decodeUtf8 source))
      modifyResponse $ setContentType "text/x-haskell"
      writeBS $ T.encodeUtf8 result
    handleError (e :: OrmoluException) = do
      modifyResponse $ setResponseCode 500 . setContentType "text/plain"
      writeLBS $ LB.fromStrict $ T.encodeUtf8 $ T.pack (show e)

galleryHandler :: CodeWorldHandler
galleryHandler = public $ const $ do
  mode <- getBuildMode
  Just shareHash <- getParam "shareHash"
  let shareId = ShareId (T.decodeUtf8 shareHash)
  gallery <- liftIO $ do
    folder <- T.unpack . T.decodeUtf8 <$> B.readFile (shareRootDir mode </> shareLink shareId)
    files <- sort <$> projectFileNames folder
    Gallery <$> mapM (galleryItemFromProject mode folder) files
  writeLBS $ encode gallery

galleryItemFromProject :: BuildMode -> FilePath -> Text -> IO GalleryItem
galleryItemFromProject mode@(BuildMode modeName) folder name = do
  let projectId = nameToProjectId name
  let file = folder </> projectFile projectId
  Just project <- decode <$> LB.readFile file

  let source = T.encodeUtf8 $ projectSource project
  let programId = sourceToProgramId source
  let deployId = sourceToDeployId source

  liftIO $ withProgramLock mode programId $ do
    ensureSourceDir mode programId
    B.writeFile (sourceRootDir mode </> sourceFile programId) source
    writeDeployLink mode deployId programId

  let baseURL = "/" <> if modeName == "codeworld" then "" else T.pack modeName

  return
    GalleryItem
      { galleryItemName = name,
        galleryItemURL =
          "run.html"
            <> "?mode="
            <> T.pack modeName
            <> "&dhash="
            <> unDeployId deployId,
        galleryItemCode = Just (baseURL <> "#" <> unProgramId programId)
      }

logHandler :: CodeWorldHandler
logHandler = public $ \ctx -> do
  Just message <- fmap T.decodeUtf8 <$> getParam "message"
  title <-
    fromMaybe "User-reported unhelpful error message"
      <$> fmap T.decodeUtf8
      <$> getParam "title"
  tag <- fromMaybe "error-message" <$> fmap T.decodeUtf8 <$> getParam "tag"

  liftIO $ do
    let body =
          object
            [ ("title", String title),
              ("body", String message),
              ("labels", toJSON [tag])
            ]
    authToken <- B.readFile "github-auth-token.txt"
    let authHeader = "token " <> authToken
    let userAgent = "https://code.world github integration by cdsmith"
    request <-
      addRequestHeader "Authorization" authHeader
        <$> addRequestHeader "User-agent" userAgent
        <$> setRequestBodyJSON body
        <$> parseRequestThrow "POST https://api.github.com/repos/google/codeworld/issues"
    httpNoBody request
  return ()

responseCodeFromCompileStatus :: CompileStatus -> Int
responseCodeFromCompileStatus CompileSuccess = 200
responseCodeFromCompileStatus CompileError = 400
responseCodeFromCompileStatus CompileAborted = 503

compileIfNeeded :: Context -> BuildMode -> ProgramId -> IO CompileStatus
compileIfNeeded ctx mode programId = do
  hasResult <- doesFileExist (buildRootDir mode </> resultFile programId)
  hasTarget <- doesFileExist (buildRootDir mode </> targetFile programId)
  if
      | hasResult && hasTarget -> return CompileSuccess
      | hasResult -> return CompileError
      | otherwise ->
        MSem.with (compileSem ctx) $ compileProgram ctx mode programId

compileProgram :: Context -> BuildMode -> ProgramId -> IO CompileStatus
compileProgram ctx mode programId = do
  ver <- baseVersion
  baseStatus <- buildBaseIfNeeded ctx ver

  case baseStatus of
    CompileSuccess -> do
      status <- compileIncrementally mode programId ver
      T.writeFile (buildRootDir mode </> baseVersionFile programId) ver

      -- It's possible that a new library was built during the compile.  If so, then the code
      -- we've just built is suspect, and it's better to just build it anew!
      checkVer <- baseVersion
      if ver == checkVer
        then return status
        else compileProgram ctx mode programId
    _ -> return CompileAborted

compileIncrementally :: BuildMode -> ProgramId -> Text -> IO CompileStatus
compileIncrementally mode programId ver =
  compileSource stage source (projectModuleFinder mode) result (getMode mode) False
  where
    source = sourceRootDir mode </> sourceFile programId
    target = buildRootDir mode </> targetFile programId
    result = buildRootDir mode </> resultFile programId
    baseURL = "runBaseJS?version=" ++ T.unpack ver
    stage = UseBase target (baseSymbolFile ver) baseURL

projectModuleFinder :: BuildMode -> String -> IO (Maybe FilePath)
projectModuleFinder mode modName
  | length modName /= 23 || '.' `elem` modName = return Nothing
  | "P" `isPrefixOf` modName = go (ProgramId (T.pack modName))
  | "D" `isPrefixOf` modName = do
    let deployId = DeployId (T.pack modName)
    resolveDeployId mode deployId >>= go
  | otherwise = return Nothing
  where
    go programId = do
      let path = sourceRootDir mode </> sourceFile programId
      exists <- doesFileExist path
      if exists then return (Just path) else return Nothing

noModuleFinder :: String -> IO (Maybe FilePath)
noModuleFinder _ = return Nothing

buildBaseIfNeeded :: Context -> Text -> IO CompileStatus
buildBaseIfNeeded ctx ver = do
  codeExists <- doesFileExist (baseCodeFile ver)
  symbolsExist <- doesFileExist (baseSymbolFile ver)
  if not codeExists || not symbolsExist
    then MSem.with (baseSem ctx) $ withSystemTempDirectory "genbase" $ \tmpdir -> do
      let linkMain = tmpdir </> "LinkMain.hs"
      let linkBase = tmpdir </> "LinkBase.hs"
      let err = tmpdir </> "output.txt"
      generateBaseBundle basePaths baseIgnore "codeworld" linkMain linkBase
      let stage = GenBase "LinkBase" linkBase (baseCodeFile ver) (baseSymbolFile ver)
      compileSource stage linkMain noModuleFinder err "codeworld" False
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
  status <-
    MSem.with (errorSem ctx) $ MSem.with (compileSem ctx) $
      compileSource ErrorCheck srcFile (projectModuleFinder mode) errFile (getMode mode) False
  hasOutput <- doesFileExist errFile
  output <- if hasOutput then B.readFile errFile else return B.empty
  return (status, output)

getMode :: BuildMode -> String
getMode (BuildMode m) = m
