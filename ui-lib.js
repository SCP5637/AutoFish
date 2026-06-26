#!/usr/bin/env node

// UI library for AutoFish — shared color, Unicode detection, box drawing, text stripping.
// New palette names (dim/info/accent) coexist with old aliases (note/run/key).

function createPalette(env = {}) {
  const noColor = Boolean(env.NO_COLOR);
  const wrap = (code) => (text) => noColor ? text : `\x1b[${code}m${text}\x1b[0m`;

  const dim = wrap('90');
  const info = wrap('33');
  const accent = wrap('96');
  const warn = wrap('93');
  const error = wrap('91');

  return {
    dim,
    info,
    accent,
    warn,
    error,
    // 旧别名 — 保持向后兼容
    note: dim,
    run: info,
    key: accent,
  };
}

function supportsUnicode(env = {}, stream = process.stdout) {
  if (env.NO_COLOR) return false;
  if (stream && !stream.isTTY) return false;
  if (env.WT_SESSION) return true;
  if (env.LANG && env.LANG.toUpperCase().includes('UTF-8')) return true;
  if (env.TERM_PROGRAM) return true;
  return false;
}

function stripAnsi(text) {
  return String(text).replace(/\x1b\[[0-9;]*m/g, '');
}

function stripBoxChars(text) {
  return String(text).replace(/[─-╿•▸]/g, '');
}

function visualWidth(text) {
  return stripAnsi(String(text)).length;
}

function padOrTruncate(text, targetWidth) {
  const vis = visualWidth(text);
  if (vis === targetWidth) return text;
  if (vis < targetWidth) return text + ' '.repeat(targetWidth - vis);
  // truncate with ellipsis
  let out = '';
  let r = targetWidth - 1;
  for (const ch of String(text)) {
    if (r <= 0) break;
    out += ch;
    r--;
  }
  return out + '…';
}

// Box-drawing character sets
const UNICODE_CHARS = {
  tl: '┌', tr: '┐', bl: '└', br: '┘',
  hz: '─', vt: '│',
  lt: '├', rt: '┤', tt: '┬', bt: '┴', cr: '┼',
  bul: '•', arr: '▸',
};

const ASCII_CHARS = {
  tl: '+', tr: '+', bl: '+', br: '+',
  hz: '-', vt: '|',
  lt: '+', rt: '+', tt: '+', bt: '+', cr: '+',
  bul: '*', arr: '>',
};

function createBox(env = {}, stream = process.stdout) {
  const C = supportsUnicode(env, stream) ? UNICODE_CHARS : ASCII_CHARS;

  function header(title, width = 80) {
    if (!title) {
      return C.tl + C.hz.repeat(width - 2) + C.tr;
    }
    const inner = ' ' + title + ' ';
    if (inner.length + 2 > width) {
      return C.tl + C.hz.repeat(width - 2) + C.tr;
    }
    return C.tl + C.hz + inner + C.hz.repeat(width - 3 - inner.length) + C.tr;
  }

  function footer(width = 80) {
    return C.bl + C.hz.repeat(width - 2) + C.br;
  }

  function section(title, lines, width = 80) {
    const result = [header(title, width)];
    for (const line of lines) {
      const vis = visualWidth(line);
      const pad = Math.max(0, width - 3 - vis);
      result.push(C.vt + ' ' + line + ' '.repeat(pad) + C.vt);
    }
    result.push(footer(width));
    return result.join('\n');
  }

  function kv(key, value, width = 80, keyWidth = 14) {
    const label = (key + ':').padEnd(keyWidth);
    const vis = visualWidth(label) + 1 + visualWidth(value);
    const pad = Math.max(0, width - 3 - vis);
    return C.vt + ' ' + label + ' ' + value + ' '.repeat(pad) + C.vt;
  }

  function bullet(text, indent = 1, width = 80) {
    const prefix = ' '.repeat(indent * 2) + C.bul + ' ';
    const vis = visualWidth(prefix) + visualWidth(text);
    const pad = Math.max(0, width - 3 - vis);
    return C.vt + ' ' + prefix + text + ' '.repeat(pad) + C.vt;
  }

  function sep(width = 80) {
    return C.lt + C.hz.repeat(width - 2) + C.rt;
  }

  function hudLine(fields, width = 80) {
    const n = fields.length;
    // vt+space(2) + separators " │ " between fields
    const fixed = 2 + (n - 1) * 3;
    const colWidth = Math.floor((width - fixed) / n);
    const cells = fields.map((f) => {
      const text = f.label + ': ' + f.value;
      return padOrTruncate(text, colWidth);
    });
    return C.vt + ' ' + cells.join(' ' + C.vt + ' ') + ' ' + C.vt;
  }

  function box_line(text, width = 80) {
    const vis = visualWidth(text);
    const pad = Math.max(0, width - 3 - vis);
    return C.vt + ' ' + text + ' '.repeat(pad) + C.vt;
  }

  const box_header = header;
  const box_footer = footer;
  const box_sep = sep;

  return { header, footer, section, kv, bullet, sep, hudLine, box_header, box_footer, box_line, box_sep };
}

module.exports = { createPalette, supportsUnicode, stripAnsi, stripBoxChars, createBox, UNICODE_CHARS, ASCII_CHARS };
