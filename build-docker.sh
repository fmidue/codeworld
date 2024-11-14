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

docker cp codeworld:/opt/codeworld/codeworld.keter codeworld.tar

docker rm codeworld

