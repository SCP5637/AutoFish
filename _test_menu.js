// Temp test script — verify printMenu() Box layout, delete after check
const { createBox, createPalette, supportsUnicode, stripAnsi, UNICODE_CHARS, ASCII_CHARS } = require('./ui-lib');

function projectStatus(project) { return project._status || 'ready'; }
function toPosixPath(p) { return p.replace(/\\/g, '/'); }

const registry = {
  lastProjectId: 'proj-1',
  projects: [
    { id: 'proj-1', name: 'test-project', projectDir: 'D:/test/test-project', _status: 'ready' },
    { id: 'proj-2', name: 'annotator', projectDir: 'D:/test/annotator', _status: 'blocked' },
    { id: 'proj-3', name: 'missing-one', projectDir: 'D:/test/missing', _status: 'missing' },
  ]
};

// --- Copy of new printMenu() ---
const box = createBox();
const palette = createPalette();
const unicode = supportsUnicode();
const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
const W = 80;

const ICON = { ok: unicode ? '✓' : '[OK]', fail: unicode ? '✗' : '[XX]', warn: unicode ? '⚠' : '[!!]' };
const ARROW = unicode ? '▸' : '>';

function statusIcon(project) {
  const s = projectStatus(project);
  if (s === 'ready' || s === 'complete') return palette.info(ICON.ok) + ' ' + s;
  if (s === 'missing') return palette.error(ICON.fail) + ' ' + s;
  return palette.warn(ICON.warn) + ' ' + s;
}

function boxLine(inner) {
  const plain = stripAnsi(inner);
  const pad = Math.max(0, W - 4 - plain.length);
  return C.vt + ' ' + inner + ' '.repeat(pad) + ' ' + C.vt;
}

function projectRow(num, project) {
  const numStr = num === 0 ? '0.' : String(num).padEnd(2);
  const name = project ? project.name : 'none';
  const left = numStr + ' ' + name;
  if (!project) return palette.dim(left);
  const right = statusIcon(project);
  const leftVis = left.length;
  const rightVis = stripAnsi(right).length;
  const gap = Math.max(1, W - 4 - leftVis - rightVis);
  return left + ' '.repeat(gap) + right;
}

console.log('');
console.log(box.header('AutoFish', W));
console.log(box.kv('Root', toPosixPath('D:/test'), W));
console.log(box.sep(W));
console.log(boxLine(palette.accent('Last:')));
const last = registry.projects.find(p => p.id === registry.lastProjectId);
if (last) {
  console.log(boxLine('  ' + projectRow(0, last)));
  console.log(boxLine(palette.dim('     ' + last.projectDir)));
}
console.log(box.sep(W));
console.log(boxLine(palette.accent('Projects:')));
registry.projects.forEach((project, index) => {
  console.log(boxLine('  ' + projectRow(index + 1, project)));
  console.log(boxLine(palette.dim('     ' + project.projectDir)));
});
console.log(box.sep(W));
console.log(boxLine(palette.accent(ARROW) + ' ' + palette.info((registry.projects.length + 1) + '. New Project')));
console.log(boxLine(palette.accent(ARROW) + ' ' + palette.info('X. Exit')));
console.log(box.footer(W));
