#!/usr/bin/env node

const fs = require('fs');

const logFile = process.argv[2] || '';
const roundLabel = process.argv[3] || '?';
const noColor = Boolean(process.env.NO_COLOR);

let currentText = '';
let currentMessageIndex = 0;
let firstSentenceEmitted = false;
let seenSteps = new Set();
let toolIndex = 0;
let latestUsage = null;

const colors = {
  note: wrap('90'),
  run: wrap('33'),
  key: wrap('96'),
  warn: wrap('93'),
  error: wrap('91'),
};

process.stdin.setEncoding('utf8');

let buffer = '';
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  while (true) {
    const newline = buffer.indexOf('\n');
    if (newline === -1) {
      break;
    }
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) {
      continue;
    }
    handleLine(line);
  }
});

process.stdin.on('end', () => {
  flushCurrentMessage(true);
});

function wrap(code) {
  return (text) => noColor ? text : `\x1b[${code}m${text}\x1b[0m`;
}

function print(kind, text) {
  const line = colors[kind] ? colors[kind](text) : text;
  process.stdout.write(`${line}\n`);
  if (logFile) {
    try {
      fs.appendFileSync(logFile, `${text}\n`, 'utf8');
    } catch {}
  }
}

function handleLine(line) {
  let payload;
  try {
    payload = JSON.parse(line);
  } catch {
    return;
  }

  if (payload.type === 'stream_event') {
    handleStreamEvent(payload.event || {});
    return;
  }

  if (payload.type === 'assistant') {
    const blocks = payload.message && Array.isArray(payload.message.content) ? payload.message.content : [];
    for (const block of blocks) {
      if (block.type === 'text' && block.text) {
        currentText += block.text;
        maybeEmitFirstSentence();
        emitSteps(block.text);
      }
    }
    flushCurrentMessage(false);
    return;
  }

  if (payload.type === 'result') {
    emitUsageSummary(payload);
    if (payload.is_error) {
      print('warn', `Round ${roundLabel} result: stop_reason=${payload.stop_reason || 'unknown'} errors=${(payload.errors || []).join(' | ')}`);
    }
  }
}

function handleStreamEvent(event) {
  if (!event || !event.type) {
    return;
  }

  if (event.type === 'content_block_start') {
    const block = event.content_block || {};
    if (block.type === 'text') {
      currentMessageIndex += 1;
      currentText = '';
      firstSentenceEmitted = false;
      seenSteps = new Set();
      return;
    }
    if (block.type === 'tool_use') {
      toolIndex += 1;
      const toolName = block.name || 'tool';
      print('run', `Tool#${toolIndex}: ${toolName}`);
      return;
    }
  }

  if (event.type === 'content_block_delta') {
    const delta = event.delta || {};
    if (delta.type === 'text_delta' && delta.text) {
      currentText += delta.text;
      maybeEmitFirstSentence();
      emitSteps(delta.text);
      return;
    }
  }

  if (event.type === 'content_block_stop') {
    flushCurrentMessage(false);
    return;
  }

  if (event.type === 'message_delta' && event.usage) {
    latestUsage = event.usage;
  }
}

function maybeEmitFirstSentence() {
  if (firstSentenceEmitted || !currentText.trim()) {
    return;
  }

  const sentence = extractSentence(currentText);
  if (!sentence) {
    if (currentText.trim().length >= 80) {
      const clipped = currentText.trim().replace(/\s+/g, ' ').slice(0, 80);
      print('run', `CC#${currentMessageIndex}: ${clipped}...`);
      firstSentenceEmitted = true;
    }
    return;
  }

  print('run', `CC#${currentMessageIndex}: ${sentence}`);
  firstSentenceEmitted = true;
}

function emitSteps(text) {
  const lines = text.split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }
    const match = line.match(/^(?:[-*•]|\d+[.)])\s+(.+)$/);
    if (!match) {
      continue;
    }
    const step = match[1].trim();
    if (!step || seenSteps.has(step)) {
      continue;
    }
    seenSteps.add(step);
    print('note', `  step: ${step}`);
  }
}

function flushCurrentMessage(force) {
  if (!currentText.trim()) {
    return;
  }
  if (!firstSentenceEmitted && force) {
    const clipped = currentText.trim().replace(/\s+/g, ' ').slice(0, 120);
    print('run', `CC#${currentMessageIndex || 1}: ${clipped}${currentText.trim().length > 120 ? '...' : ''}`);
    firstSentenceEmitted = true;
  }
}

function extractSentence(text) {
  const normalized = text.trim().replace(/\s+/g, ' ');
  const match = normalized.match(/^(.{1,160}?[。！？.!?]|.{1,160}?\n)/);
  if (!match) {
    return null;
  }
  return match[1].trim();
}

function emitUsageSummary(resultPayload) {
  const usage = resultPayload.usage || latestUsage || {};
  const modelUsage = resultPayload.modelUsage ? Object.values(resultPayload.modelUsage)[0] : null;

  const inputTokens = numberOrZero(modelUsage?.inputTokens ?? usage.input_tokens);
  const outputTokens = numberOrZero(modelUsage?.outputTokens ?? usage.output_tokens);
  const cacheCreate = numberOrZero(modelUsage?.cacheCreationInputTokens ?? usage.cache_creation_input_tokens);
  const cacheRead = numberOrZero(modelUsage?.cacheReadInputTokens ?? usage.cache_read_input_tokens);
  const totalCost = typeof resultPayload.total_cost_usd === 'number' ? resultPayload.total_cost_usd : 0;
  const denominator = inputTokens + cacheCreate + cacheRead;
  const cacheHit = denominator > 0 ? ((cacheRead / denominator) * 100).toFixed(1) : '0.0';

  print('key', `Round ${roundLabel} tokens: in=${inputTokens} out=${outputTokens} cache_create=${cacheCreate} cache_read=${cacheRead} cache_hit=${cacheHit}% cost=$${totalCost.toFixed(4)}`);
}

function numberOrZero(value) {
  const numeric = Number(value || 0);
  return Number.isFinite(numeric) ? numeric : 0;
}
