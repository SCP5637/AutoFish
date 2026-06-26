#!/usr/bin/env node

const { spawnSync } = require('child_process');
const fs = require('fs');

const segmentLog = process.argv[2];
const harnessModel = process.argv[3] || 'haiku';
const maxRetries = parseInt(process.argv[4] || '3', 10);

if (!segmentLog || !fs.existsSync(segmentLog)) {
  console.log(JSON.stringify({ harness: true, comment: 'empty segment, skipped' }));
  process.exit(0);
}

const raw = fs.readFileSync(segmentLog, 'utf8');
const outputTail = raw.slice(-8000);

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

for (let attempt = 1; attempt <= maxRetries; attempt++) {
  const result = spawnSync('claude', [
    '-p', checkPrompt,
    '--model', harnessModel,
    '--permission-mode', 'auto',
    '--max-turns', '5',
    '--max-budget-usd', '0.10',
  ], { encoding: 'utf8', maxBuffer: 1024 * 1024, timeout: 60000 });

  const output = (result.stdout || '').trim();

  try {
    const jsonMatch = output.match(/\{[\s\S]*"harness"[\s\S]*\}/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      if (typeof parsed.harness === 'boolean') {
        console.log(JSON.stringify(parsed));
        process.exit(0);
      }
    }
  } catch {}

  if (attempt < maxRetries) {
    process.stderr.write(`Harness check attempt ${attempt}: invalid format, retrying...\n`);
  }
}

process.stderr.write(`Harness check failed after ${maxRetries} attempts\n`);
process.exit(1);
