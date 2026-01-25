#!/bin/bash

# Copyright 2020 The CodeWorld Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source base.sh

run . rm -rf data/*/build
rm -rf $(for fn in $(find data/base -atime +20 -regex .*\\.js$ ); do dirname $fn; done)

fuser -k -n tcp 8080
fuser -k -n tcp 9160

# Run migration of project directory structure for codeworld-server.
mkdir -p data/codeworld/projects
mkdir -p data/haskell/projects
mkdir -p data/blocklyXML/projects

mkdir -p log

# Run a server in a loop, restarting on crash
run_server() {
  local name=$1
  shift
  while true; do
    echo "$(date): Starting $name" >> log/server-restarts.log
    "$@"
    exit_code=$?
    echo "$(date): $name exited with code $exit_code" >> log/server-restarts.log

    # Exit codes: 0=clean, 137=SIGKILL (from fuser -k), 143=SIGTERM
    # Only restart on unexpected crashes (like 139=SIGSEGV)
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 137 ] || [ $exit_code -eq 143 ]; then
      break
    fi

    sleep 2
  done
}

run_server codeworld-game-server codeworld-game-server +RTS -T &
run_server codeworld-server codeworld-server -p 8080 --no-access-log
