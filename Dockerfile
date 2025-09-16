FROM ubuntu:24.04 AS base
ARG DEBIAN_FRONTEND=noninteractive
RUN <<INSTALL_DEPENDENCIES
set -e
apt-get update && apt-get upgrade -y

apt-get install -y python3 build-essential curl libffi-dev libffi8 libgmp-dev libgmp10 libncurses-dev libncursesw6 libtinfo6 sudo pkg-config git wget bzip2 xz-utils psmisc zlib1g-dev make gcc g++ gnupg patch autoconf automake libtinfo-dev libssl-dev ca-certificates
curl -sSf https://downloads.haskell.org/~ghcup/$(uname -m)-$(uname -s | awk '{print tolower($0)}')-ghcup > /usr/bin/ghcup && chmod +x /usr/bin/ghcup

useradd -ms /bin/bash -d /opt/codeworld codeworld

echo "codeworld ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
INSTALL_DEPENDENCIES

ENV CODEWORLD_DIR=/opt/codeworld

WORKDIR $CODEWORLD_DIR
RUN chown codeworld:codeworld .
USER codeworld

ENV CABAL_DIR=$CODEWORLD_DIR/.cabal

WORKDIR $CODEWORLD_DIR

ENV PATH=$CODEWORLD_DIR/.ghcup/bin:$PATH
ENV PATH=$CODEWORLD_DIR/.cabal/bin:$PATH
RUN <<PREPARE_INSTALLATION
set -e
ghcup upgrade
ghcup install 8.6.5
ghcup set 8.6.5
ghcup install-cabal 2.4.1.0


cabal update --index-state='2023-02-09T01:33:22Z'

cabal v2-install alex
cabal v2-install happy-1.19.9 --overwrite-policy=always


sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

sudo apt-get update && sudo apt-get install nodejs -y
PREPARE_INSTALLATION

FROM base AS builder

WORKDIR $CODEWORLD_DIR

###############################################
### Install GHCJS                           ###
###############################################

RUN git clone --recurse-submodules --branch ghc-8.6 --single-branch https://github.com/ghcjs/ghcjs.git build/ghcjs

COPY --chown=codeworld ghc-artifacts/ ghc-artifacts/

WORKDIR $CODEWORLD_DIR/build/ghcjs

RUN <<GHC_JS_PREPARE
set -e
git submodule update --init
patch -p0 -u -d $CODEWORLD_DIR/build < $CODEWORLD_DIR/ghc-artifacts/ghcjs-8.6-default-main.patch
patch -p0 -u -d $CODEWORLD_DIR/build < $CODEWORLD_DIR/ghc-artifacts/ghcjs-8.6-dedup-fix.patch
patch -p0 -u -d $CODEWORLD_DIR/build < $CODEWORLD_DIR/ghc-artifacts/ghcjs-8.6-boot-fix.patch

./utils/boot || true

cabal v2-install . --symlink-bindir=$CODEWORLD_DIR/build/bin -j1 --disable-documentation --overwrite-policy=always

ls $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp --remove-destination $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-boot $CODEWORLD_DIR/build/bin/ghcjs-boot
ls $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp --remove-destination $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-run $CODEWORLD_DIR/build/bin/ghcjs-run
ls $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp --remove-destination $CODEWORLD_DIR/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-dumparchive $CODEWORLD_DIR/build/bin/ghcjs-dumparchive
GHC_JS_PREPARE


WORKDIR $CODEWORLD_DIR/build/ghcjs

ENV PATH=$CODEWORLD_DIR/build/bin:$PATH

RUN ghcjs-boot -j1 --no-prof --no-haddock -s lib/boot/ 

###############################################
### Install CodeMirror                      ###
###############################################

WORKDIR $CODEWORLD_DIR/build

RUN git clone https://github.com/codemirror/CodeMirror.git

WORKDIR $CODEWORLD_DIR/build/CodeMirror

RUN <<CODE_MIRROR_PREPARE
set -e
git checkout dde0e5cb51b243c61de9c43405b60c69a86dfb24

npm install

npm install -s uglify-js https://github.com/angelozerr/CodeMirror-Extension
CODE_MIRROR_PREPARE

###############################################
### Install third party modules             ###
###############################################

WORKDIR $CODEWORLD_DIR

COPY --chown=codeworld third_party/ third_party/

RUN <<FETCH_SUBMODULES
set -e
git init
git submodule init
git submodule update
FETCH_SUBMODULES

###############################################
### Build codeworld                         ###
###############################################

COPY --chown=codeworld mirror/ mirror/
COPY --chown=codeworld base.sh ./

RUN $CODEWORLD_DIR/mirror/get_mirrored

COPY --chown=codeworld codeworld-error-sanitizer/ codeworld-error-sanitizer/ 
COPY --chown=codeworld codeworld-api/ codeworld-api/
COPY --chown=codeworld codeworld-base/ codeworld-base/
COPY --chown=codeworld codeworld-available-pkgs/ codeworld-available-pkgs/

RUN <<BUILD_CODEWORLD_MIRROR
set -e
bash -c "source base.sh && cabal_install --ghcjs ./codeworld-error-sanitizer ./codeworld-api ./codeworld-base ./codeworld-available-pkgs"

ghcjs-pkg hide base-compat
ghcjs-pkg hide ghcjs-dom-jsffi
ghcjs-pkg hide Cabal
ghcjs-pkg hide some

node $CODEWORLD_DIR/build/bin/find-dup-modules.jsexe/all.js $CODEWORLD_DIR/.ghcjs/x86_64-linux-8.6.0.1-8.6.5/ghcjs/package.conf.d/package.cache
BUILD_CODEWORLD_MIRROR

WORKDIR $CODEWORLD_DIR/codeworld-base

RUN <<BUILD_CODEWORLD_BASE
set -e
cabal configure --ghcjs
cabal haddock --html
cabal haddock --hoogle
BUILD_CODEWORLD_BASE

WORKDIR $CODEWORLD_DIR/codeworld-api

RUN <<BUILD_CODEWORLD_API
set -e
cabal configure --ghcjs
cabal haddock --html
cabal haddock --hoogle
BUILD_CODEWORLD_API

WORKDIR $CODEWORLD_DIR

COPY --chown=codeworld codeworld-server/ codeworld-server/
COPY --chown=codeworld codeworld-compiler/ codeworld-compiler/

RUN bash -c "source base.sh && cabal_install ./codeworld-server ./codeworld-error-sanitizer ./codeworld-compiler ./codeworld-api"

WORKDIR $CODEWORLD_DIR/build/CodeMirror

RUN node_modules/uglify-js/bin/uglifyjs lib/codemirror.js addon/dialog/dialog.js addon/display/placeholder.js addon/display/rulers.js addon/edit/matchbrackets.js addon/hint/show-hint.js addon/lint/lint.js addon/runmode/runmode.js addon/scroll/annotatescrollbar.js addon/search/match-highlighter.js addon/search/matchesonscrollbar.js addon/search/search.js addon/search/searchcursor.js addon/selection/active-line.js mode/haskell/haskell.js node_modules/codemirror-extension/addon/hover/text-hover.js -c -m > codemirror-compressed.js 

###############################################
### Fix web directory                       ###
###############################################
WORKDIR $CODEWORLD_DIR

COPY --chown=codeworld web/ web/
COPY --chown=codeworld run.sh create-symlinks.sh ./

RUN <<KETER
set -e
./create-symlinks.sh

tar -cf codeworld.keter .cabal/store/ghc-8.6.5/ .ghcjs/ base.sh build/bin/codeworld-server build/bin/ghcjs build/lib/x86_64-linux-ghcjs-8.6.0.1-ghc8_6_5 codeworld-base/dist/doc/html/codeworld-base/codeworld-base.txt run.sh web/
KETER

ENTRYPOINT [ "./run.sh" ]
