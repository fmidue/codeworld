#!/bin/bash

set -eux

mkdir -p .cache/base/ .cache/dist/

# Create a new builder instance

echo "Creating a new builder instance..."

docker buildx create --use --name=codeworld-builder --driver docker-container --node larger_log --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=500000000

# Build the dist image

echo "Building the dist image..."

docker buildx build --load --cache-from=type=local,src=.cache/dist --cache-to=type=local,dest=.cache/dist,mode=max --tag codeworld:fmi --file Dockerfile.prod .

# Copy keter file from image

# echo "Copying keter file from image..."

# ID=$(docker create codeworld:fmi)

# docker cp $ID:/home/codeworld/codeworld.keter - > extracted.tar

# docker rm -v $ID

# tar -xvf extracted.tar

# rm extracted.tar

# # Copy keter config into keter file

# echo "Copying keter config into keter file..."

# tar -rvf codeworld.keter config/keter.yaml