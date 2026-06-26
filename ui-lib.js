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

module.exports = { createPalette, supportsUnicode };
