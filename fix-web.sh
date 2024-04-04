#!/bin/bash

set -u

rm -rf web/codeworld-base.txt web/mirrored web/js/codemirror-compressed.js web/SourceCodePro web/js/diff.min.js web/js/details-element-polyfill.js web/js/codemirror-buttons/buttons.js web/doc web/doc-haskell web/index.html web/gallery.html web/gallery-icfp17.html web/blockly web/js/blocks_lib.js web/js/blocks_out.js web/js/blocks_rts.js web/js/blocks_ain.js web/css/ambiance.css web/css/codemirror.css web/css/lint.css web/css/show-hint.css web/ims web/help/ims 

cp codeworld-base/dist/doc/html/codeworld-base/codeworld-base.txt web/codeworld-base.txt
grep -r -s -h 'pattern\s*[A-Za-z_0-9]*\s*::.*' /home/codeworld/codeworld-base >> /home/codeworld/web/codeworld-base.txt


cp -r build/mirrored/ web/mirrored

cp build/CodeMirror/codemirror-compressed.js web/js/codemirror-compressed.js

cp -r third_party/SourceCodePro web/SourceCodePro

cp third_party/jsdiff/diff.min.js web/js/diff.min.js

cp third_party/details-element-polyfill/details-element-polyfill.js web/js/details-element-polyfill.js

cp third_party/codemirror-buttons/buttons.js web/js/codemirror-buttons/buttons.js

cp -r codeworld-base/dist/doc/html/codeworld-base web/doc

cp -r codeworld-api/dist/doc/html/codeworld-api web/doc-haskell

cp web/env.html web/index.html

cp -r third_party/blockly web/blockly

cp build/CodeMirror/theme/ambiance.css web/css/ambiance.css

cp build/CodeMirror/lib/codemirror.css web/css/codemirror.css

cp build/CodeMirror/addon/lint/lint.css web/css/lint.css

cp build/CodeMirror/addon/hint/show-hint.css web/css/show-hint.css

cp -r third_party/MaterialDesign web/ims

cp -r third_party/MaterialDesign web/help/ims