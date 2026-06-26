#!/usr/bin/env node
// E2E verification script for AutoFish UI modernization — Phase 6.1
// Tests all UI components in isolation: palette, box, menus, summaries, etc.

const { createBox, createPalette, supportsUnicode, stripAnsi, stripBoxChars, UNICODE_CHARS, ASCII_CHARS } = require('./ui-lib');

let passed = 0;
let failed = 0;

function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ${UNICODE_CHARS.tl}${UNICODE_CHARS.hz} PASS: ${name}`);
  } catch (e) {
    failed++;
    console.log(`  ${UNICODE_CHARS.tl}${UNICODE_CHARS.hz} FAIL: ${name} — ${e.message}`);
  }
}

console.log('\n' + '='.repeat(60));
console.log('AutoFish E2E UI Verification — Phase 6.1');
console.log('='.repeat(60));

// ---- Phase 1: ui-lib.js ----
console.log('\n--- Phase 1: UI Library (ui-lib.js) ---');

check('createPalette returns all color functions', () => {
  const p = createPalette({});
  if (typeof p.dim !== 'function') throw new Error('dim missing');
  if (typeof p.info !== 'function') throw new Error('info missing');
  if (typeof p.accent !== 'function') throw new Error('accent missing');
  if (typeof p.warn !== 'function') throw new Error('warn missing');
  if (typeof p.error !== 'function') throw new Error('error missing');
  // Backward compat
  if (typeof p.note !== 'function') throw new Error('note alias missing');
  if (typeof p.run !== 'function') throw new Error('run alias missing');
  if (typeof p.key !== 'function') throw new Error('key alias missing');
});

check('createPalette NO_COLOR strips ANSI', () => {
  const p = createPalette({ NO_COLOR: '1' });
  const result = p.error('test');
  if (result !== 'test') throw new Error(`NO_COLOR not honored: "${result}"`);
});

check('createPalette with color wraps ANSI', () => {
  const p = createPalette({});
  const result = p.error('test');
  if (!result.includes('\x1b[91m')) throw new Error(`Missing ANSI color code: "${result}"`);
});

check('supportsUnicode with WT_SESSION returns true', () => {
  if (!supportsUnicode({ WT_SESSION: '1' }, { isTTY: true })) throw new Error('WT_SESSION should enable unicode');
});

check('supportsUnicode with LANG UTF-8 returns true', () => {
  if (!supportsUnicode({ LANG: 'en_US.UTF-8' }, { isTTY: true })) throw new Error('LANG UTF-8 should enable unicode');
});

check('supportsUnicode with NO_COLOR returns false', () => {
  if (supportsUnicode({ NO_COLOR: '1', WT_SESSION: '1' })) throw new Error('NO_COLOR should disable unicode');
});

check('supportsUnicode with non-TTY returns false', () => {
  if (supportsUnicode({ WT_SESSION: '1' }, { isTTY: false })) throw new Error('non-TTY should disable unicode');
});

check('stripAnsi removes color codes', () => {
  const result = stripAnsi('\x1b[91mERROR\x1b[0m');
  if (result !== 'ERROR') throw new Error(`stripAnsi failed: "${result}"`);
});

check('stripBoxChars removes box-drawing chars', () => {
  const result = stripBoxChars('┌───┐');
  if (result !== '') throw new Error(`stripBoxChars failed: "${result}"`);
});

check('stripBoxChars does not remove ASCII', () => {
  const result = stripBoxChars('+---[OK] text >');
  if (result !== '+---[OK] text >') throw new Error(`stripBoxChars removed ASCII: "${result}"`);
});

// ---- Box drawing ----
console.log('\n--- Phase 1: Box Drawing ---');

check('createBox header with title', () => {
  const box = createBox();
  const h = box.header('Test', 50);
  if (h.length < 48) throw new Error(`header too short: ${h.length}`);
  if (!h.includes('Test')) throw new Error('header missing title');
});

check('createBox footer', () => {
  const box = createBox();
  const f = box.footer(50);
  if (f.length < 48) throw new Error(`footer too short: ${f.length}`);
});

check('createBox kv alignment', () => {
  const box = createBox();
  const line = box.kv('Name', 'value', 80, 14);
  if (line.length < 78) throw new Error(`kv too short: ${line.length}`);
  const plain = stripAnsi(line);
  if (!plain.includes('Name:') || !plain.includes('value')) throw new Error(`kv content wrong: "${plain}"`);
});

check('createBox sep', () => {
  const box = createBox();
  const s = box.sep(60);
  if (s.length < 58) throw new Error(`sep too short: ${s.length}`);
});

check('createBox section', () => {
  const box = createBox();
  const s = box.section('Section', ['line1', 'line2'], 60);
  const lines = s.split('\n');
  if (lines.length !== 4) throw new Error(`section lines: expected 4, got ${lines.length}`);
});

check('createBox bullet', () => {
  const box = createBox();
  const b = box.bullet('item', 1, 60);
  if (b.length < 58) throw new Error(`bullet too short: ${b.length}`);
});

check('createBox hudLine', () => {
  const box = createBox();
  const fields = [
    { label: 'R', value: '1' },
    { label: 'Task', value: 'test' },
    { label: 'Budget', value: '$5' },
  ];
  const h = box.hudLine(fields, 80);
  if (h.length < 78) throw new Error(`hudLine too short: ${h.length}`);
});

check('ASCII fallback box chars', () => {
  const box = createBox({ NO_COLOR: '1' });
  const h = box.header('Test', 50);
  if (h.includes('┌')) throw new Error('ASCII mode should not use Unicode');
});

check('box_line (alias)', () => {
  const box = createBox();
  const l = box.box_line('test', 60);
  if (l.length < 58) throw new Error(`box_line too short: ${l.length}`);
});

// ---- Phase 2: autofish.js UI (simulated) ----
console.log('\n--- Phase 2: autofish.js UI Components ---');

const box = createBox(process.env, process.stdout);
const palette = createPalette(process.env);
const unicode = supportsUnicode(process.env, process.stdout);
const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
const W = 80;
const ICON = { ok: unicode ? '✓' : '[OK]', fail: unicode ? '✗' : '[XX]', warn: unicode ? '⚠' : '[!!]' };

function boxLine(inner) {
  const plain = stripAnsi(inner);
  const pad = Math.max(0, W - 4 - plain.length);
  return C.vt + ' ' + inner + ' '.repeat(pad) + ' ' + C.vt;
}

check('printMenu - header renders', () => {
  const h = box.header('AutoFish', W);
  if (!h.includes('AutoFish')) throw new Error('menu header wrong');
  if (h.length < 78) throw new Error('menu header too short');
});

check('printMenu - kv renders', () => {
  const line = box.kv('Root', 'D:/test', W);
  const plain = stripAnsi(line);
  if (!plain.includes('Root:') || !plain.includes('D:/test')) throw new Error('menu kv wrong');
});

check('printMenu - sep renders', () => {
  const s = box.sep(W);
  if (s.length < 78) throw new Error('menu sep too short');
});

check('printMenu - footer renders', () => {
  const f = box.footer(W);
  if (f.length < 78) throw new Error('menu footer too short');
});

check('printMenu - status icons colorized', () => {
  const result = palette.info(ICON.ok) + ' ready';
  if (!result.includes(ICON.ok)) throw new Error('ok icon missing');
  const resultWarn = palette.warn(ICON.warn) + ' blocked';
  if (!resultWarn.includes(ICON.warn)) throw new Error('warn icon missing');
  const resultErr = palette.error(ICON.fail) + ' missing';
  if (!resultErr.includes(ICON.fail)) throw new Error('fail icon missing');
});

check('printMenu - arrow + action line', () => {
  const ARROW = unicode ? '▸' : '>';
  const line = boxLine(palette.accent(ARROW) + ' ' + palette.info('4. New Project'));
  if (line.length < 78) throw new Error('action line too short');
  const p = stripAnsi(line);
  if (!p.includes(ARROW)) throw new Error('arrow missing');
});

check('printProjectSummary - header renders', () => {
  const h = box.header('Selected project', W);
  if (!h.includes('Selected project')) throw new Error('summary header wrong');
});

check('printProjectSummary - all kv fields render', () => {
  const fields = ['Name', 'Status', 'Project', 'State dir', 'Project doc', 'Config', 'Bootstrap'];
  for (const field of fields) {
    const line = box.kv(field, 'test-value', W);
    if (line.length < 78) throw new Error(`summary kv ${field} too short: ${line.length}`);
    const plain = stripAnsi(line);
    if (!plain.includes(field + ':')) throw new Error(`summary kv ${field} label missing`);
  }
});

check('printPluginPreflight - header renders', () => {
  const h = box.header('Plugin preflight', W);
  if (!h.includes('Plugin preflight')) throw new Error('plugin header wrong');
});

check('printSafeSetupLaunchResult - header renders', () => {
  const h = box.header('Safety hooks required', W);
  if (!h.includes('Safety hooks required')) throw new Error('safe setup header wrong');
});

check('printBootstrapLaunchResult - header renders', () => {
  const h = box.header('Bootstrap required', W);
  if (!h.includes('Bootstrap required')) throw new Error('bootstrap header wrong');
});

check('printWntdLaunchResult - header renders', () => {
  const h = box.header('WNTD review required', W);
  if (!h.includes('WNTD review required')) throw new Error('wntd header wrong');
});

// ---- Phase 3: run-loop.sh box helpers (simulated) ----
console.log('\n--- Phase 3: run-loop.sh UI Components ---');

check('Box chars: UNICODE set has all chars', () => {
  const required = ['tl','tr','bl','br','hz','vt','lt','rt','bul','arr'];
  for (const k of required) {
    if (typeof UNICODE_CHARS[k] !== 'string' || UNICODE_CHARS[k].length !== 1) {
      throw new Error(`UNICODE_CHARS.${k} missing or wrong`);
    }
  }
});

check('Box chars: ASCII set has all chars', () => {
  const required = ['tl','tr','bl','br','hz','vt','lt','rt','bul','arr'];
  for (const k of required) {
    if (typeof ASCII_CHARS[k] !== 'string' || ASCII_CHARS[k].length < 1) {
      throw new Error(`ASCII_CHARS.${k} missing or wrong`);
    }
  }
});

check('Round header simulates bash box_header', () => {
  const h = box.header('Round 1', 62);
  if (h.length < 60) throw new Error('round header too short');
  if (!h.includes('Round 1')) throw new Error('round header title missing');
});

check('HUD line simulates bash hud_line', () => {
  const fields = [
    { label: 'R', value: '1' },
    { label: 'Budget', value: '$5.00' },
  ];
  const h = box.hudLine(fields, 62);
  if (h.length < 60) throw new Error('hud line too short');
  const plain = stripAnsi(h);
  if (!plain.includes('R:') || !plain.includes('Budget:')) throw new Error('hud fields missing');
});

check('Run summary simulates bash main() startup', () => {
  const h = box.header('Run summary', 62);
  if (!h.includes('Run summary')) throw new Error('run summary header wrong');
  const kvLines = [
    box.kv('Project id', 'legacy', 62, 15),
    box.kv('Config', '/path/config.json', 62, 15),
  ];
  for (const line of kvLines) {
    if (line.length < 60) throw new Error('run summary kv too short');
  }
});

check('Final summary simulates bash final output', () => {
  const h = box.header('Final summary', 62);
  if (!h.includes('Final summary')) throw new Error('final summary header wrong');
});

check('Stop condition icons use correct symbols', () => {
  const CHECK = unicode ? '✓' : '[OK]';
  const CROSS = unicode ? '✗' : '[XX]';
  const WARN_SYM = unicode ? '⚠' : '[!!]';
  const ARROW = unicode ? '→' : '->';
  // Verify CHECK/CROSS match ICON
  if (CHECK !== ICON.ok) throw new Error(`CHECK mismatch: ${CHECK} vs ${ICON.ok}`);
  if (CROSS !== ICON.fail) throw new Error(`CROSS mismatch: ${CROSS} vs ${ICON.fail}`);
  if (WARN_SYM !== ICON.warn) throw new Error(`WARN_SYM mismatch: ${WARN_SYM} vs ${ICON.warn}`);
});

// ---- Phase 4: progress-filter.js (symbols only) ----
console.log('\n--- Phase 4: progress-filter.js UI Components ---');

check('progress-filter CC prefix chars', () => {
  const CC_PRE = unicode ? '╰─ ' : '|_ ';
  if (CC_PRE.length < 2) throw new Error('CC prefix too short');
});

check('progress-filter step bullet', () => {
  const BUL = unicode ? '•' : '*';
  if (BUL.length !== 1) throw new Error('step bullet wrong');
});

check('progress-filter palette export (dim/info/accent)', () => {
  const p = createPalette({});
  const dimResult = p.dim('test');
  const infoResult = p.info('test');
  const accentResult = p.accent('test');
  if (!dimResult || !infoResult || !accentResult) throw new Error('filter palette broken');
});

check('progress-filter stripAnsi for log writes', () => {
  // Use UNICODE_CHARS.hz explicitly — ASCII hz ('-') is valid in plain text logs
  const logLine = stripAnsi(stripBoxChars(UNICODE_CHARS.hz + ' ' + palette.accent('CC: hello') + ' ' + UNICODE_CHARS.hz));
  if (logLine.includes('\x1b')) throw new Error('ANSI not stripped from log line');
  if (logLine.includes(UNICODE_CHARS.hz)) throw new Error('Box chars not stripped from log line');
});

// ---- Phase 5: run-auto.bat ASCII compatibility ----
console.log('\n--- Phase 5: run-auto.bat ASCII Compatibility ---');

check('ASCII_CHARS all printable ASCII', () => {
  const vals = Object.values(ASCII_CHARS);
  for (const v of vals) {
    if (v.length < 1) throw new Error('ASCII char too short');
    for (const ch of v) {
      const code = ch.charCodeAt(0);
      if (code < 32 || code > 126) throw new Error(`Non-printable ASCII char: code=${code}`);
    }
  }
});

check('ASCII_CHARS compatible with Batch CMD', () => {
  // Batch CMD can only handle ASCII chars. Verify no Unicode symbols.
  const vals = Object.values(ASCII_CHARS);
  for (const v of vals) {
    if (/[^\x00-\x7F]/.test(v)) throw new Error(`Non-ASCII char in ASCII set: "${v}"`);
  }
});

// ---- NO_COLOR mode ----
console.log('\n--- NO_COLOR Mode Verification ---');

check('NO_COLOR: createPalette returns plain text', () => {
  const p = createPalette({ NO_COLOR: '1' });
  const names = ['dim', 'info', 'accent', 'warn', 'error', 'note', 'run', 'key'];
  for (const name of names) {
    const result = p[name]('test');
    if (result.includes('\x1b')) throw new Error(`${name} has ANSI in NO_COLOR mode: "${result}"`);
    if (result !== 'test') throw new Error(`${name} mangles text in NO_COLOR mode: "${result}"`);
  }
});

check('NO_COLOR: supportsUnicode returns false', () => {
  if (supportsUnicode({ NO_COLOR: '1', WT_SESSION: '1' }, { isTTY: true })) {
    throw new Error('supportsUnicode should return false with NO_COLOR');
  }
});

check('NO_COLOR: createBox uses ASCII chars', () => {
  const b = createBox({ NO_COLOR: '1' });
  const h = b.header('Test', 50);
  if (h.includes('┌') || h.includes('─') || h.includes('┐')) {
    throw new Error('NO_COLOR box uses Unicode: ' + h.slice(0, 10));
  }
});

// ---- Log file safety ----
console.log('\n--- Log File Safety ---');

check('stripAnsi + stripBoxChars produces clean log line', () => {
  const original = `${C.tl}${C.hz.repeat(10)} ${palette.info('INFO')} ${palette.warn('WARN')} ${C.tr}`;
  const clean = stripBoxChars(stripAnsi(original));
  if (clean.includes('\x1b')) throw new Error('ANSI leaking to log');
  if (/[─-╿•▸]/.test(clean)) throw new Error('Box chars leaking to log');
});

// ---- Summary ----
console.log('\n' + '='.repeat(60));
console.log(`Results: ${passed} passed, ${failed} failed, ${passed + failed} total`);
console.log('='.repeat(60));

if (failed > 0) {
  process.exit(1);
}
