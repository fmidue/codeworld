#!/usr/bin/env zsh

set -eux

CACHE=.cache
CACHE_TO=--cache-to=type=local,dest=${CACHE}/dist,mode=max

mkdir -p ${CACHE}/base/ ${CACHE}/dist/

# Create a new builder instance

echo "Creating a new builder instance..."

docker buildx create --use --name=codeworld-builder --driver docker-container --node larger_log --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=500000000

# Build the dist image

echo "Building the dist image..."

docker buildx build --load --cache-from=type=local,src=${CACHE}/dist ${CACHE_TO} --tag codeworld:fmi --file Dockerfile.prod .

# Copy keter file from image

docker create --name codeworld codeworld:fmi

docker cp codeworld:/opt/codeworld/codeworld.keter codeworld.keter

docker rm codeworld

TMPDIR=$(mktemp -d)
ARCHIVEPATH="$(pwd)/codeworld.keter"

# Create bundle

cd $TMPDIR

echo "Tempdir: $TMPDIR"

tar xf "$ARCHIVEPATH"

cd -

rm -rf codeworld.keter

tar czf codeworld.keter config/keter.yaml -C $TMPDIR .cabal/ .ghcjs/ base.sh run.sh build/ codeworld-base/ web/

rm -rf $TMPDIR
