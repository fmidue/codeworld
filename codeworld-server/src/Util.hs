{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC
    -fno-warn-name-shadowing
#-}

{-
  Copyright 2019 The CodeWorld Authors. All rights reserved.

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
module Util where

import CodeWorld.Account (UserId(..))
import Control.Exception
import Control.Monad
import qualified Crypto.Hash as Crypto
import Data.Aeson
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.List (sort)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LB
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LT
import System.Directory
import System.File.Tree (Tree(Node), toTree, copyTo_, getDirectory)
import System.FilePath
import System.IO.Error
import System.Posix.Files

import Model

newtype BuildMode = BuildMode String
    deriving (Eq)

newtype ProgramId = ProgramId
    { unProgramId :: Text
    } deriving (Eq)

newtype ProjectId = ProjectId
    { unProjectId :: Text
    } deriving (Eq)

newtype DeployId = DeployId
    { unDeployId :: Text
    } deriving (Eq)

newtype DirId = DirId
    { unDirId :: Text
    } deriving (Eq)

newtype ShareId = ShareId
    { unShareId :: Text
    } deriving (Eq)

type BaseVersion = Text

autocompletePath :: FilePath
autocompletePath = "web/codeworld-base.txt"

clientIdPath :: FilePath
clientIdPath = "web/clientId.txt"

baseRootDir :: FilePath
baseRootDir = "data/base"

sourceRootDir :: BuildMode -> FilePath
sourceRootDir (BuildMode m) = "data" </> m </> "user"

buildRootDir :: BuildMode -> FilePath
buildRootDir (BuildMode m) = "data" </> m </> "build"

shareRootDir :: BuildMode -> FilePath
shareRootDir (BuildMode m) = "data" </> m </> "share"

projectRootDir :: BuildMode -> FilePath
projectRootDir (BuildMode m) = "data" </> m </> "projects"

deployRootDir :: BuildMode -> FilePath
deployRootDir (BuildMode m) = "data" </> m </> "deploy"

baseCodeFile :: BaseVersion -> FilePath
baseCodeFile ver = baseRootDir </> T.unpack ver </> "base.js"

baseSymbolFile :: BaseVersion -> FilePath
baseSymbolFile ver = baseRootDir </> T.unpack ver </> "base.symbs"

sourceBase :: ProgramId -> FilePath
sourceBase (ProgramId p) =
    let s = T.unpack p
    in take 3 s </> s

sourceFile :: ProgramId -> FilePath
sourceFile programId = sourceBase programId <.> "hs"

sourceXML :: ProgramId -> FilePath
sourceXML programId = sourceBase programId <.> "xml"

targetFile :: ProgramId -> FilePath
targetFile programId = sourceBase programId <.> "js"

resultFile :: ProgramId -> FilePath
resultFile programId = sourceBase programId <.> "err.txt"

baseVersionFile :: ProgramId -> FilePath
baseVersionFile programId = sourceBase programId <.> "basever"

auxiliaryFiles :: ProgramId -> [FilePath]
auxiliaryFiles programId =
    [ sourceBase programId <.> "js_hi"
    , sourceBase programId <.> "js_o"
    , sourceBase programId <.> "jsexe" </> "index.html"
    , sourceBase programId <.> "jsexe" </> "lib.js"
    , sourceBase programId <.> "jsexe" </> "manifest.webapp"
    , sourceBase programId <.> "jsexe" </> "out.js"
    , sourceBase programId <.> "jsexe" </> "out.stats"
    , sourceBase programId <.> "jsexe" </> "rts.js"
    , sourceBase programId <.> "jsexe" </> "runmain.js"
    ]

deployLink :: DeployId -> FilePath
deployLink (DeployId d) =
    let s = T.unpack d
    in take 3 s </> s

shareLink :: ShareId -> FilePath
shareLink (ShareId sh) =
    let s = T.unpack sh
    in take 3 s </> s

userProjectDir :: BuildMode -> UserId -> FilePath
userProjectDir mode (UserId userIdRaw) = projectRootDir mode </> userIdRaw

projectBase :: ProjectId -> FilePath
projectBase (ProjectId p) = T.unpack p

projectFile :: ProjectId -> FilePath
projectFile projectId = projectBase projectId <.> "cw"

sourceToProgramId :: ByteString -> ProgramId
sourceToProgramId = ProgramId . hashToId "P"

sourceToDeployId :: ByteString -> DeployId
sourceToDeployId = DeployId . hashToId "D" . ("DEPLOY_ID" <>)

nameToProjectId :: Text -> ProjectId
nameToProjectId = ProjectId . hashToId "S" . T.encodeUtf8

dirBase :: DirId -> FilePath
dirBase (DirId d) = T.unpack d

nameToDirId :: Text -> DirId
nameToDirId = DirId . hashToId "D" . T.encodeUtf8

ensureSourceDir :: BuildMode -> ProgramId -> IO ()
ensureSourceDir mode (ProgramId p) = createDirectoryIfMissing True dir
  where
    dir = sourceRootDir mode </> take 3 (T.unpack p)

ensureShareDir :: BuildMode -> ShareId -> IO ()
ensureShareDir mode (ShareId s) = createDirectoryIfMissing True dir
  where
    dir = shareRootDir mode </> take 3 (T.unpack s)

ensureUserProjectDir :: BuildMode -> UserId -> IO ()
ensureUserProjectDir mode userId =
    createDirectoryIfMissing True (userProjectDir mode userId)

ensureUserBaseDir :: BuildMode -> UserId -> FilePath -> IO ()
ensureUserBaseDir mode userId path = do
    ensureUserProjectDir mode userId
    createDirectoryIfMissing
        False
        (userProjectDir mode userId </> takeDirectory path)

ensureUserDir :: BuildMode -> UserId -> FilePath -> IO ()
ensureUserDir mode userId path = do
    ensureUserProjectDir mode userId
    createDirectoryIfMissing False (userProjectDir mode userId </> path)

ensureProjectDir :: BuildMode -> UserId -> FilePath -> ProjectId -> IO ()
ensureProjectDir mode userId path projectId = do
    ensureUserProjectDir mode userId
    createDirectoryIfMissing False (dropFileName f)
  where
    f = userProjectDir mode userId </> path </> projectFile projectId

listDirectoryWithPrefix :: FilePath -> IO [FilePath]
listDirectoryWithPrefix filePath = map (filePath </>) <$> listDirectory filePath

dirFilter :: [FilePath] -> Char -> [FilePath]
dirFilter dirs char = filter (\x -> head (takeBaseName x) == char) dirs

projectFileNames :: FilePath -> IO [Text]
projectFileNames dir = do
    subHashedDirs <- listDirectoryWithPrefix dir
    let hashedFiles = dirFilter subHashedDirs 'S'
    projects <- fmap catMaybes $
        forM hashedFiles $ \f -> do
            exists <- doesFileExist f
            if exists
                then decode <$> LB.readFile f
                else return Nothing
    return $ map projectName projects

projectDirNames :: FilePath -> IO [Text]
projectDirNames dir = do
    subHashedDirs <- listDirectoryWithPrefix dir
    let hashedDirs = dirFilter subHashedDirs 'D'
    dirs <- mapM (\x -> B.readFile $ x </> "dir.info") hashedDirs
    return $ map T.decodeUtf8 dirs

writeDeployLink :: BuildMode -> DeployId -> ProgramId -> IO ()
writeDeployLink mode deployId (ProgramId p) = do
    createDirectoryIfMissing True (dropFileName f)
    B.writeFile f (T.encodeUtf8 p)
  where
    f = deployRootDir mode </> deployLink deployId

resolveDeployId :: BuildMode -> DeployId -> IO ProgramId
resolveDeployId mode deployId = ProgramId . T.decodeUtf8 <$> B.readFile f
  where
    f = deployRootDir mode </> deployLink deployId

isDir :: FilePath -> IO Bool
isDir path = do
    status <- getFileStatus path
    return $ isDirectory status

getFilesRecursive :: FilePath -> IO [FilePath]
getFilesRecursive path = do
    dirBool <- isDir path
    case dirBool of
        True -> do
            contents <- listDirectory path
            concat <$> mapM (getFilesRecursive . (path </>)) contents
        False -> return [path]

dirToCheckSum :: FilePath -> IO Text
dirToCheckSum path = do
    files <- getFilesRecursive path
    fileContents <- mapM B.readFile files
    let cryptoContext = Crypto.hashInitWith Crypto.MD5
    return $
        (T.pack "F" <>) .
        T.decodeUtf8 .
        BC.takeWhile (/= '=') .
        BC.map toWebSafe .
        B64.encode .
        convert . Crypto.hashFinalize . Crypto.hashUpdates cryptoContext $
        fileContents
  where
    toWebSafe '/' = '_'
    toWebSafe '+' = '-'
    toWebSafe c = c

hashToId :: Text -> ByteString -> Text
hashToId pfx =
    (pfx <>) .
    T.decodeUtf8 .
    BC.takeWhile (/= '=') .
    BC.map toWebSafe . B64.encode . convert . Crypto.hashWith Crypto.MD5
  where
    toWebSafe '/' = '_'
    toWebSafe '+' = '-'
    toWebSafe c = c

copyDirIfExists :: FilePath -> FilePath -> IO ()
copyDirIfExists folder1 folder2 = getDirectory folder1 >>= copyTo_ folder2

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists fileName = removeFile fileName `catch` handleExists
  where
    handleExists e
        | isDoesNotExistError e = return ()
        | otherwise = throwIO e

removeDirectoryIfExists :: FilePath -> IO ()
removeDirectoryIfExists dirName =
    removeDirectoryRecursive dirName `catch` handleExists
  where
    handleExists e
        | isDoesNotExistError e = return ()
        | otherwise = throwIO e

loadDumpedTree :: BuildMode -> UserId -> IO DirTree
loadDumpedTree mode uid = do
    let file = userProjectDir mode uid </> "tree.info"
    exists <- doesFileExist file
    realTree <- getDirectoryTree mode uid
    case exists of
        False -> return realTree
        True -> do
            content  <- LB.readFile file
            return $ case decode content of
                Nothing -> realTree
                Just dumpedTree -> case compareTrees realTree (Dir "root" dumpedTree) of
                    True  -> Dir "root" dumpedTree
                    False -> realTree

getDirectoryTree :: BuildMode -> UserId -> IO DirTree
getDirectoryTree mode uid = do
    fileTree <- getDirectory $ userProjectDir mode uid
    let (Node rootPath children) = toTree fileTree
    children' <- mapM (constructTree rootPath) $ filter notInfo children
    return $ Dir "root" children'
    where
        constructTree :: FilePath -> Tree FilePath -> IO DirTree
        constructTree prefix (Node path [(Node "dir.info" [])]) = do -- empty directory
            name <- B.readFile $ prefix </> path </> "dir.info"
            return $ Dir (T.decodeUtf8 name) []
        constructTree prefix (Node path []) = do
            let currentNode = prefix </> path
            source <- LB.readFile currentNode
            let Just project = decode source
            return $ Source (projectName project) $ LT.toStrict $ LT.decodeUtf8 source
        constructTree prefix (Node path children) = do
            name <- B.readFile $ prefix </> path </> "dir.info"
            children' <- mapM (constructTree $ prefix </> path) $ filter notInfo children
            return $ Dir (T.decodeUtf8 name) children'

        notInfo :: Tree FilePath -> Bool
        notInfo (Node "dir.info" []) = False
        notInfo (Node "tree.info" []) = False
        notInfo _ = True

-- If directory trees have same structure
-- in spite of different order of elements
compareTrees :: DirTree -> DirTree -> Bool
compareTrees (Source n1 s1) (Source n2 s2) = n1 == n2
compareTrees (Dir n1 chs1) (Dir n2 chs2) 
    | length chs1 == length chs2 = n1 == n2 && and (map (uncurry compareTrees) $ zip (sort chs1) (sort chs2))
    | otherwise = False
compareTrees _ _ = False