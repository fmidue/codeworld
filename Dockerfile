FROM debian:buster
RUN useradd -ms /bin/bash codeworld

# Install dependencies
RUN apt-get update -y
RUN apt-get install -y sudo pkg-config git curl wget bzip2 xz-utils psmisc zlib1g-dev libncurses5 libncurses5-dev make gcc g++ libgmp-dev gnupg patch autoconf automake libtinfo-dev libssl-dev

RUN curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
RUN apt-get install -y nodejs
RUN sudo ln -s /usr/bin/node /usr/bin/nodejs

ENV PATH /codeworld/build/bin:/home/codeworld/.ghcup/bin:/home/codeworld/.cabal/bin:$PATH

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
RUN ghcup upgrade


## Install GHC
RUN ghcup install 8.6.5
RUN ghcup set 8.6.5
RUN ghcup install-cabal 2.4.1.0

RUN cabal update --index-state='2023-02-09T01:33:22Z'


## Install ghcjs

RUN cabal v2-install alex
RUN cabal v2-install happy-1.19.9 --overwrite-policy=always

RUN git clone --recurse-submodules --branch ghc-8.6 --single-branch https://github.com/ghcjs/ghcjs.git /codeworld/build/ghcjs

WORKDIR /codeworld/build/ghcjs

RUN git checkout eeeb0cde48e093e278fc1a4f418b48a2d23aa08c
RUN git submodule update --init
RUN patch -p0 -u -d /codeworld/build < /codeworld/ghc-artifacts/ghcjs-8.6-default-main.patch
RUN patch -p0 -u -d /codeworld/build < /codeworld/ghc-artifacts/ghcjs-8.6-dedup-fix.patch
RUN ./utils/makePackages.sh

RUN cabal v2-install . --symlink-bindir=/codeworld/build/bin -j1 --disable-documentation --overwrite-policy=always

RUN ls /home/codeworld/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp /home/codeworld/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-boot /codeworld/build/bin/ghcjs-boot-new
RUN ls /home/codeworld/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp /home/codeworld/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-run /codeworld/build/bin/ghcjs-run-new
RUN ls /home/codeworld/.cabal/store/ghc-8.6.5/ | grep ghcjs-8.6.0.1 | xargs -i sudo cp /home/codeworld/.cabal/store/ghc-8.6.5/{}/libexec/ghcjs-dumparchive /codeworld/build/bin/ghcjs-dumparchive-new

RUN mv /codeworld/build/bin/ghcjs-boot-new /codeworld/build/bin/ghcjs-boot
RUN mv /codeworld/build/bin/ghcjs-run-new /codeworld/build/bin/ghcjs-run
RUN mv /codeworld/build/bin/ghcjs-dumparchive-new /codeworld/build/bin/ghcjs-dumparchive

WORKDIR /codeworld/build/ghcjs

RUN ghcjs-boot -j1 --no-prof --no-haddock -s lib/boot/ --with-ghcjs-bin /codeworld/build/bin

## Install tools to build CodeMirror editor.

WORKDIR /codeworld/build

RUN git clone https://github.com/codemirror/CodeMirror.git

WORKDIR /codeworld/build/CodeMirror

RUN git checkout dde0e5cb51b243c61de9c43405b60c69a86dfb24

RUN npm install

RUN npm install -s uglify-js https://github.com/angelozerr/CodeMirror-Extension

## Fetch third_party/blockly submodule

WORKDIR /codeworld

RUN git submodule init
RUN git submodule update

RUN git config core.hooksPath .githooks

# Build codeworld

RUN /codeworld/mirror/get_mirrored

RUN bash -c "source base.sh && cabal_install --ghcjs ./codeworld-prediction ./codeworld-error-sanitizer ./codeworld-api ./codeworld-base ./codeworld-game-api ./codeworld-available-pkgs"

RUN ghcjs-pkg hide base-compat
RUN ghcjs-pkg hide ghcjs-dom-jsffi
RUN ghcjs-pkg hide matrices
RUN ghcjs-pkg hide simple-affine-space
RUN ghcjs-pkg hide newtype
RUN ghcjs-pkg hide non-empty
RUN ghcjs-pkg hide hgeometry-combinatorial
RUN ghcjs-pkg hide Cabal
RUN ghcjs-pkg hide cabal-doctest
RUN ghcjs-pkg hide some

RUN node /codeworld/build/bin/find-dup-modules.jsexe/all.js /home/codeworld/.ghcjs/x86_64-linux-8.6.0.1-8.6.5/ghcjs/package.conf.d/package.cache

WORKDIR /codeworld/codeworld-base

RUN cabal configure --ghcjs
RUN cabal haddock --html
RUN cabal haddock --hoogle

RUN rm /codeworld/web/codeworld-base.txt
RUN cp /codeworld/codeworld-base/dist/doc/html/codeworld-base/codeworld-base.txt /codeworld/web/codeworld-base.txt
RUN grep -r -s -h 'pattern\s*[A-Za-z_0-9]*\s*::.*' . >> /codeworld/web/codeworld-base.txt

WORKDIR /codeworld/codeworld-api

RUN cabal configure --ghcjs
RUN cabal haddock --html
RUN cabal haddock --hoogle

WORKDIR /codeworld

RUN bash -c "source base.sh && cabal_install ./codeworld-server ./codeworld-error-sanitizer ./codeworld-compiler ./codeworld-requirements ./codeworld-game-api ./codeworld-prediction ./codeworld-api ./codeworld-game-server ./codeworld-account ./codeworld-auth"

RUN bash -c "source base.sh && cabal_install --ghcjs ./funblocks-client"

WORKDIR /codeworld/build/CodeMirror

RUN node_modules/uglify-js/bin/uglifyjs lib/codemirror.js addon/dialog/dialog.js addon/display/placeholder.js addon/display/rulers.js addon/edit/matchbrackets.js addon/hint/show-hint.js addon/lint/lint.js addon/runmode/runmode.js addon/scroll/annotatescrollbar.js addon/search/match-highlighter.js addon/search/matchesonscrollbar.js addon/search/search.js addon/search/searchcursor.js addon/selection/active-line.js mode/haskell/haskell.js node_modules/codemirror-extension/addon/hover/text-hover.js -c -m > codemirror-compressed.js 

WORKDIR /codeworld

RUN rm -r /codeworld/web/mirrored /codeworld/web/ims /codeworld/web/help/ims /codeworld/web/blockly /codeworld/web/SourceCodePro /codeworld/web/doc /codeworld/web/doc-haskell

RUN cp -r /codeworld/build/mirrored/ /codeworld/web/mirrored
RUN cp /codeworld/build/CodeMirror/codemirror-compressed.js /codeworld/web/js/codemirror-compressed.js
RUN cp -r /codeworld/third_party/SourceCodePro /codeworld/web/SourceCodePro
RUN cp /codeworld/third_party/jsdiff/diff.min.js /codeworld/web/js/diff.min.js
RUN cp /codeworld/third_party/details-element-polyfill/details-element-polyfill.js /codeworld/web/js/details-element-polyfill.js
RUN cp /codeworld/third_party/codemirror-buttons/buttons.js /codeworld/web/js/codemirror-buttons/buttons.js
RUN cp -r /codeworld/codeworld-base/dist/doc/html/codeworld-base /codeworld/web/doc
RUN cp -r /codeworld/codeworld-api/dist/doc/html/codeworld-api /codeworld/web/doc-haskell
RUN cp /codeworld/web/env.html /codeworld/web/index.html
RUN cp /codeworld/web/gallery.html /codeworld/web/gallery-icfp17.html
RUN cp -r /codeworld/third_party/blockly /codeworld/web/blockly
RUN cp /codeworld/funblocks-client/dist/build/funblocks-client/funblocks-client.jsexe/lib.js /codeworld/web/js/blocks_lib.js
RUN cp /codeworld/funblocks-client/dist/build/funblocks-client/funblocks-client.jsexe/out.js /codeworld/web/js/blocks_out.js
RUN cp /codeworld/funblocks-client/dist/build/funblocks-client/funblocks-client.jsexe/rts.js /codeworld/web/js/blocks_rts.js
RUN cp /codeworld/funblocks-client/dist/build/funblocks-client/funblocks-client.jsexe/runmain.js /codeworld/web/js/blocks_runmain.js
RUN cp /codeworld/build/CodeMirror/theme/ambiance.css /codeworld/web/css/ambiance.css
RUN cp /codeworld/build/CodeMirror/lib/codemirror.css /codeworld/web/css/codemirror.css
RUN cp /codeworld/build/CodeMirror/addon/lint/lint.css /codeworld/web/css/lint.css
RUN cp /codeworld/build/CodeMirror/addon/hint/show-hint.css /codeworld/web/css/show-hint.css
RUN cp -r /codeworld/third_party/MaterialDesign /codeworld/web/ims
RUN cp -r /codeworld/third_party/MaterialDesign /codeworld/web/help/ims

CMD ./run.sh
