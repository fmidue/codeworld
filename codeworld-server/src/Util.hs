{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

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
module Util where

import Data.Text (Text, unpack)
import System.FilePath ((</>))

newtype BuildMode = BuildMode String
  deriving (Eq)

type BaseVersion = Text


baseRootDir :: FilePath
baseRootDir = "data/base"

baseCodeFile :: BaseVersion -> FilePath
baseCodeFile ver = baseRootDir </> unpack ver </> "base.js"

baseSymbolFile :: BaseVersion -> FilePath
baseSymbolFile ver = baseRootDir </> unpack ver </> "base.symbs"
