{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

module CodeWorld.Compile.Obfuscate (processObfuscation) where

import CodeWorld.Compile.Framework
import CodeWorld.Compile.Requirements.Eval
import CodeWorld.Compile.Requirements.Language
import CodeWorld.Compile.Requirements.Types
import Codec.Compression.Zlib
import Control.Exception
import Control.Monad
import Control.Monad.State
import Data.Array
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as B (fromStrict, toStrict)
import Data.Char
import Data.Either
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Language.Haskell.Exts
import System.IO.Unsafe
import Text.Regex.TDFA
import Text.Regex.TDFA.Text
import Data.Bifunctor (second)

obfuscateMarker :: Text
obfuscateMarker = "{-+[[:space:]]*OBFUSCATE[[:space:]]*-}"

obfuscatedPattern :: Text
obfuscatedPattern = "{-+[[:space:]]*OBFUSCATED\\b((\n|[^-]|-[^}])*)-}"

runObfuscation :: MonadCompile m => FilePath -> m ()
runObfuscation path = do
  code <- decodeUtf8 <$> getSourceCode path
  let match = code =~ obfuscateMarker :: Text
  unless (T.null match) $ do
   let markerRemoved = T.replace match "" code
       obfuscated = T.unpack $ obfuscate [markerRemoved]
   addDiagnostics 
    [ ( noSrcSpan
      , CompileSuccess
      , "Obfuscated code:\n" ++ obfuscated
      )
    ]

runDeobfuscation :: MonadCompile m => FilePath -> m Bool
runDeobfuscation path = do
  code <- decodeUtf8 <$> getSourceCode path
  let matches = code =~ obfuscatedPattern :: MatchArray
  unless (null (indices matches)) $ do
    let (obfOff, obfLen) = matches ! 1 
        deobfuscated = head <$> deobfuscate (T.take obfLen (T.drop obfOff code))
    case deobfuscated of
      Nothing -> addDiagnostics [(noSrcSpan, CompileError, "Failed to deobfuscate code.")]
      Just originalCode -> do
        let (comOff, comLen) = matches ! 0
            unobfuscatedCode = T.take comOff code <> originalCode <> T.drop (comOff + comLen) code
        liftIO $ T.writeFile path unobfuscatedCode
        
  pure (not $ null matches)

processObfuscation :: MonadCompile m => m ()
processObfuscation = do
  sources <- gets compileSourcePaths
  forM_ sources $ \source -> do
    ranDeobfuscation <- runDeobfuscation source
    unless ranDeobfuscation (runObfuscation source) 

extractSubmatches :: FilePath -> Text -> Text -> [Text]
extractSubmatches f pattern src =
  [ T.take len (T.drop off src)
    | matchArray :: MatchArray <- src =~ pattern,
      rangeSize (bounds matchArray) > 1,
      let (off, len) = matchArray ! 1
  ]

obfuscate :: [Text] -> Text
obfuscate =
  wrapWithPrefix 60 "\n    " . decodeUtf8 . B64.encode
    . B.toStrict
    . compress
    . B.fromStrict
    . encodeUtf8
    . T.pack
    . show
    . map T.unpack

deobfuscate :: Text -> Maybe [Text]
deobfuscate =
  fmap (map T.pack . read . T.unpack . decodeUtf8)
    . partialToMaybe
    . B.toStrict
    . decompress
    . B.fromStrict
    . B64.decodeLenient
    . encodeUtf8
    . T.filter (not . isSpace)


wrapWithPrefix :: Int -> Text -> Text -> Text
wrapWithPrefix n pre txt = T.concat (parts txt)
  where
    parts t
      | T.length t < n = [pre <> t]
      | otherwise =
        let (a, b) = T.splitAt n t
         in pre <> a : parts b

partialToMaybe :: a -> Maybe a
partialToMaybe =
  (eitherToMaybe :: Either SomeException a -> Maybe a)
    . unsafePerformIO
    . try
    . evaluate

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just
