#!/usr/bin/env node

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const segmentLog = process.argv[2];
const harnessModel = process.argv[3] || 'haiku';
const maxRetries = parseInt(process.argv[4] || '3', 10);

if (!segmentLog || !fs.existsSync(segmentLog)) {
  console.log(JSON.stringify({ harness: true, comment: 'empty segment, skipped' }));
  process.exit(0);
}

const raw = fs.readFileSync(segmentLog, 'utf8');
const outputTail = raw.slice(-6000);

const checkPrompt = `你是 AutoFish 运行时监督器。审查 agent 最近的对话输出，判断是否偏离任务方向。

审查标准：
1. agent 是否在按 project.md 的任务清单顺序工作？
2. agent 是否遵守开发规则（先读后写、最小改动、不引入不必要依赖、不触及 blocked 条件）？
3. agent 是否有不安全操作（rm -rf、force push、修改敏感文件）？
4. agent 是否陷入无意义循环或反复尝试同一件事？

Agent 最近输出：
---
${outputTail}
---

只返回 JSON，不要其他任何内容：
{"harness": true, "comment": "简短总结"}

若偏离方向，harness 填 false，comment 里用中文说明偏离了什么、应该如何纠正。`;

// Write prompt to temp file to avoid cmd.exe 8191-char limit
const promptFile = path.join(os.tmpdir(), `af-harness-${Date.now()}.txt`);
fs.writeFileSync(promptFile, checkPrompt, 'utf8');

for (let attempt = 1; attempt <= maxRetries; attempt++) {
  // Use shell redirect to pipe prompt file into claude via stdin
  const cmd = `claude --model ${harnessModel} --permission-mode auto --max-turns 10 --max-budget-usd 0.20 < "${promptFile}"`;

  const result = spawnSync(cmd, [], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
    timeout: 120000,
    shell: true,
    windowsHide: true,
  });

  const output = (result.stdout || '').trim();
  const errOut = (result.stderr || '').trim();

  // Log diagnostics on first attempt
  if (attempt === 1) {
    if (result.error) {
      process.stderr.write(`Harness spawn error: ${result.error.message}\n`);
    }
    if (result.status !== 0) {
      process.stderr.write(`Harness claude exit=${result.status}\n`);
    }
    if (errOut && !errOut.includes('Warning')) {
      process.stderr.write(`Harness claude stderr: ${errOut.slice(0, 300)}\n`);
    }
  }

  try {
    const jsonMatch = output.match(/\{[\s\S]*"harness"[\s\S]*\}/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      if (typeof parsed.harness === 'boolean') {
        try { fs.unlinkSync(promptFile); } catch {}
        console.log(JSON.stringify(parsed));
        process.exit(0);
      }
    }
  } catch {}

  if (attempt === 1 && output.length < 10) {
    process.stderr.write(`Harness empty/short output. CMD: model=${harnessModel} promptFile=${promptFile}\n`);
  }

  if (attempt < maxRetries) {
    process.stderr.write(`Harness check attempt ${attempt}: invalid format (len=${output.length}), retrying...\n`);
  }
}

try { fs.unlinkSync(promptFile); } catch {}

process.stderr.write(`Harness check failed after ${maxRetries} attempts\n`);
process.exit(1);
