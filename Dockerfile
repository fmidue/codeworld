FROM debian:buster
RUN useradd -ms /bin/bash codeworld

# Install dependencies
RUN apt-get update -y
RUN apt-get install -y sudo pkg-config git curl wget bzip2 xz-utils psmisc zlib1g-dev libncurses5 libncurses5-dev make gcc g++ libgmp-dev gnupg patch autoconf automake libtinfo-dev libssl-dev

RUN curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
RUN apt-get install -y nodejs
RUN sudo ln -s /usr/bin/node /usr/bin/nodejs

RUN echo "codeworld ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /codeworld
RUN chown codeworld:codeworld .
USER codeworld
COPY --chown=codeworld . .

# Run installation

## Install ghcup

RUN mkdir -p /codeworld/build/.ghcup/bin
RUN curl -fsSL https://gitlab.haskell.org/haskell/ghcup/raw/master/ghcup > /codeworld/build/.ghcup/bin/ghcup
RUN chmod +x /codeworld/build/.ghcup/bin/ghcup
RUN /codeworld/build/.ghcup/bin/ghcup upgrade


## Install GHC
RUN /codeworld/build/.ghcup/bin/ghcup install 8.6.5
RUN /codeworld/build/.ghcup/bin/ghcup set 8.6.5
RUN /codeworld/build/.ghcup/bin/ghcup install-cabal 2.4.1.0
RUN sudo cp -rf /home/codeworld/.ghcup /codeworld/build

RUN sudo ln -s /home/codeworld/.ghcup/bin/cabal /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc-8.6 /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc-8.6.5 /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc-pkg /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc-pkg-8.6 /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/ghc-pkg-8.6.5 /usr/bin

RUN /codeworld/build/.ghcup/bin/cabal update --index-state='2023-02-09T01:33:22Z'


## Install ghcjs

# RUN /codeworld/build/.ghcup/bin/cabal v2-install alex --symlink-bindir=/codeworld/build/bin
# RUN /codeworld/build/.ghcup/bin/cabal v2-install happy-1.19.9 --symlink-bindir=/codeworld/build/bin --overwrite-policy=always
RUN /codeworld/build/.ghcup/bin/cabal v2-install alex
RUN /codeworld/build/.ghcup/bin/cabal v2-install happy-1.19.9 --overwrite-policy=always
RUN sudo cp -rf /home/codeworld/.cabal /codeworld/build
RUN sudo ln -s /home/codeworld/.cabal/bin/alex /usr/bin
RUN sudo ln -s /home/codeworld/.cabal/bin/happy /usr/bin


RUN git clone --recurse-submodules --branch ghc-8.6 --single-branch https://github.com/ghcjs/ghcjs.git /codeworld/build/ghcjs

WORKDIR /codeworld/build/ghcjs

RUN git checkout eeeb0cde48e093e278fc1a4f418b48a2d23aa08c
RUN git submodule update --init
RUN patch -p0 -u -d /codeworld/build < /codeworld/ghc-artifacts/ghcjs-8.6-default-main.patch
RUN patch -p0 -u -d /codeworld/build < /codeworld/ghc-artifacts/ghcjs-8.6-dedup-fix.patch
RUN ./utils/makePackages.sh
RUN cabal v2-install . --symlink-bindir=/codeworld/build/bin -j1 --disable-documentation --overwrite-policy=always

WORKDIR /codeworld/build/bin

RUN rm -f ghcjs-boot
RUN rm -f ghcjs-run
RUN rm -f ghcjs-dumparchive

RUN sudo ln -s /home/codeworld/.cabal/store/ghc-8.6.5/ghcjs-8.6.0.1-360405b9389c1ab6f9289e9dd522001d8aeab9e16ff23bc588fda3f2e06d65ad/libexec/ghcjs-boot ghcjs-boot
RUN sudo ln -s /home/codeworld/.cabal/store/ghc-8.6.5/ghcjs-8.6.0.1-360405b9389c1ab6f9289e9dd522001d8aeab9e16ff23bc588fda3f2e06d65ad/libexec/ghcjs-run ghcjs-run
RUN sudo ln -s /home/codeworld/.cabal/store/ghc-8.6.5/ghcjs-8.6.0.1-360405b9389c1ab6f9289e9dd522001d8aeab9e16ff23bc588fda3f2e06d65ad/libexec/ghcjs-dumparchive ghcjs-dumparchive

RUN sudo ln -s /codeworld/build/bin/haddock-ghcjs /usr/bin


RUN sudo ln -s /home/codeworld/.ghcup/bin/hsc2hs /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/hsc2hs-8.6 /usr/bin
RUN sudo ln -s /home/codeworld/.ghcup/bin/hsc2hs-8.6.5 /usr/bin


WORKDIR /codeworld/build/ghcjs

RUN /codeworld/build/bin/ghcjs-boot -j1 --no-prof --no-haddock -s lib/boot/ --with-ghcjs-bin /codeworld/build/bin

## Install tools to build CodeMirror editor.

WORKDIR /codeworld/build

RUN git clone https://github.com/codemirror/CodeMirror.git

WORKDIR /codeworld/build/CodeMirror

RUN git checkout dde0e5cb51b243c61de9c43405b60c69a86dfb24

RUN npm install

RUN npm install -s uglify-js https://github.com/angelozerr/CodeMirror-Extension

## Fetch third_party/blockly submodule

WORKDIR /codeworld/build

RUN git submodule init
RUN git submodule update

RUN git config core.hooksPath .githooks

WORKDIR /codeworld

RUN ./build.sh

# CMD ./run.sh
