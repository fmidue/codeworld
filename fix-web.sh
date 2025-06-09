#!/bin/bash

set -u

cp codeworld-base/dist/doc/html/codeworld-base/codeworld-base.txt web/codeworld-base.txt
grep -r -s -h 'pattern\s*[A-Za-z_0-9]*\s*::.*' /home/codeworld/codeworld-base >> $HOME/web/codeworld-base.txt


cp -r build/mirrored/ web/mirrored

cp build/CodeMirror/codemirror-compressed.js web/js/codemirror-compressed.js

cp -r third_party/SourceCodePro web/SourceCodePro

cp third_party/jsdiff/diff.min.js web/js/diff.min.js

cp third_party/details-element-polyfill/details-element-polyfill.js web/js/details-element-polyfill.js

mkdir -p web/js/codemirror-buttons/
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
