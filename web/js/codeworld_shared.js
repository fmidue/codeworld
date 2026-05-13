/*
 * Copyright 2020 The CodeWorld Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import * as Alert from './utils/alert.js';
import * as Html from './utils/html.js';
import { sendHttp } from './utils/network.js';

const hintBlacklist = [
  // Symbols that only exist to implement RebindableSyntax or map to
  // built-in Haskell types.
  'Bool',
  'IO',
  'fail',
  'fromCWText',
  'fromDouble',
  'fromInt',
  'fromInteger',
  'fromRational',
  'fromString',
  'ifThenElse',
  'toCWText',
  'toDouble',
  'toInt',

  // Deprecated exports.
  //'path',
  'thickPath',
  'text',
  'styledText',
  'collaborationOf',
  'simulationOf',
  'interactionOf',
  'debugInteractionOf',
  'debugSimulationOf',
  'cyan',
  'magenta',
  'azure',
  'chartreuse',
  'aquamarine',
  'violet',
  'rose',
  'hue',
  'saturation',
  'luminosity',
  'alpha',
];

const VAR_OR_CON = /^[a-zA-Z_][A-Za-z_0-9']*$/;
const QUALIFIER = /^[A-Z][A-Za-z_0-9']*[.]$/;

function definePanelExtension() {
  CodeMirror.defineExtension('addPanel', function (node) {
    const originWrapper = this.getWrapperElement();
    const wrapper = document.createElement('div');
    originWrapper.parentNode.insertBefore(wrapper, originWrapper);
    wrapper.appendChild(originWrapper);
    wrapper.insertBefore(node, wrapper.firstChild);
  });
}

// codeWorldSymbols is a variable containing annotations and documentation
// of builtin and user-defined variables.
// Expected format:
// codeWorldSymbols = {
//   codeWorldLogo: {
//     declaration: "codeWorldLogo :: Picture",
//     symbolStart: 0,
//     symbolEnd: 13,
//     insertText: "codeWorldLogo",
//     doc: "The CodeWorld logo."
//   }
// }
window.codeWorldSymbols = {};
window.codeWorldModules = {
  Prelude: {},
};
window.codeWorldBuiltins = {
  program: {
    declaration: 'program :: Program',
    doc: 'Your program.',
    symbolStart: 0,
    symbolEnd: 7,
    insertText: 'program',
  },
};

window.alreadyReportedErrors = new Set();

function getWordStart(word, line) {
  return line.indexOf(word);
}

function getWordEnd(word, line) {
  const wordStart = getWordStart(word, line);
  if (wordStart !== -1) {
    return wordStart + word.length;
  }
  return -1;
}

function parseSymbolsFromCurrentCode() {
  const lines = window.codeworldEditor.getValue().split('\n');
  const parseResults = {};
  let lineIndex = 0;

  const imports = [];

  lines.forEach((line) => {
    lineIndex++;

    const importExp = /^import\s+(qualified)?\s*([A-Z][A-Za-z0-9.']*)(\s+(as)\s+([A-Z][A-Za-z0-9.']*))?(\s+(hiding))?\s*([(]([^()]*|([(][^()]*[)])*)[)])?\s*$/;
    if (importExp.test(line)) {
      const match = importExp.exec(line);
      const qualified = Boolean(match[1]);
      const module = match[2];
      const asName = match[5] !== undefined ? match[5] : module;
      const hiding = Boolean(match[7]);
      const importList =
        match[9] &&
        match[9]
          .split(',')
          .map((s) => s.trim())
          .map((s) => (/[(].*[)]/.test(s) ? s.substr(1, s.length - 2) : s));
      imports.push({
        module: module,
        asName: asName,
        qualified: qualified,
        hiding: hiding,
        importList: importList,
      });
      return;
    }

    const docString = `Defined in your code on line ${lineIndex}.`;

    if (/^\w+\(.*/.test(line)) {
      // f(x, y) =
      const word = line.split('(')[0].trim();
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: word,
        insertText: word,
        doc: docString,
      };
    } else if (/^\S+\s*=/.test(line)) {
      // foo =
      const word = line.split('=')[0].trim();
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: word,
        insertText: word,
        doc: docString,
      };
    } else if (/^data\s.+/.test(line)) {
      // data Foo
      const match = /^data\s+(\S+)\b.*/.exec(line);
      const word = match[1];
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: line.slice(0, getWordEnd(word, line)),
        symbolStart: getWordStart(word, line),
        symbolEnd: getWordEnd(word, line),
        insertText: word,
        doc: docString,
      };
    } else if (/^type\s.+/.test(line)) {
      // type Foo = Bar
      const match = /^type\s+(\S+\b).*/.exec(line);
      const word = match[1];
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: line,
        symbolStart: getWordStart(word, line),
        symbolEnd: getWordEnd(word, line),
        insertText: word,
        doc: docString,
      };
    } else if (/^\([^()]+\)\s*::/.test(line)) {
      // (*#^) :: Type
      const splitted = line.split('::');
      let word = splitted[0].trim();
      word = word.slice(1, word.length - 1);
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: line,
        symbolStart: getWordStart(word, line),
        symbolEnd: getWordEnd(word, line),
        insertText: word,
        doc: docString,
      };
    } else if (/^\S+\s*::/.test(line)) {
      // foo :: Type
      const splitted = line.split('::');
      const word = splitted[0].trim();
      if (parseResults[word]) return;
      parseResults[word] = {
        declaration: line,
        symbolStart: getWordStart(word, line),
        symbolEnd: getWordEnd(word, line),
        insertText: word,
        doc: docString,
      };
    }
  });

  if (!imports.find((i) => i.module === 'Prelude')) {
    imports.push({
      module: 'Prelude',
      asName: 'Prelude',
      qualified: false,
      hiding: false,
      importList: undefined,
    });
  }

  if (window.buildMode === 'codeworld') {
    const symbols = Object.assign({}, window.codeWorldBuiltins);
    for (const i of imports) {
      if (i.module in window.codeWorldModules) {
        for (const symbol in window.codeWorldModules[i.module]) {
          if (i.importList) {
            if (i.hiding && i.importList.includes(symbol)) continue;
            if (!i.hiding && !i.importList.includes(symbol)) continue;
          }
          symbols[`${i.asName}.${symbol}`] =
            window.codeWorldModules[i.module][symbol];
          if (!i.qualified) {
            symbols[symbol] = window.codeWorldModules[i.module][symbol];
          }
        }
        symbols[i.asName] = {
          declaration: `module ${i.asName}`,
          symbolStart: 7,
          symbolEnd: 7 + i.asName.length,
          insertText: `${i.asName}.`,
          module: true,
          doc: null,
        };
      }
    }
    window.codeWorldSymbols = Object.assign(symbols, parseResults);
  } else {
    window.codeWorldSymbols = Object.assign({}, parseResults);
  }
}

function renderDeclaration(decl, keywordData, maxLen, argIndex = -1) {
  let column = 0;

  function addSegment(text, isWord, isBold) {
    function addSpan(content, wrappable) {
      const span = document.createElement('span');
      if (isWord) span.className = 'hint-word';
      if (isBold) span.style.fontWeight = 'bold';
      if (!wrappable) span.style.whiteSpace = 'nowrap';
      span.appendChild(document.createTextNode(content));
      decl.appendChild(span);
      column += content.length;
    }

    function trimFromTail(excess) {
      const tailLen = decl.lastChild.textContent.length;
      if (tailLen <= excess) {
        decl.removeChild(decl.lastChild);
        trimFromTail(excess - tailLen);
      } else {
        decl.lastChild.textContent = decl.lastChild.textContent.slice(
          0,
          tailLen - excess
        );
      }
    }

    const SYM = /^([:!#$%&*+./<=>?@\\^|~-]+)[^:!#$%&*+./<=>?@\\^|~-].*/;
    const NONSYM = /^([^:!#$%&*+./<=>?@\\^|~-]+)[:!#$%&*+./<=>?@\\^|~-].*/;
    while (text.length > 0) {
      const sym = SYM.exec(text);
      const split = sym || NONSYM.exec(text) || [text, text];

      addSpan(split[1], !sym);
      text = text.slice(split[1].length);
    }

    if (column > maxLen) {
      trimFromTail(column - maxLen + 3);
      addSpan('...', false);
    }
  }

  if (keywordData.symbolStart > 0) {
    addSegment(keywordData.declaration.slice(0, keywordData.symbolStart));
  }

  addSegment(
    keywordData.declaration.slice(
      keywordData.symbolStart,
      keywordData.symbolEnd
    ),
    true,
    false
  );

  if (keywordData.symbolEnd < keywordData.declaration.length) {
    const leftover = keywordData.declaration
      .slice(keywordData.symbolEnd)
      .replace(/\s+/g, ' ');
    if (argIndex >= 0) {
      // TODO: use a more sophisticated parser to fetch arguments,
      // and remove unnecessary subsequent checks.
      const parsedFunction = /^(\s*::\s*[(]?)([\w,\s]*)([)]?\s*->.*)$/.exec(
        leftover
      );
      if (!parsedFunction || parsedFunction.length <= 1) return null;

      const [head, args, tail] = parsedFunction.slice(1);
      const tokens = args.split(',');
      argIndex = Math.min(argIndex, tokens.length - 1);

      addSegment(head, false, false);
      for (let i = 0; i < tokens.length; i++) {
        if (i > 0) addSegment(',', false, false);
        addSegment(tokens[i], false, argIndex === i);
      }
      addSegment(tail, false, false);
    } else {
      addSegment(leftover, false, false);
    }
  }
  return decl;
}

function renderHover(keywordData, replacementExplanation) {
  if (!keywordData) return;

  const $wrapper = $('<div>');
  const $documentationContainer = $('<div>');
  const $fadeDiv = $('<div>');
  $fadeDiv.addClass('fade');
  const $annotation = $('<div>');
  renderDeclaration($annotation[0], keywordData, 9999);
  $annotation.addClass('hover-decl');

  $documentationContainer.append($annotation);

  if (keywordData.doc) {
    const $description = $('<div>');
    $description.html(keywordData.doc);
    $description.addClass('hover-doc');
    $documentationContainer.append($description);

    if (replacementExplanation) {
      const $noteAboutReplacement = $('<p>');
      $noteAboutReplacement.addClass('hint-description-replacement-note');
      $noteAboutReplacement.text(replacementExplanation);
      $description.append($noteAboutReplacement);
    }
  }

  $wrapper.append($documentationContainer);
  $wrapper.append($fadeDiv);

  return $wrapper[0];
}

function onHover(cm, data, node) {
  if (data && data.token && data.token.string) {
    const prefix = getQualifierPrefix(
      cm,
      CodeMirror.Pos(data.token.state.line, data.token.start)
    );
    const token_name = data.token.string;
    if (hintBlacklist.indexOf(token_name) === -1) {
      const info = window.codeWorldSymbols[prefix + token_name];
      return renderHover(info);
    }
  }
}

function getQualifierPrefix(cm, pos) {
  let prefix = '';
  let start = pos.ch;
  while (start > 1) {
    let qtoken = cm.getTokenAt(CodeMirror.Pos(pos.line, start));
    let qual = qtoken.string;
    if (qtoken.string === '.') {
      qtoken = cm.getTokenAt(CodeMirror.Pos(pos.line, qtoken.start));
      qual = `${qtoken.string}.`;
    }
    if (!QUALIFIER.test(qual)) break;

    prefix = qual + prefix;
    start = qtoken.start;
  }
  return prefix;
}

function substitutionCost(a, b, fixedLen, isTermReplaced) {
  const insertCost = 1;
  const deleteCost = 1.5;
  const transCost = 1;
  const substCost = 1.5;
  const caseCost = 0.1;
  const redirectPenalty = 5;

  const d = Array(b.length + 1)
    .fill()
    .map(() => Array(a.length + 1));

  function scale(i) {
    return i >= fixedLen ? 10 : 100;
  }

  for (let i = 0; i <= a.length; i += 1) {
    for (let j = 0; j <= b.length; j += 1) {
      if (i === 0 && j === 0) {
        d[j][i] = 0;
        continue;
      } else if (i === 0) {
        d[j][i] = d[j - 1][i] + insertCost * scale(i);
      } else if (j === 0) {
        d[j][i] = d[j][i - 1] + deleteCost * scale(i - 1);
      } else {
        const replaceCost =
          a[i - 1] === b[j - 1]
            ? 0
            : a[i - 1].toLowerCase() === b[j - 1].toLowerCase()
              ? caseCost
              : substCost;

        d[j][i] = Math.min(
          d[j][i - 1] + deleteCost * scale(i - 1),
          d[j - 1][i] + insertCost * scale(i),
          d[j - 1][i - 1] + replaceCost * scale(i - 1)
        );
        if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
          d[j][i] = Math.min(
            d[j][i],
            d[j - 2][i - 2] + transCost * scale(i - 2)
          );
        }
      }
    }
  }

  return (
    d[b.length][a.length] +
    scale(fixedLen) * (a.length - b.length) +
    (isTermReplaced ? redirectPenalty : 0)
  );
}

// Hints and hover tooltips
function registerStandardHints(successFunc) {
  let replacementTerms = {};
  fetch('./replacement_terms.json')
    .then((blob) => blob.json())
    .then((result) => (replacementTerms = result));

  CodeMirror.registerHelper('hint', 'codeworld', (cm) => {
    const deleteOldHintDocs = () => {
      $('.hint-description').remove();
    };

    deleteOldHintDocs();

    const cur = cm.getCursor();
    const token = cm.getTokenAt(cur);

    // If the current token is whitespace, it can be split.
    let term = token.string.substr(0, cur.ch - token.start);
    let from = CodeMirror.Pos(cur.line, token.start);

    if (!VAR_OR_CON.test(term)) {
      term = '';
      from = cur;
    }

    const prefix = getQualifierPrefix(cm, from);

    // The found collection is organized into three tiers:
    //
    // 1. Exact match for the current token.
    // 2. Current token is a case-sensitive prefix.
    // 3. Others, to be presented as fuzzy matches.
    const found = [[], [], []];

    for (const [hintName, hintProps] of Object.entries(
      window.codeWorldSymbols
    )) {
      const parts = hintName.split(/\.(?=[^.]+$)/);
      const hintPrefix = parts.length < 2 ? '' : `${parts[0]}.`;
      const hintIdent = parts.length < 2 ? hintName : parts[1];

      if (!VAR_OR_CON.test(hintIdent)) {
        continue;
      }

      if (hintProps.module) {
        if (hintName.startsWith(prefix)) {
          const candidate = {
            text: hintProps.insertText.substr(prefix.length),
            details: hintProps,
            render: (elem) => {
              renderDeclaration(elem, hintProps, 50);
            },
          };
          if (hintName === prefix + token.string) {
            found[0].push(candidate);
          } else if (hintName.startsWith(prefix + term)) {
            found[1].push(candidate);
          } else {
            found[2].push(candidate);
          }
        }
      } else if (hintPrefix === prefix) {
        const candidate = {
          text: hintProps.insertText,
          details: hintProps,
          render: (elem) => {
            renderDeclaration(elem, hintProps, 50);
          },
        };
        if (hintIdent === token.string) {
          found[0].push(candidate);
        } else if (hintIdent.startsWith(term)) {
          found[1].push(candidate);
        } else {
          found[2].push(candidate);
        }
      }
    }

    let options = found[0].concat(found[1], found[2]);
    let foundReplacementPrefix = false;
    options.forEach((candidate) => {
      const { text } = candidate;
      candidate.cost = substitutionCost(token.string, text, term.length);

      if (!window.codeWorldSymbols[text]) {
        return;
      }

      const { definingModule } = window.codeWorldSymbols[text];
      if (!definingModule) {
        return;
      }

      const mapping = replacementTerms[definingModule];
      const mappedTerms =
        Object.prototype.hasOwnProperty.call(mapping, text) && mapping[text];

      if (!mappedTerms) {
        return;
      }

      const mappedTermsWithCosts = mappedTerms.map((mappedTerm) => {
        const replacementWord = mappedTerm.value
          ? mappedTerm.value
          : mappedTerm;
        if (replacementWord.startsWith(term)) {
          foundReplacementPrefix = true;
        }

        return {
          replacementExplanation: mappedTerm.explanation,
          cost: substitutionCost(
            token.string,
            mappedTerm.value ? mappedTerm.value : mappedTerm,
            term.length,
            true
          ),
        };
      });

      const lowestCost = Math.min(
        ...mappedTermsWithCosts.map(({ cost }) => cost),
        candidate.cost
      );
      candidate.cost = lowestCost;

      const winningMappedTerm = mappedTermsWithCosts.find(
        ({ cost }) => cost === lowestCost
      );
      if (winningMappedTerm) {
        candidate.replacementExplanation =
          winningMappedTerm.replacementExplanation;
      }
    });

    // If there's a chance to complete an exact prefix, clear out the fuzzy
    // matches so that the exact match is chosen.
    if (
      found[0].length === 0 &&
      found[1].length === 1 &&
      !foundReplacementPrefix
    ) {
      options = found[1];
    }

    if (options.length > 0) {
      options.sort((a, b) => {
        if (a.cost < b.cost) return -1;
        if (a.cost > b.cost) return 1;
        return a.text.toLowerCase() < b.text.toLowerCase() ? -1 : 1;
      });

      let numGood;
      for (numGood = 1; numGood < options.length; numGood++) {
        if (numGood >= 16 && options[numGood].cost > 2 * options[0].cost + 50) {
          break;
        }
      }

      const goodOptions = options.slice(0, numGood);

      const data = {
        list: goodOptions,
        from,
        to: VAR_OR_CON.test(term) ? CodeMirror.Pos(cur.line, token.end) : cur,
      };

      CodeMirror.on(data, 'close', deleteOldHintDocs);
      CodeMirror.on(data, 'pick', deleteOldHintDocs);
      CodeMirror.on(data, 'pick', (completion) => {
        if (completion.details.module) cm.showHint();
      });

      // Tracking of hint selection
      CodeMirror.on(data, 'select', (selection, elem) => {
        const hintsWidgetRect = elem.parentElement.getBoundingClientRect();
        const doc = document.createElement('div');
        deleteOldHintDocs();
        const hover = renderHover(
          selection.details,
          selection.replacementExplanation
        );
        if (hover) {
          doc.className += 'hint-description';
          doc.style.top = `${hintsWidgetRect.top}px`;
          doc.style.left = `${hintsWidgetRect.right}px`;
          doc.appendChild(hover);
          document.body.appendChild(doc);
        }
      });
      return data;
    }
  });

  sendHttp('GET', 'codeworld-base.txt', null, (request) => {
    let lines = [];
    if (request.status !== 200) {
      console.log('Failed to load autocomplete word list.');
    } else {
      lines = request.responseText.split('\n');
    }

    // Special case for "program", since it is morally a built-in name.
    window.codeworldKeywords['program'] = 'builtin';

    window.codeWorldModules = {};
    let module = null;
    let doc = '';
    lines.forEach((line) => {
      if (line.startsWith('module ')) {
        module = line.substr(7);
        if (!window.codeWorldModules[module]) {
          window.codeWorldModules[module] = {};
        }
        doc = '';
        return;
      }

      if (!module) {
        // Ignore anything outside of a module.
        doc = '';
        return;
      }

      if (module === 'Prelude' && line.startsWith('type Program')) {
        // We must intervene to hide the IO type.
        line = 'data Program';
      } else if (module === 'Prelude' && line.startsWith('type Truth')) {
        line = 'data Truth';
      } else if (module === 'Prelude' && line.startsWith('True ::')) {
        line = 'True :: Truth';
      } else if (module === 'Prelude' && line.startsWith('False ::')) {
        line = 'False :: Truth';
      } else if (line.startsWith('newtype ')) {
        // Hide the distinction between newtype and data.
        line = `data ${line.substr(8)}`;
      } else if (line.startsWith('pattern ')) {
        // Hide the distinction between patterns and constructors.
        line = line.substr(8);
      } else if (line.startsWith('class ')) {
        doc = '';
        return;
      } else if (line.startsWith('instance ')) {
        doc = '';
        return;
      } else if (line.startsWith('infix ')) {
        doc = '';
        return;
      } else if (line.startsWith('infixl ')) {
        doc = '';
        return;
      } else if (line.startsWith('infixr ')) {
        doc = '';
        return;
      }

      // Filter out strictness annotations.
      line = line.replace(/(\s)!([A-Za-z([])/g, '$1$2');

      // Filter out CallStack constraints.
      line = line.replace(/:: HasCallStack =>/g, '::');

      if (line.startsWith('-- |')) {
        doc = `${line.replace(/-- \| /g, '')}\n`;
      } else if (line.startsWith('-- ')) {
        doc += `${line.replace(/-- {3}/g, '')}\n`;
      } else {
        let wordStart = 0;
        if (line.startsWith('type ') || line.startsWith('data ')) {
          wordStart += 5;

          // Hide kind annotations.
          const kindIndex = line.indexOf(' ::');
          if (kindIndex !== -1) {
            line = line.substr(0, kindIndex);
          }
        }

        let wordEnd = line.indexOf(' ', wordStart);
        if (wordEnd === -1) {
          wordEnd = line.length;
        }
        if (wordStart === wordEnd) {
          doc = '';
          return;
        }

        if (line[wordStart] === '(' && line[wordEnd - 1] === ')') {
          wordStart++;
          wordEnd--;
        }

        const word = line.substr(wordStart, wordEnd - wordStart);
        let isBlacklisted = false;
        if (module === 'Prelude') {
          if (hintBlacklist.indexOf(word) >= 0) isBlacklisted = true;
        } else {
          if (['RGB', 'HSL', 'RGBA'].indexOf(word) >= 0) isBlacklisted = true;
        }
        if (!isBlacklisted) {
          window.codeWorldModules[module][word] = {
            declaration: line,
            symbolStart: wordStart,
            symbolEnd: wordEnd,
            insertText: word,
            definingModule: module,
          };
          if (doc) {
            window.codeWorldModules[module][word].doc = doc;
          }
        }

        if (module === 'Prelude') {
          if (hintBlacklist.indexOf(word) >= 0) {
            window.codeworldKeywords[word] = 'deprecated';
          } else if (/^[A-Z:]/.test(word)) {
            window.codeworldKeywords[word] = 'builtin-2';
          } else {
            window.codeworldKeywords[word] = 'builtin';
          }
        }

        doc = '';
      }
    });

    successFunc();
  });
}


function loadSample(isEditorClean, action, code) {
  if (isEditorClean()) {
    sweetAlert.close();
  }

  warnIfUnsaved(isEditorClean, () => {
    action(code);
  });
}


function warnIfUnsaved(isEditorClean, action) {
  if (isEditorClean()) {
    action();
  } else {
    sweetAlert({
      title: Alert.title('Warning'),
      text:
        'There are unsaved changes to your project. Continue and throw away your changes?',
      type: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#DD6B55',
      confirmButtonText: 'Yes, discard my changes!',
    }).then((result) => {
      if (result && result.value) action();
    });
  }
}


function goto(line, col) {
  codeworldEditor.getDoc().setCursor(line - 1, col - 1);
  codeworldEditor.scrollIntoView(null, 100);
  codeworldEditor.focus();
}

// Expose this method globally - click handlers required it in preFormatMessage().
window.goto = goto;

function preFormatMessage(msg) {
  while (msg.match(/(\r\n|[^\x08]|)\x08/)) {
    msg = msg.replace(/(\r\n|[^\x08])\x08/g, '');
  }

  msg = Html.encode(msg)
    .replace(
      /program\.hs:(\d+):((\d+)(-\d+)?)/g,
      '<a href="#" onclick="goto($1, $3); return false;">Line $1, Column $2</a>'
    )
    .replace(
      /program\.hs:\((\d+),(\d+)\)-\((\d+),(\d+)\)/g,
      '<a href="#" onclick="goto($1, $2); return false;">Line $1-$3, Column $2-$4</a>'
    )
    .replace(
      /[A-Za-z0-9_-]*\.hs:(\d+):((\d+)(-\d+)?)/g,
      'In an imported module'
    )
    .replace(
      /program\.hs:\((\d+),(\d+)\)-\((\d+),(\d+)\)/g,
      'In an imported module'
    );
  return msg;
}

function printMessage(type, message) {
  const $outputBlock = $('#message');
  const $lastOutputBlock = $outputBlock.children().last();

  const formattedMessage = preFormatMessage(message);

  // Combine sequential log messages.
  if (
    type === 'log' &&
    $lastOutputBlock.length &&
    $lastOutputBlock.attr('class').includes('log')
  ) {
    const $lastOutputBlockMessageContent = $lastOutputBlock.find(
      '.message-content'
    );
    $lastOutputBlockMessageContent.append(formattedMessage);
  } else {
    const lines = formattedMessage.trim().split('\n');
    const $box = $('<div>');
    $box.addClass(`message-box ${type}`);

    const $messageGutter = $('<div>');
    $messageGutter.addClass('message-gutter');

    const $messageContent = $('<div>');
    $messageContent.addClass('message-wrapper');

    $box.append($messageGutter, $messageContent);
    $outputBlock.append($box);

    if (lines.length < 2 || type === 'log') {
      const $singleLineMsg = $('<div>');
      $singleLineMsg.addClass('message-content');
      $singleLineMsg.html(formattedMessage);

      $messageContent.append($singleLineMsg);
    } else {
      const formattedMessageFirstLine = lines[0];
      const formattedMessageWithoutFirstLine = lines.slice(1).join('\n');

      const $summary = $('<summary>');
      $summary.addClass('message-summary');
      $summary.html(formattedMessageFirstLine);

      const $details = $('<details>');
      $details.addClass('message-content');
      $details.attr('open', '');
      $details.append($summary, formattedMessageWithoutFirstLine);

      $messageContent.append($details);
    }
  }


  $outputBlock.scrollTop($outputBlock.prop('scrollHeight'));
}

function clearMessages() {
  const outputDiv = document.getElementById('message');
  outputDiv.innerHTML = '';
  outputDiv.classList.remove('error');
}

function markFailed() {
  const outputDiv = document.getElementById('message');
  outputDiv.classList.add('error');
}

// Get path to root dir in format root/sub1/sub2/etc
// starting from parent.
function pathToRootDir(nodeInit) {
  let node = Object.assign(nodeInit);
  const path = [];
  while (node.parent && node.parent.name !== '') {
    node = node.parent;
    path.push(node.name);
  }
  path.reverse();
  return path.join('/');
}


const LAYOUT_CONTAINER_CLASSNAME = '.ui-layout-container';

function initializeLayoutContainer(options) {
  $(LAYOUT_CONTAINER_CLASSNAME).layout(options);
}


function run(successful, msg, error, generation) {
  window.runningGeneration = generation;
  window.debugAvailable = false;
  window.debugActive = false;
  window.lastRunMessage = msg;

  const runner = document.getElementById('runner');

  // Stop canvas recording if the recorder is active
  document.getElementById('runner').contentWindow.postMessage(
    {
      type: 'stopRecord',
    },
    '*'
  );

  runner.contentWindow.location.replace(`run?mode=${window.buildMode}`);
  document.getElementById('runner').style.display = 'none';
  document.getElementById('startRecButton').style.display = 'none';

  const layoutHandler = $(LAYOUT_CONTAINER_CLASSNAME).layout();

  if (successful || msg) {
    layoutHandler.show('east');
    layoutHandler.open('east');
  } else {
    layoutHandler.hide('east');
  }

  clearMessages();

  parseCompileErrors(msg).forEach((cmError) => {
    printMessage(cmError.severity, cmError.fullText);
  });

  if (error) markFailed();
}

function toggleObsoleteCodeAlert() {
  const isRunning = $('#runner').css('display') !== 'none';
  // If true, current code isn't equal to previously compiled code.
  const isObsolete = window.codeworldEditor
    ? !window.codeworldEditor.getDoc().isClean(window.runningGeneration)
    : false;
  const $obsoleteAlert = $('#obsolete-code-alert');

  if (isRunning && isObsolete) {
    $obsoleteAlert.addClass('obsolete-code-alert-fadein');
    $obsoleteAlert.removeClass('obsolete-code-alert-fadeout');
  } else {
    $obsoleteAlert.addClass('obsolete-code-alert-fadeout');
    $obsoleteAlert.removeClass('obsolete-code-alert-fadein');
  }
}

function parseCompileErrors(rawErrors) {
  const errors = [];
  rawErrors = rawErrors.split('\n\n');
  rawErrors.forEach((err) => {
    const lines = err.trim().split('\n');
    const firstLine = lines[0].trim();
    const otherLines = lines
      .slice(1)
      .map((ln) => ln.trim())
      .join('\n');
    const re1 = /^program\.hs:(\d+):((\d+)-?(\d+)?): (\w+):(.*)/;
    const re2 = /^program\.hs:\((\d+),(\d+)\)-\((\d+),(\d+)\): (\w+):(.*)/;
    const reCompile = /: \[[0-9]+ of [0-9]+\] Compiling .*/;
    const reLink = /: Linking program[.]jsexe\b.*/;

    if (err.trim() === '') {
      // Ignore empty messages.
    } else if (re1.test(firstLine)) {
      const match = re1.exec(firstLine);

      const line = Number(match[1]) - 1;
      let startCol = Number(match[3]) - 1;
      let endCol;
      if (match[4]) {
        endCol = Number(match[4]);
      } else {
        const token = window.codeworldEditor
          .getLineTokens(line)
          .find((t) => t.start === startCol);
        if (token) {
          endCol = token.end;
        } else if (
          startCol >= window.codeworldEditor.getDoc().getLine(line).length
        ) {
          endCol = startCol;
          --startCol;
        } else {
          endCol = startCol + 1;
        }
      }

      const message = ((match[6] ? `${match[6].trim()}\n` : '') + otherLines)
        .replace(/program\.hs:(\d+):((\d+)(-\d+)?)/g, 'Line $1, Column $2')
        .replace(
          /program\.hs:\((\d+),(\d+)\)-\((\d+),(\d+)\)/g,
          'Line $1-$3, Column $2-$4'
        );

      errors.push({
        from: CodeMirror.Pos(line, startCol),
        to: CodeMirror.Pos(line, endCol),
        severity: match[5],
        fullText: err,
        message: message,
      });
    } else if (re2.test(firstLine)) {
      const match = re2.exec(firstLine);

      const startLine = Number(match[1]) - 1;
      const startCol = Number(match[2]) - 1;
      const endLine = Number(match[3]) - 1;
      const endCol = Number(match[4]);

      errors.push({
        from: CodeMirror.Pos(startLine, startCol),
        to: CodeMirror.Pos(endLine, endCol),
        severity: match[5],
        fullText: err,
        message: (match[6] ? `${match[6].trim()}\n` : '') + otherLines,
      });
    } else if (!reCompile.test(firstLine) && !reLink.test(firstLine)) {
      errors.push({
        fullText: err,
        message: err,
      });
    }
  });
  return errors;
}

async function sha256digest(data) {
  const buffer = new TextEncoder().encode(data);
  return await crypto.subtle.digest('SHA-256', buffer).then((hash) => {
    return Array.from(new Uint8Array(hash))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  });
}

async function saveCodeToLocalStorageAndReplaceHash(code, mode) {
  const currentUrl = new URL(window.location);
  const searchParams = currentUrl.searchParams;

  const codeHash = await sha256digest(code.trim());
  localStorage.setItem(`${mode}-${codeHash}`, code);
  currentUrl.hash = codeHash;

  window.history.replaceState(window.history.state, "", currentUrl.toString());
}

function tryLoadingCodeFromLocalStorage(mode) {
  const currentUrl = new URL(window.location);
  const codeHash = currentUrl.hash.slice(1);
  if(!codeHash) return;

  return localStorage.getItem(`${mode}-${codeHash}`);
}

async function tryFetchCodeFromSourceAndStripURL(handler){
  const currentUrl = new URL(window.location);
  const searchParams = currentUrl.searchParams;

  const codeSrc = searchParams.get("loadSrc");
  if (!codeSrc) return;

  const fetchController = new AbortController();
    sweetAlert({
      title: Alert.title('Loading code'),
      text: 'The code is being fetched.  Please wait...',
      onOpen: () => {
        sweetAlert.showLoading();
        sweetAlert.getCancelButton().disabled = false;
      },
      showConfirmButton: false,
      showCancelButton: true,
      showCloseButton: false,
      allowOutsideClick: false,
      allowEscapeKey: false,
      allowEnterKey: false,
    }).then(() => {
      fetchController.abort();
    });
    try {
      const response = await fetch(codeSrc, {
        signal: fetchController.signal,
      });
      const code = await response.text();
      searchParams.delete("loadSrc");
      window.history.replaceState(window.history.state, "", currentUrl.toString());
      sweetAlert.close();
      handler(code);

    } catch (error) {
      sweetAlert(
        'Oops!',
        'Could not load the code from source. Please try again.',
        'error'
      );
    }
}

export {
  clearMessages,
  definePanelExtension,
  initializeLayoutContainer,
  LAYOUT_CONTAINER_CLASSNAME,
  loadSample,
  markFailed,
  onHover,
  parseCompileErrors,
  parseSymbolsFromCurrentCode,
  printMessage,
  registerStandardHints,
  renderDeclaration,
  run,
  toggleObsoleteCodeAlert,
  warnIfUnsaved,
  sha256digest,
  saveCodeToLocalStorageAndReplaceHash,
  tryLoadingCodeFromLocalStorage,
  tryFetchCodeFromSourceAndStripURL,
};
