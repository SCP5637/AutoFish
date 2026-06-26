#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const readline = require('readline');
const { spawnSync, spawn } = require('child_process');

const { createBox, createPalette, supportsUnicode, stripAnsi, UNICODE_CHARS, ASCII_CHARS } = require('./ui-lib');

const ROOT = normalizePath(process.env.AUTOFISH_ROOT || __dirname);
const ROOT_CONFIG_FILE = path.join(ROOT, 'config.json');
const STATE_DIR = path.join(ROOT, 'state');
const PROJECTS_DIR = path.join(STATE_DIR, 'projects');
const REGISTRY_FILE = path.join(STATE_DIR, 'configList.json');
const BASH = process.env.AUTOFISH_BASH || 'bash';
const CLAUDE_HOME = path.join(os.homedir(), '.claude');
const CLAUDE_HOOKS_DIR = path.join(CLAUDE_HOME, 'hooks');
const CLAUDE_SETTINGS_FILE = path.join(CLAUDE_HOME, 'settings.json');
const CLAUDE_SETTINGS_LOCAL_FILE = path.join(CLAUDE_HOME, 'settings.local.json');
const SAFE_SETUP_HOOKS = Object.freeze([
  'destructive-guard.sh',
  'branch-guard.sh',
  'syntax-check.sh',
  'context-monitor.sh',
  'comment-strip.sh',
  'cd-git-allow.sh',
  'secret-guard.sh',
  'api-error-alert.sh',
]);

const DEFAULT_BOOTSTRAP = Object.freeze({
  schema_version: 1,
  status: 'not_started',
  phase: 0,
  project_doc_confirmed: false,
  config_decision: 'pending',
  confirmed_at: null,
  confirmed_by: null,
  project_doc_source: 'none',
  last_started_at: null,
  last_updated_at: null,
});

const DEFAULT_WNTD = Object.freeze({
  schema_version: 1,
  status: 'idle',
  last_reason: null,
  continue_after_resolved: null,
  continue_decided_at: null,
  runtime_config_change_requested: null,
  runtime_config_decided_at: null,
  runtime_config_updated_at: null,
  last_requested_at: null,
  last_started_at: null,
  last_finished_at: null,
  last_blocked_at: null,
  last_resolved_at: null,
});

const COLOR = createPalette(process.env.AUTOFISH_COLOR === 'never' ? { NO_COLOR: '1' } : process.env);

main().catch((error) => {
  console.error(colorize('error', `[FATAL] ${error.message}`));
  process.exit(1);
});

async function main() {
  ensureDir(STATE_DIR);
  ensureDir(PROJECTS_DIR);

  const registry = loadRegistry();
  const selection = await selectProject(registry);

  if (!selection) {
    console.log(`\n${colorize('dim', 'AutoFish exited.')}`);
    return;
  }

  if (!fs.existsSync(selection.projectDir)) {
    console.log(`\n${colorize('error', '=== Project missing ===')}`);
    console.log(colorize('dim', `Path: ${selection.projectDir}`));
    console.log(colorize('dim', 'Re-register project with New Project.'));
    return;
  }

  let projectConfig;
  while (true) {
    projectConfig = ensureProjectState(selection);
    projectConfig = maybeImportRootProjectDoc(selection, projectConfig);
    projectConfig = ensureProjectState(selection, projectConfig);

    const initialStatus = projectStatus(selection, projectConfig);
    if (fs.existsSync(selection.projectDoc) && initialStatus === 'needs-confirmation' && projectConfig.bootstrap.status === 'not_started') {
      projectConfig = setBootstrapState(selection, {
        status: 'awaiting_project_confirmation',
        phase: 4,
        project_doc_confirmed: false,
        config_decision: 'pending',
        confirmed_at: null,
        confirmed_by: null,
        project_doc_source: projectConfig.bootstrap.project_doc_source === 'none' ? 'manual_existing' : projectConfig.bootstrap.project_doc_source,
      }, projectConfig);
    }

    registry.lastProjectId = selection.id;
    selection.lastSelectedAt = new Date().toISOString();
    upsertProject(registry, selection);
    saveRegistry(registry);

    const status = projectStatus(selection, projectConfig);
    printProjectSummary(selection, projectConfig, status);

    const pluginReport = checkPluginPreflight(projectConfig);
    printPluginPreflight(pluginReport);

    const launchPlan = resolveProjectLaunchPlan(selection, projectConfig, pluginReport);
    if (launchPlan.type === 'safe-setup') {
      const launched = openSafeSetupWindow(selection, pluginReport);
      printSafeSetupLaunchResult(launched, pluginReport, selection);
      return;
    }

    if (launchPlan.type === 'bootstrap') {
      projectConfig = markBootstrapLaunch(selection, projectConfig, launchPlan.mode);
      const launched = openBootstrapWindow(selection, projectConfig, launchPlan.mode, launchPlan.reason);
      if (!launched) {
        printBootstrapLaunchResult(selection, projectConfig, launched, launchPlan.reason);
        return;
      }
      projectConfig = ensureProjectState(selection);
      if (!isBootstrapConfirmed(projectConfig)) {
        printBootstrapLaunchResult(selection, projectConfig, launched, launchPlan.reason);
        const retry = await confirm('Bootstrap not complete. Open bootstrap window again? [Y/n]: ', true);
        if (retry) {
          continue;
        }
        return;
      }
      console.log(colorize('info', 'Bootstrap confirmed. Continuing to run-loop...\n'));
      continue;
    }

    const initialWntdReason = launchPlan.type === 'wntd' ? launchPlan.reason : null;
    ensureRuntimeFiles(selection);
    const wntdResult = await runProjectWithWntd(selection, projectConfig, initialWntdReason);
    if (wntdResult && wntdResult.archived) {
      projectConfig = ensureProjectState(selection);
      continue;
    }
    break;
  }
}

async function selectProject(registry) {
  while (true) {
    printMenu(registry);
    const answer = (await ask('Select: ')).trim();

    if (!answer) {
      console.log('');
      continue;
    }

    if (/^x$/i.test(answer)) {
      return null;
    }

    if (answer === '0') {
      if (!registry.lastProjectId) {
        console.log(`\n${colorize('warn', '[INPUT] No last project.')}\n`);
        continue;
      }

      const last = registry.projects.find((project) => project.id === registry.lastProjectId);
      if (!last) {
        console.log(`\n${colorize('warn', '[INPUT] Last project missing from registry.')}\n`);
        continue;
      }

      return normalizeProjectRecord(last);
    }

    const newProjectIndex = registry.projects.length + 1;
    if (answer === String(newProjectIndex)) {
      const created = await createNewProjectInteractive(registry);
      if (created) {
        return created;
      }
      continue;
    }

    const index = Number.parseInt(answer, 10);
    if (!Number.isNaN(index) && index >= 1 && index <= registry.projects.length) {
      return normalizeProjectRecord(registry.projects[index - 1]);
    }

    console.log(`\n${colorize('warn', '[INPUT] Invalid selection.')}\n`);
  }
}

function printMenu(registry) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;

  const ICON = {
    ok: unicode ? '✓' : '[OK]',
    fail: unicode ? '✗' : '[XX]',
    warn: unicode ? '⚠' : '[!!]',
  };
  const ARROW = unicode ? '▸' : '>';

  function statusIcon(project) {
    const s = projectStatus(project);
    if (s === 'ready' || s === 'complete') return palette.info(ICON.ok) + ' ' + s;
    if (s === 'missing') return palette.error(ICON.fail) + ' ' + s;
    return palette.warn(ICON.warn) + ' ' + s;
  }

  function boxLine(inner) {
    const visible = stripAnsi(inner).length;
    const pad = Math.max(0, W - 4 - visible);
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
    const gap = Math.max(1, W - 6 - leftVis - rightVis);
    return left + ' '.repeat(gap) + right;
  }

  console.log('');
  console.log(box.header('AutoFish', W));
  console.log(box.kv('Root', toPosixPath(ROOT), W));

  console.log(box.sep(W));
  console.log(boxLine(palette.accent('Last:')));
  if (registry.lastProjectId) {
    const last = registry.projects.find((p) => p.id === registry.lastProjectId);
    if (last) {
      console.log(boxLine('  ' + projectRow(0, last)));
      console.log(boxLine(palette.dim('     ' + last.projectDir)));
    } else {
      console.log(boxLine(palette.dim('  0. none')));
    }
  } else {
    console.log(boxLine(palette.dim('  0. none')));
  }

  console.log(box.sep(W));
  console.log(boxLine(palette.accent('Projects:')));
  if (registry.projects.length === 0) {
    console.log(boxLine(palette.dim('  (none)')));
  } else {
    registry.projects.forEach((project, index) => {
      console.log(boxLine('  ' + projectRow(index + 1, project)));
      console.log(boxLine(palette.dim('     ' + project.projectDir)));
    });
  }

  console.log(box.sep(W));
  console.log(boxLine(palette.accent(ARROW) + ' ' + palette.info(`${registry.projects.length + 1}. New Project`)));
  console.log(boxLine(palette.accent(ARROW) + ' ' + palette.info('X. Exit')));

  console.log(box.footer(W));
}

async function createNewProjectInteractive(registry) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_WARN = unicode ? '⚠' : '[!!]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  while (true) {
    console.log(`\n${box.header('New Project', W)}\n`);
    const raw = (await ask('Input project path (blank = cancel): ')).trim();
    if (!raw) {
      console.log('');
      return null;
    }

    const resolved = await resolveProjectPathInteractive(raw);
    if (!resolved) {
      continue;
    }

    if (samePath(resolved, ROOT)) {
      const confirmSelf = await confirm('Target is AutoFish root itself. Continue? [y/N]: ', false);
      if (!confirmSelf) {
        console.log('');
        continue;
      }
    }

    const existing = registry.projects.find((project) => samePath(project.projectDir, resolved));
    if (existing) {
      console.log('');
      console.log(box.header('Project exists', W));
      console.log(boxLine(palette.warn(ICON_WARN + ' Using existing project: ' + existing.name)));
      console.log(box.footer(W));
      console.log('');
      return normalizeProjectRecord(existing);
    }

    const record = buildProjectRecord(resolved);
    ensureProjectState(record);
    upsertProject(registry, record);
    saveRegistry(registry);
    return record;
  }
}

async function resolveProjectPathInteractive(inputPath) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_WARN = unicode ? '⚠' : '[!!]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  const normalizedInput = normalizeInputPath(inputPath);
  if (!normalizedInput) {
    console.log('');
    console.log(box.header('Path invalid', W));
    console.log(boxLine(palette.warn(ICON_WARN + ' Input path could not be resolved.')));
    console.log(box.footer(W));
    console.log('');
    return null;
  }

  const directRoot = gitRootFor(normalizedInput);
  if (directRoot) {
    if (!samePath(directRoot, normalizedInput)) {
      const useRoot = await confirm(`Found git root at "${directRoot}". Use it? [Y/n]: `, true);
      return useRoot ? directRoot : null;
    }
    return directRoot;
  }

  const candidates = findNearbyGitProjects(normalizedInput, 3);
  if (candidates.length === 0) {
    const useCurrent = await confirm('No git project found within 3 parent/child levels. Use current path anyway? [y/N]: ', false);
    return useCurrent ? normalizedInput : null;
  }

  if (candidates.length === 1) {
    const useFound = await confirm(`Current path is not a git project. Found one at "${candidates[0]}". Use it? [Y/n]: `, true);
    return useFound ? candidates[0] : null;
  }

  console.log('');
  console.log(box.header('Detected projects', W));
  console.log(boxLine(palette.warn(ICON_WARN + ' Current path is not a git project. Found multiple nearby projects:'), 1));
  candidates.forEach((candidate, index) => {
    console.log(boxLine(palette.dim('  ' + (index + 1) + '. ' + candidate), 1));
  });
  console.log(box.sep(W));
  console.log(boxLine(palette.info('C. Use current path anyway')));
  console.log(boxLine(palette.info('R. Re-enter path')));
  console.log(box.footer(W));
  console.log('');

  while (true) {
    const answer = (await ask('Choose: ')).trim();
    if (/^r$/i.test(answer)) {
      return null;
    }
    if (/^c$/i.test(answer)) {
      const confirmCurrent = await confirm('Use current path even though it is not a git project? [y/N]: ', false);
      return confirmCurrent ? normalizedInput : null;
    }

    const index = Number.parseInt(answer, 10);
    if (!Number.isNaN(index) && index >= 1 && index <= candidates.length) {
      return candidates[index - 1];
    }

    console.log('');
    console.log(box.header('Invalid selection', W));
    console.log(boxLine(palette.warn(ICON_WARN + ' Please enter a number (1-' + candidates.length + '), C, or R.')));
    console.log(box.footer(W));
    console.log('');
  }
}

function findNearbyGitProjects(basePath, maxDepth) {
  const visitedDirs = new Set();
  const roots = new Map();

  const collect = (dir, depth) => {
    const normalized = normalizePath(dir);
    if (visitedDirs.has(normalized)) {
      return;
    }
    visitedDirs.add(normalized);

    const gitRoot = gitRootFor(normalized);
    if (gitRoot) {
      roots.set(gitRoot.toLowerCase(), gitRoot);
    }

    if (depth === 0) {
      return;
    }

    let entries = [];
    try {
      entries = fs.readdirSync(normalized, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.isDirectory()) {
        continue;
      }
      if (shouldSkipDir(entry.name)) {
        continue;
      }
      collect(path.join(normalized, entry.name), depth - 1);
    }
  };

  collect(basePath, maxDepth);

  let parent = normalizePath(basePath);
  for (let level = 0; level < maxDepth; level += 1) {
    const next = normalizePath(path.dirname(parent));
    if (samePath(next, parent)) {
      break;
    }
    parent = next;
    const gitRoot = gitRootFor(parent);
    if (gitRoot) {
      roots.set(gitRoot.toLowerCase(), gitRoot);
    }
  }

  return Array.from(roots.values()).sort((a, b) => a.localeCompare(b));
}

function shouldSkipDir(name) {
  return new Set([
    '.git',
    '.hg',
    '.svn',
    '.idea',
    '.vscode',
    '.claude',
    'node_modules',
    'dist',
    'build',
    'target',
    'bin',
    'obj',
    'out',
    'coverage',
    'state',
  ]).has(name);
}

function gitRootFor(targetPath) {
  const result = spawnSync('git', ['-C', targetPath, 'rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    windowsHide: true,
  });

  if (result.status !== 0) {
    return null;
  }

  const value = result.stdout.trim();
  return value ? normalizePath(value) : null;
}

function ensureProjectState(project, seedConfig = null) {
  ensureDir(project.stateDir);
  ensureDir(project.runtimeDir);

  const rootConfig = readJson(ROOT_CONFIG_FILE, {});
  const existingConfig = seedConfig || readJson(project.configFile, {});
  const mergedConfig = mergeDeep(rootConfig, existingConfig);
  const normalizedConfig = normalizeProjectConfig(mergedConfig, project);

  if (!fs.existsSync(project.configFile) || JSON.stringify(existingConfig) !== JSON.stringify(normalizedConfig)) {
    writeJson(project.configFile, normalizedConfig);
  }

  return normalizedConfig;
}

function normalizeProjectConfig(config, project) {
  const normalized = mergeDeep({}, config);
  normalized.project_dir = project.projectDir;
  normalized.project_doc = project.projectDoc;
  normalized.state_dir = project.stateDir;
  normalized.runtime_dir = project.runtimeDir;
  normalized.project_id = project.id;
  normalized.bootstrap = normalizeBootstrapState(normalized.bootstrap, fs.existsSync(project.projectDoc));
  normalized.wntd = normalizeWntdState(normalized.wntd);
  return normalized;
}

function normalizeBootstrapState(currentBootstrap, hasProjectDoc) {
  const bootstrap = { ...DEFAULT_BOOTSTRAP, ...(currentBootstrap || {}) };

  if (!currentBootstrap && hasProjectDoc) {
    bootstrap.status = 'awaiting_project_confirmation';
    bootstrap.phase = 4;
    bootstrap.project_doc_source = 'manual_existing';
  }

  return bootstrap;
}

function normalizeWntdState(currentWntd) {
  const wntd = { ...DEFAULT_WNTD, ...(currentWntd || {}) };
  const allowedStatus = new Set(['idle', 'pending', 'in_progress', 'resolved', 'blocked']);
  if (!allowedStatus.has(wntd.status)) {
    wntd.status = 'idle';
  }
  if (typeof wntd.continue_after_resolved !== 'boolean') {
    wntd.continue_after_resolved = null;
  }
  if (typeof wntd.runtime_config_change_requested !== 'boolean') {
    wntd.runtime_config_change_requested = null;
  }
  return wntd;
}

function maybeImportRootProjectDoc(project, projectConfig) {
  if (fs.existsSync(project.projectDoc)) {
    return projectConfig;
  }

  const rootDoc = path.join(project.projectDir, 'project.md');
  if (!fs.existsSync(rootDoc)) {
    return projectConfig;
  }

  fs.copyFileSync(rootDoc, project.projectDoc);
  return setBootstrapState(project, {
    status: 'awaiting_project_confirmation',
    phase: 4,
    project_doc_confirmed: false,
    config_decision: 'pending',
    confirmed_at: null,
    confirmed_by: null,
    project_doc_source: 'imported_root_project_md',
  }, projectConfig);
}

function setBootstrapState(project, patch, baseConfig = null) {
  const currentConfig = baseConfig || ensureProjectState(project);
  const now = new Date().toISOString();
  const updatedConfig = mergeDeep(currentConfig, {
    bootstrap: {
      ...currentConfig.bootstrap,
      ...patch,
      last_updated_at: now,
    },
  });

  if (patch.status === 'in_progress') {
    updatedConfig.bootstrap.last_started_at = now;
  }

  writeJson(project.configFile, updatedConfig);
  return updatedConfig;
}

function setWntdState(project, patch, baseConfig = null) {
  const currentConfig = baseConfig || ensureProjectState(project);
  const updatedConfig = mergeDeep(currentConfig, {
    wntd: {
      ...normalizeWntdState(currentConfig.wntd),
      ...patch,
    },
  });

  writeJson(project.configFile, updatedConfig);
  return updatedConfig;
}

function runtimeControlSnapshot(config) {
  return {
    max_rounds: config.max_rounds ?? null,
    max_turns_per_round: config.max_turns_per_round ?? null,
    max_budget_per_round_usd: config.max_budget_per_round_usd ?? null,
    runtime: {
      max_duration_minutes: config.runtime?.max_duration_minutes ?? null,
      stop_at: config.runtime?.stop_at ?? null,
    },
  };
}

function markBootstrapLaunch(project, projectConfig, mode) {
  const hasProjectDoc = fs.existsSync(project.projectDoc);
  const phase = !hasProjectDoc ? 1 : (!projectConfig.bootstrap.project_doc_confirmed ? 4 : 5);
  return setBootstrapState(project, {
    status: 'in_progress',
    phase,
    project_doc_confirmed: hasProjectDoc ? projectConfig.bootstrap.project_doc_confirmed : false,
    config_decision: hasProjectDoc ? projectConfig.bootstrap.config_decision : 'pending',
  }, projectConfig);
}

function resolveProjectLaunchPlan(project, projectConfig, pluginReport) {
  if (pluginReport.shouldBlock || pluginReport.shouldOpenAssistant) {
    return { type: 'safe-setup' };
  }

  if (!fs.existsSync(project.projectDoc)) {
    return {
      type: 'bootstrap',
      mode: 'new',
      reason: 'project.md missing',
    };
  }

  if (!isBootstrapConfirmed(projectConfig)) {
    return {
      type: 'bootstrap',
      mode: 'review',
      reason: bootstrapReason(projectConfig),
    };
  }

  const wntdReason = blockedInteractionReason(project);
  if (wntdReason) {
    return {
      type: 'wntd',
      reason: wntdReason,
    };
  }

  return { type: 'run-loop' };
}

function blockedInteractionReason(project) {
  const normalized = normalizeProjectRecord(project);
  const blockedFile = path.join(normalized.runtimeDir, 'task-blocked.txt');
  if (fs.existsSync(blockedFile) && fs.readFileSync(blockedFile, 'utf8').includes('ALL_BLOCKED')) {
    return 'task-blocked.txt contains ALL_BLOCKED';
  }

  if (fs.existsSync(path.join(normalized.runtimeDir, 'WhatNeedToDo.md'))) {
    const checklist = readWntdChecklistState(project);
    if (checklist && checklist.unresolved === 0 && checklist.resolved > 0) {
      cleanupResolvedWntdArtifacts(project);
      return null;
    }
    return 'WhatNeedToDo.md already exists';
  }

  return null;
}

function hasBlockedInteraction(project) {
  return blockedInteractionReason(project) !== null;
}

function readWntdChecklistState(project) {
  const normalized = normalizeProjectRecord(project);
  const wntdFile = path.join(normalized.runtimeDir, 'WhatNeedToDo.md');
  if (!fs.existsSync(wntdFile)) {
    return null;
  }

  const lines = fs.readFileSync(wntdFile, 'utf8').split(/\r?\n/);
  let inBlockedSection = false;
  let unresolved = 0;
  let resolved = 0;

  for (const line of lines) {
    if (!inBlockedSection) {
      if (line.trim() === '## 阻塞任务清单') {
        inBlockedSection = true;
      }
      continue;
    }

    if (/^##\s/.test(line)) {
      break;
    }

    if (/^- \[x\]/.test(line)) {
      resolved += 1;
    } else if (/^- \[ \]/.test(line)) {
      unresolved += 1;
    }
  }

  return { resolved, unresolved };
}

function cleanupResolvedWntdArtifacts(project) {
  const normalized = normalizeProjectRecord(project);
  const wntdFile = path.join(normalized.runtimeDir, 'WhatNeedToDo.md');
  try {
    fs.unlinkSync(wntdFile);
  } catch {}

  const blockedFile = path.join(normalized.runtimeDir, 'task-blocked.txt');
  if (!fs.existsSync(blockedFile)) {
    return;
  }

  const nextContent = fs.readFileSync(blockedFile, 'utf8')
    .split(/\r?\n/)
    .filter((line) => line.trim() !== 'ALL_BLOCKED')
    .join('\n')
    .replace(/\n+$/, '');

  fs.writeFileSync(blockedFile, nextContent ? `${nextContent}\n` : '', 'utf8');
}

function decidePostWntdAction(project, projectConfig, nextStatus) {
  const wntdState = readWntdChecklistState(project);
  const wntdConfig = normalizeWntdState(projectConfig.wntd);
  const allResolved = Boolean(wntdState && wntdState.unresolved === 0 && wntdState.resolved > 0);

  if (allResolved) {
    if (wntdConfig.continue_after_resolved === false) {
      return { action: 'pause', wntdState, shouldCleanup: true };
    }
    return { action: 'continue', wntdState, shouldCleanup: true };
  }

  if (nextStatus !== 'blocked') {
    return { action: 'continue', wntdState, shouldCleanup: false };
  }

  return { action: 'stop', wntdState, shouldCleanup: false };
}

function launchClaudeWindow(project, options) {
  const {
    title,
    prompt,
    scriptPath,
    env = {},
    missingClaudeHint,
    exitHint,
    waitForExit = false,
  } = options;

  const script = `$ErrorActionPreference = 'Stop'\n$Host.UI.RawUI.WindowTitle = '${psSingleQuote(title)}'\n$sessionPrompt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('${Buffer.from(prompt, 'utf8').toString('base64')}'))\n${Object.entries(env).map(([key, value]) => `$env:${key} = '${psSingleQuote(value)}'`).join('\n')}\nSet-Location -LiteralPath '${psSingleQuote(project.projectDir)}'\nif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {\n  Write-Host '[ERROR] claude not found in PATH.' -ForegroundColor Red\n  Write-Host '${psSingleQuote(missingClaudeHint)}' -ForegroundColor DarkYellow\n  return\n}\n& claude -n '${psSingleQuote(title)}' $sessionPrompt\nWrite-Host ''\nWrite-Host '${psSingleQuote(exitHint)}' -ForegroundColor DarkYellow\n`;
  fs.writeFileSync(scriptPath, script, 'utf8');

  const startArgs = ['/c', 'start', ''];
  if (waitForExit) {
    startArgs.push('/wait');
  }
  startArgs.push('powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', scriptPath);

  const result = spawnSync('cmd.exe', startArgs, {
    cwd: project.projectDir,
    env: process.env,
    windowsHide: false,
  });

  return result.status === 0 && !result.error;
}


function ensureRuntimeFiles(project) {
  ensureDir(project.runtimeDir);

  for (const file of ['auto-log.txt', 'task-done.txt', 'task-blocked.txt']) {
    const target = path.join(project.runtimeDir, file);
    if (!fs.existsSync(target)) {
      fs.writeFileSync(target, '', 'utf8');
    }
  }

  const roundFile = path.join(project.runtimeDir, 'auto-round.txt');
  if (!fs.existsSync(roundFile)) {
    fs.writeFileSync(roundFile, '0\n', 'utf8');
  }
}

function checkPluginPreflight(projectConfig) {
  const plugins = projectConfig.plugins || {};
  const required = Array.isArray(plugins.required) ? plugins.required : [];
  const optional = Array.isArray(plugins.optional) ? plugins.optional : [];
  const checkEnabled = plugins.check_on_startup !== false;
  const openInstallAssistant = plugins.open_install_assistant_on_missing !== false;
  const doctorOnStartup = plugins.doctor_on_startup === true;

  const report = {
    skipped: !checkEnabled,
    required,
    optional,
    missingRequired: [],
    missingOptional: [],
    warnings: [],
    notes: [],
    details: [],
    shouldBlock: false,
    shouldOpenAssistant: false,
  };

  if (!checkEnabled) {
    return report;
  }

  const allPlugins = [...new Set([...required, ...optional])];
  for (const plugin of allPlugins) {
    const isRequired = required.includes(plugin);
    const detail = inspectPlugin(plugin, { doctorOnStartup });
    report.details.push(detail);

    if (!detail.ok) {
      if (isRequired) {
        report.missingRequired.push(plugin);
      } else {
        report.missingOptional.push(plugin);
      }
    }

    if (detail.warnings.length > 0) {
      report.warnings.push(...detail.warnings);
    }
    if (detail.notes.length > 0) {
      report.notes.push(...detail.notes);
    }
  }

  report.shouldBlock = report.missingRequired.length > 0;
  report.shouldOpenAssistant = openInstallAssistant && (report.missingRequired.length > 0 || report.missingOptional.includes('cc-safe-setup'));
  return report;
}

function inspectPlugin(plugin, options = {}) {
  if (plugin === 'cc-safe-setup') {
    return inspectSafeSetup(options);
  }

  const commandExistsResult = commandExists(plugin);
  if (commandExistsResult) {
    return {
      plugin,
      ok: true,
      status: 'installed',
      warnings: [],
      notes: [`${plugin}: command found in PATH`],
    };
  }

  const npmCheck = spawnSync('npm', ['list', '-g', plugin], {
    encoding: 'utf8',
    windowsHide: true,
  });

  if (npmCheck.status === 0) {
    return {
      plugin,
      ok: true,
      status: 'installed',
      warnings: [],
      notes: [`${plugin}: found in global npm packages`],
    };
  }

  return {
    plugin,
    ok: false,
    status: 'missing',
    warnings: [],
    notes: [`${plugin}: not found in PATH or global npm packages`],
  };
}

function inspectSafeSetup(options = {}) {
  const warnings = [];
  const notes = [];

  const hooksDirExists = fs.existsSync(CLAUDE_HOOKS_DIR);
  const hookFiles = SAFE_SETUP_HOOKS.filter((file) => fs.existsSync(path.join(CLAUDE_HOOKS_DIR, file)));
  const hooksDirFiles = hooksDirExists
    ? fs.readdirSync(CLAUDE_HOOKS_DIR).filter((name) => name.endsWith('.sh'))
    : [];

  const settingsFiles = [CLAUDE_SETTINGS_FILE, CLAUDE_SETTINGS_LOCAL_FILE].filter((file) => fs.existsSync(file));
  const settingsText = settingsFiles.map((file) => fs.readFileSync(file, 'utf8')).join('\n');
  const hooksRegistered = settingsText.includes('hooks') && (settingsText.includes('/hooks/') || SAFE_SETUP_HOOKS.some((file) => settingsText.includes(file)));

  const jqInstalled = commandExists('jq');
  const gccInstalled = commandExists('gcc');

  if (!hooksDirExists) {
    notes.push(`cc-safe-setup: hooks directory missing -> ${CLAUDE_HOOKS_DIR}`);
  } else {
    notes.push(`cc-safe-setup: hooks directory found -> ${CLAUDE_HOOKS_DIR}`);
  }

  if (hookFiles.length < 4) {
    notes.push(`cc-safe-setup: expected hook scripts too few (${hookFiles.length}/${SAFE_SETUP_HOOKS.length})`);
  } else {
    notes.push(`cc-safe-setup: found ${hookFiles.length}/${SAFE_SETUP_HOOKS.length} expected hook scripts`);
  }

  if (!hooksRegistered) {
    notes.push('cc-safe-setup: no hook registration found in Claude settings');
  } else {
    notes.push('cc-safe-setup: hook registration found in Claude settings');
  }

  if (!jqInstalled) {
    warnings.push('cc-safe-setup: jq not found in PATH; some hook logic may fail');
  }
  if (!gccInstalled) {
    warnings.push('cc-safe-setup: gcc not found in PATH; syntax-check hook may fail');
  }

  if (options.doctorOnStartup) {
    const doctor = spawnSync('npx', ['cc-safe-setup', '--doctor'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    if (doctor.status === 0) {
      notes.push('cc-safe-setup: doctor passed');
    } else {
      warnings.push('cc-safe-setup: doctor failed or returned non-zero');
    }
  }

  const ok = hooksDirExists && hookFiles.length >= 4 && hooksRegistered;

  return {
    plugin: 'cc-safe-setup',
    ok,
    status: ok ? 'installed' : 'missing',
    warnings,
    notes,
    meta: {
      hooksDirExists,
      hookFiles,
      hooksDirFiles,
      settingsFiles,
      hooksRegistered,
      jqInstalled,
      gccInstalled,
    },
  };
}

function printPluginPreflight(report) {
  if (report.skipped) {
    console.log(colorize('dim', 'Plugin preflight skipped by config.'));
    console.log('');
    return;
  }

  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_OK = unicode ? '✓' : '[OK]';
  const ICON_FAIL = unicode ? '✗' : '[XX]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  console.log('');
  console.log(box.header('Plugin preflight', W));

  for (const detail of report.details) {
    const icon = detail.ok ? palette.info(ICON_OK) : palette.error(ICON_FAIL);
    console.log(boxLine(icon + ' ' + detail.plugin + ': ' + detail.status));
    for (const note of detail.notes) {
      console.log(boxLine(palette.dim(note), 1));
    }
  }

  if (report.warnings.length > 0) {
    console.log(box.sep(W));
    for (const warning of report.warnings) {
      console.log(boxLine(palette.warn(warning), 1));
    }
  }

  if (report.missingRequired.length > 0 || report.missingOptional.length > 0) {
    console.log(box.sep(W));
    console.log(boxLine(palette.info('install: npx cc-safe-setup'), 1));
    console.log(boxLine(palette.info('verify:  npx cc-safe-setup --doctor'), 1));
    console.log(boxLine(palette.info('after:   restart Claude Code / AutoFish'), 1));
  }

  console.log(box.footer(W));
  console.log('');
}

function openSafeSetupWindow(project, pluginReport) {
  const detail = pluginReport.details.find((item) => item.plugin === 'cc-safe-setup');
  const diagnostics = detail ? [...detail.notes, ...detail.warnings] : ['cc-safe-setup missing'];
  const prompt = [
    '# AutoFish safety hooks setup assistant',
    '',
    '你现在不是在做项目开发。你只负责帮助用户安装并验证 AutoFish 所需的安全 hooks。',
    '',
    '要求：',
    '1. 解释 AutoFish 检测到的 hooks 缺失或无效问题。',
    '2. 指导用户执行 `! npx cc-safe-setup`。',
    '3. 如缺少依赖，指导用户安装 jq / gcc。',
    '4. 指导用户执行 `! npx cc-safe-setup --doctor`。',
    '5. 检查 `~/.claude/hooks` 与 `~/.claude/settings.json`。',
    '6. 安装完成后明确提醒：必须重启 Claude Code / AutoFish。',
    '7. 禁止修改目标项目代码。',
    '',
    '## Diagnostics',
    ...diagnostics.map((line) => `- ${line}`),
    '',
    '## Runtime context',
    `- Project: ${project.projectDir}`,
    `- Claude hooks dir: ${toPosixPath(CLAUDE_HOOKS_DIR)}`,
    `- Claude settings: ${toPosixPath(CLAUDE_SETTINGS_FILE)}`,
    `- Claude settings local: ${toPosixPath(CLAUDE_SETTINGS_LOCAL_FILE)}`,
    '',
    'Stop after hooks are installed and verified.',
    '',
  ].join('\n');

  const scriptPath = path.join(project.stateDir, 'safe-setup-launch.ps1');
  return launchClaudeWindow(project, {
    title: `AutoFish Safety Hooks Setup - ${project.name}`,
    prompt,
    scriptPath,
    missingClaudeHint: 'Install Claude Code first, then rerun AutoFish.',
    exitHint: 'Safety setup session ended. Restart Claude Code / AutoFish if hooks changed.',
  });
}

function printSafeSetupLaunchResult(launched, report, project) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_OK = unicode ? '✓' : '[OK]';
  const ICON_FAIL = unicode ? '✗' : '[XX]';
  const ICON_WARN = unicode ? '⚠' : '[!!]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  console.log('');
  console.log(box.header('Safety hooks required', W));
  console.log(boxLine(palette.warn(ICON_WARN + ' Project: ' + project.projectDir)));

  if (report.missingRequired.length > 0) {
    console.log(boxLine(palette.warn(ICON_WARN + ' Required: ' + report.missingRequired.join(', '))));
  }
  if (report.missingOptional.length > 0) {
    console.log(boxLine(palette.warn(ICON_WARN + ' Optional: ' + report.missingOptional.join(', '))));
  }

  console.log(box.sep(W));

  if (launched) {
    console.log(boxLine(palette.info(ICON_OK + ' Setup window opened.')));
    console.log(boxLine(palette.dim('Complete install + doctor, then restart.')));
  } else {
    console.log(boxLine(palette.error(ICON_FAIL + ' Failed to open setup window.')));
    console.log(box.sep(W));
    console.log(boxLine(palette.info('install: npx cc-safe-setup'), 1));
    console.log(boxLine(palette.info('verify:  npx cc-safe-setup --doctor'), 1));
    console.log(boxLine(palette.info('after:   restart Claude Code / AutoFish'), 1));
  }

  console.log(box.footer(W));
  console.log('');
}

function maybeOpenMonitorWindow(project) {
  const projectConfig = readJson(project.configFile, {});
  const showWindow = Boolean(projectConfig.display && projectConfig.display.show_cc_window);
  if (!showWindow) {
    return false;
  }

  const logFile = toPosixPath(path.join(project.runtimeDir, 'auto-log.txt'));
  const command = `Write-Host 'AutoFish CC Monitor' -ForegroundColor Cyan; Write-Host 'Close this window to stop monitoring (does not affect automation)' -ForegroundColor DarkYellow; Write-Host ''; if (-not (Test-Path '${psSingleQuote(logFile)}')) { New-Item -ItemType File -Path '${psSingleQuote(logFile)}' | Out-Null }; Get-Content '${psSingleQuote(logFile)}' -Wait -Tail 10`;

  const result = spawnSync('cmd.exe', ['/c', 'start', '', 'powershell.exe', '-NoExit', '-Command', command], {
    cwd: project.projectDir,
    env: process.env,
    windowsHide: false,
  });

  return result.status === 0 && !result.error;
}

function openBootstrapWindow(project, projectConfig, mode, reason) {
  const bootstrapSeed = fs.readFileSync(path.join(ROOT, 'bootstrap-seed.md'), 'utf8');
  const prompt = `${bootstrapSeed}\n## AutoFish runtime context\n\n- AUTOFISH_ROOT: ${project.root}\n- AUTOFISH_PROJECT_ID: ${project.id}\n- AUTOFISH_PROJECT_DIR: ${project.projectDir}\n- AUTOFISH_STATE_DIR: ${project.stateDir}\n- AUTOFISH_RUNTIME_DIR: ${project.runtimeDir}\n- AUTOFISH_PROJECT_DOC: ${project.projectDoc}\n- AUTOFISH_PROJECT_CONFIG: ${project.configFile}\n- AUTOFISH_BOOTSTRAP_MODE: ${mode}\n- AUTOFISH_BOOTSTRAP_STATUS: ${projectConfig.bootstrap.status}\n- BOOTSTRAP_REASON: ${reason}\n\n## Required first actions\n\n1. Read: ${toPosixPath(path.join(ROOT, 'PROJECT_SPEC.md'))}\n2. Read target project README / build config / test config / key entry files\n3. Phase 1 stays in normal conversation: facts only, no plan mode, no file writes.\n4. Phases 2-4 must run through plan mode: enter in phase 2, stay there through phase 4 draft review, then exit before waiting for explicit \"确认生成 project.md\".\n5. Do not write ${project.projectDoc} before phase 4 explicit confirmation.\n6. Do not write ${project.configFile} before phase 5 config decision.\n7. After bootstrap is complete, stop. Do not modify business code.\n`;

  const scriptPath = path.join(project.stateDir, 'bootstrap-launch.ps1');
  return launchClaudeWindow(project, {
    title: `AutoFish Bootstrap - ${project.name}`,
    prompt,
    scriptPath,
    env: {
      AUTOFISH_PROJECT_CONFIG: project.configFile,
      AUTOFISH_PROJECT_DOC: project.projectDoc,
      AUTOFISH_BOOTSTRAP_MODE: mode,
      AUTOFISH_BOOTSTRAP_STATUS: projectConfig.bootstrap.status,
    },
    waitForExit: true,
    missingClaudeHint: 'Close this window after fixing PATH, then rerun AutoFish.',
    exitHint: 'Bootstrap session ended. AutoFish will now check if bootstrap is complete.',
  });
}

function openWntdWindow(project, reason) {
  const wntdFile = toPosixPath(path.join(project.runtimeDir, 'WhatNeedToDo.md'));
  const blockedFile = toPosixPath(path.join(project.runtimeDir, 'task-blocked.txt'));
  const doneFile = toPosixPath(path.join(project.runtimeDir, 'task-done.txt'));
  const logFile = toPosixPath(path.join(project.runtimeDir, 'auto-log.txt'));
  const wntdSeed = fs.readFileSync(path.join(ROOT, 'wntd-seed.md'), 'utf8');
  const prompt = `${wntdSeed}\n## AutoFish runtime context\n\n- AUTOFISH_ROOT: ${project.root}\n- AUTOFISH_PROJECT_ID: ${project.id}\n- AUTOFISH_PROJECT_DIR: ${project.projectDir}\n- AUTOFISH_STATE_DIR: ${project.stateDir}\n- AUTOFISH_RUNTIME_DIR: ${project.runtimeDir}\n- AUTOFISH_PROJECT_DOC: ${project.projectDoc}\n- AUTOFISH_PROJECT_CONFIG: ${project.configFile}\n- AUTOFISH_WNTD_FILE: ${wntdFile}\n- AUTOFISH_BLOCKED_FILE: ${blockedFile}\n- AUTOFISH_DONE_FILE: ${doneFile}\n- AUTOFISH_LOG_FILE: ${logFile}\n- WNTD_REASON: ${reason}\n\n## Required first actions\n\n1. Read ${wntdFile} if it exists.
2. Read ${project.projectDoc} and ${project.configFile}.
3. Enter plan mode before asking blocked-resolution questions.
4. Before leaving plan mode, explicitly ask whether to continue automation and whether to change runtime config (max_rounds, max_turns_per_round, max_budget_per_round_usd, runtime.max_duration_minutes, runtime.stop_at).
5. After ExitPlanMode, show draft write-back grouped by file before any edit.
6. Include exact project.md additions for any confirmed long-term constraints, decisions, or prerequisites that future AutoFish rounds need.
7. Do not write any file until user explicitly confirms write-back.
8. If user confirms those decisions, write them back into ${project.configFile} under wntd and runtime fields as needed.
9. Stop after WNTD write-back or after confirming remaining blocked items.\n`;

  const scriptPath = path.join(project.stateDir, 'wntd-launch.ps1');
  return launchClaudeWindow(project, {
    title: `AutoFish WNTD - ${project.name}`,
    prompt,
    scriptPath,
    env: {
      AUTOFISH_PROJECT_CONFIG: project.configFile,
      AUTOFISH_PROJECT_DOC: project.projectDoc,
      AUTOFISH_WNTD_FILE: wntdFile,
      AUTOFISH_BLOCKED_FILE: blockedFile,
      AUTOFISH_DONE_FILE: doneFile,
      AUTOFISH_LOG_FILE: logFile,
      AUTOFISH_WNTD_REASON: reason,
    },
    missingClaudeHint: 'Close this window after fixing PATH, then rerun AutoFish.',
    exitHint: 'WNTD session ended. Close this window to let AutoFish re-check blocked state.',
    waitForExit: true,
  });
}

function printWntdLaunchResult(project, options) {
  const {
    reason,
    launched = true,
    phase = 'result',
    nextStatus = null,
    decision = 'continue',
  } = options;

  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_OK = unicode ? '✓' : '[OK]';
  const ICON_FAIL = unicode ? '✗' : '[XX]';
  const ICON_WARN = unicode ? '⚠' : '[!!]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  console.log('');
  console.log(box.header('WNTD review required', W));
  console.log(boxLine(palette.warn(ICON_WARN + ' Reason: ' + reason)));
  console.log(boxLine(palette.dim('Project:   ' + project.projectDir)));
  console.log(boxLine(palette.dim('WNTD file: ' + toPosixPath(path.join(project.runtimeDir, 'WhatNeedToDo.md')))));
  console.log(boxLine(palette.dim('Blocked:   ' + toPosixPath(path.join(project.runtimeDir, 'task-blocked.txt')))));
  if (nextStatus) {
    console.log(boxLine(palette.accent('Next status: ' + nextStatus)));
  }

  console.log(box.sep(W));

  if (phase === 'waiting') {
    console.log(boxLine(palette.info(ICON_OK + ' Opened Claude WNTD window.')));
    console.log(boxLine(palette.dim('AutoFish will wait until that window closes, then re-check runtime state.')));
  } else if (!launched) {
    console.log(boxLine(palette.error(ICON_FAIL + ' Failed to open Claude WNTD window.')));
    console.log(box.sep(W));
    console.log(boxLine(palette.info('WNTD script: ' + toPosixPath(path.join(project.stateDir, 'wntd-launch.ps1'))), 1));
    console.log(boxLine(palette.dim('Run that script manually or fix terminal/permissions, then rerun AutoFish.'), 1));
  } else if (decision === 'pause') {
    console.log(boxLine(palette.warn(ICON_WARN + ' WNTD resolved blocked items but user chose to pause automation.')));
    console.log(boxLine(palette.dim('AutoFish will stop here. Rerun AutoFish later to resume with current config.')));
  } else if (nextStatus === 'blocked') {
    console.log(boxLine(palette.warn(ICON_WARN + ' Blocked items still remain after WNTD session.')));
    console.log(boxLine(palette.dim('Review WhatNeedToDo.md / task-blocked.txt, then rerun AutoFish after more input.')));
  } else {
    console.log(boxLine(palette.info(ICON_OK + ' WNTD session cleared blocked state.')));
    console.log(boxLine(palette.dim('AutoFish will continue with normal run-loop.')));
  }

  console.log(box.footer(W));
  console.log('');
}

async function runProjectWithWntd(project, projectConfig, initialWntdReason = null) {
  let pendingWntdReason = initialWntdReason;
  let monitorWindowChecked = false;

  while (true) {
    if (pendingWntdReason) {
      const requestedAt = new Date().toISOString();
      projectConfig = setWntdState(project, {
        status: 'pending',
        last_reason: pendingWntdReason,
        last_requested_at: requestedAt,
      }, projectConfig);
      printWntdLaunchResult(project, {
        reason: pendingWntdReason,
        phase: 'waiting',
      });

      const configBeforeWntd = runtimeControlSnapshot(projectConfig);
      projectConfig = setWntdState(project, {
        status: 'in_progress',
        last_reason: pendingWntdReason,
        last_started_at: new Date().toISOString(),
      }, projectConfig);

      const launched = openWntdWindow(project, pendingWntdReason);
      if (!launched) {
        const blockedAt = new Date().toISOString();
        projectConfig = setWntdState(project, {
          status: 'blocked',
          last_reason: pendingWntdReason,
          continue_after_resolved: null,
          continue_decided_at: null,
          runtime_config_change_requested: null,
          runtime_config_decided_at: null,
          last_finished_at: blockedAt,
          last_blocked_at: blockedAt,
        }, projectConfig);
        printWntdLaunchResult(project, {
          reason: pendingWntdReason,
          launched: false,
        });
        return;
      }

      projectConfig = ensureProjectState(project);
      let nextStatus = projectStatus(project, projectConfig);
      const decision = decidePostWntdAction(project, projectConfig, nextStatus);
      if (decision.shouldCleanup) {
        cleanupResolvedWntdArtifacts(project);
        projectConfig = ensureProjectState(project);
        nextStatus = projectStatus(project, projectConfig);
      }
      const runtimeConfigChanged = JSON.stringify(configBeforeWntd) !== JSON.stringify(runtimeControlSnapshot(projectConfig));
      const decidedAt = new Date().toISOString();
      const currentWntd = normalizeWntdState(projectConfig.wntd);
      const runtimeConfigDecision = currentWntd.runtime_config_change_requested === null
        ? (runtimeConfigChanged ? true : null)
        : currentWntd.runtime_config_change_requested;
      const statePatch = {
        last_reason: pendingWntdReason,
        continue_after_resolved: currentWntd.continue_after_resolved,
        continue_decided_at: currentWntd.continue_after_resolved === null
          ? null
          : (currentWntd.continue_decided_at || decidedAt),
        runtime_config_change_requested: runtimeConfigDecision,
        runtime_config_decided_at: runtimeConfigDecision === null
          ? null
          : (currentWntd.runtime_config_decided_at || decidedAt),
        runtime_config_updated_at: currentWntd.runtime_config_updated_at,
        last_finished_at: decidedAt,
      };
      if (runtimeConfigChanged && !statePatch.runtime_config_updated_at) {
        statePatch.runtime_config_updated_at = decidedAt;
      }
      projectConfig = setWntdState(project, (decision.action === 'stop' || decision.action === 'pause')
        ? {
            ...statePatch,
            status: 'blocked',
            last_blocked_at: decidedAt,
          }
        : {
            ...statePatch,
            status: 'resolved',
            last_resolved_at: decidedAt,
          }, projectConfig);
      printWntdLaunchResult(project, {
        reason: pendingWntdReason,
        nextStatus,
        decision: decision.action,
      });
      if (decision.action === 'stop' || decision.action === 'pause') {
        return;
      }

      pendingWntdReason = null;
    }

    if (!monitorWindowChecked) {
      maybeOpenMonitorWindow(project);
      monitorWindowChecked = true;
    }

    await runLoop(project, projectConfig);
    projectConfig = ensureProjectState(project);

    if (!fs.existsSync(project.projectDoc)) {
      projectConfig = setBootstrapState(project, {
        status: 'not_started',
        phase: 0,
        project_doc_confirmed: false,
        config_decision: 'pending',
        confirmed_at: null,
        confirmed_by: null,
        project_doc_source: 'none',
      }, projectConfig);
      console.log(`\n${box.header('All tasks completed', W)}`);
      console.log(colorize('dim', 'project.md archived to History/. Starting new bootstrap...\n'));
      return { archived: true };
    }

    pendingWntdReason = blockedInteractionReason(project);
    if (!pendingWntdReason) {
      return;
    }
  }
}

async function runLoop(project, projectConfig) {
  const stopFile = path.join(project.runtimeDir, 'stop-requested');
  try { fs.unlinkSync(stopFile); } catch {}

  const env = {
    ...process.env,
    AUTOFISH_ROOT: project.root,
    AUTOFISH_PROJECT_ID: project.id,
    AUTOFISH_PROJECT_DIR: project.projectDir,
    AUTOFISH_STATE_DIR: project.stateDir,
    AUTOFISH_PROJECT_CONFIG: project.configFile,
    AUTOFISH_PROJECT_DOC: project.projectDoc,
    AUTOFISH_RUNTIME_DIR: project.runtimeDir,
    AUTOFISH_BOOTSTRAP_STATUS: projectConfig.bootstrap.status,
  };

  const child = spawn(BASH, [toPosixPath(path.join(ROOT, 'run-loop.sh'))], {
    cwd: ROOT,
    env,
    stdio: 'inherit',
    windowsHide: false,
  });

  let stopRequested = false;
  const requestStop = (signal) => {
    if (!stopRequested) {
      stopRequested = true;
      try {
        fs.writeFileSync(stopFile, `${new Date().toISOString()} ${signal}\n`, 'utf8');
      } catch {}
      console.log(`\n${colorize('warn', `[STOP] ${signal} received. Requesting graceful stop...`)}`);
      try { child.kill('SIGINT'); } catch {}
      return;
    }

    console.log(colorize('error', '[STOP] Second interrupt received. Forcing termination...'));
    forceKillProcessTree(child.pid);
  };

  const onSigInt = () => requestStop('SIGINT');
  const onSigTerm = () => requestStop('SIGTERM');
  process.on('SIGINT', onSigInt);
  process.on('SIGTERM', onSigTerm);

  const exitCode = await new Promise((resolve) => {
    child.on('exit', (code, signal) => {
      process.off('SIGINT', onSigInt);
      process.off('SIGTERM', onSigTerm);
      if (signal) {
        resolve(1);
      } else {
        resolve(code ?? 0);
      }
    });
  });

  process.exitCode = exitCode;
}

function forceKillProcessTree(pid) {
  if (!pid) {
    return;
  }

  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    return;
  }

  try {
    process.kill(pid, 'SIGTERM');
  } catch {}
}

function projectStatus(project, configOverride = null) {
  const normalized = normalizeProjectRecord(project);
  if (!fs.existsSync(normalized.projectDir)) {
    return 'missing';
  }

  const doneFile = path.join(normalized.runtimeDir, 'task-done.txt');
  if (fs.existsSync(doneFile) && fs.readFileSync(doneFile, 'utf8').includes('ALL_COMPLETE')) {
    return 'complete';
  }

  if (hasBlockedInteraction(normalized)) {
    return 'blocked';
  }

  if (!fs.existsSync(normalized.projectDoc)) {
    return 'needs-bootstrap';
  }

  const projectConfig = configOverride || readJson(normalized.configFile, {});
  const bootstrap = normalizeBootstrapState(projectConfig.bootstrap, true);
  if (bootstrap.status === 'in_progress') {
    return 'bootstrap-in-progress';
  }

  if (!isBootstrapConfirmed({ bootstrap })) {
    return 'needs-confirmation';
  }

  return 'ready';
}

function isBootstrapConfirmed(projectConfig) {
  const bootstrap = normalizeBootstrapState(projectConfig.bootstrap, true);
  return bootstrap.status === 'confirmed'
    && bootstrap.project_doc_confirmed === true
    && bootstrap.config_decision !== 'pending';
}

function bootstrapReason(projectConfig) {
  const bootstrap = normalizeBootstrapState(projectConfig.bootstrap, true);
  if (!bootstrap.project_doc_confirmed) {
    return 'project.md exists but is not confirmed for run-loop';
  }
  if (bootstrap.config_decision === 'pending') {
    return 'project.md confirmed but config decision is still pending';
  }
  return `bootstrap status is ${bootstrap.status}`;
}

function printProjectSummary(project, projectConfig, status) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const W = 80;

  const statusColor = (status === 'ready' || status === 'complete') ? palette.info :
                      status === 'missing' ? palette.error : palette.warn;

  console.log('');
  console.log(box.header('Selected project', W));
  console.log(box.kv('Name', project.name, W));
  console.log(box.kv('Status', statusColor(status), W));
  console.log(box.kv('Project', palette.dim(project.projectDir), W));
  console.log(box.kv('State dir', palette.dim(project.stateDir), W));
  console.log(box.kv('Project doc', palette.dim(project.projectDoc), W));
  console.log(box.kv('Config', palette.dim(project.configFile), W));
  console.log(box.kv('Bootstrap', palette.dim(`status=${projectConfig.bootstrap.status}, phase=${projectConfig.bootstrap.phase}, confirmed=${projectConfig.bootstrap.project_doc_confirmed}, config=${projectConfig.bootstrap.config_decision}`), W));
  console.log(box.footer(W));
  console.log('');
}

function printBootstrapLaunchResult(project, projectConfig, launched, reason) {
  const box = createBox(process.env, process.stdout);
  const palette = createPalette(process.env);
  const unicode = supportsUnicode(process.env, process.stdout);
  const C = unicode ? UNICODE_CHARS : ASCII_CHARS;
  const W = 80;
  const ICON_OK = unicode ? '✓' : '[OK]';
  const ICON_FAIL = unicode ? '✗' : '[XX]';
  const ICON_WARN = unicode ? '⚠' : '[!!]';

  function boxLine(inner, indent = 0) {
    const prefix = indent > 0 ? '  '.repeat(indent) : '';
    const visible = stripAnsi(prefix + inner).length;
    const pad = Math.max(0, W - 4 - visible);
    return C.vt + ' ' + prefix + inner + ' '.repeat(pad) + ' ' + C.vt;
  }

  console.log('');
  console.log(box.header('Bootstrap required', W));
  console.log(boxLine(palette.warn(ICON_WARN + ' Reason: ' + reason)));
  console.log(boxLine(palette.dim('Project:     ' + project.projectDir)));
  console.log(boxLine(palette.dim('Project doc: ' + project.projectDoc)));
  console.log(boxLine(palette.dim('Config:      ' + project.configFile)));
  console.log(boxLine(palette.accent('Bootstrap:   status=' + projectConfig.bootstrap.status + ', phase=' + projectConfig.bootstrap.phase)));

  console.log(box.sep(W));

  if (launched) {
    console.log(boxLine(palette.info(ICON_OK + ' Opened Claude bootstrap window.')));
    console.log(boxLine(palette.dim('Complete the five-stage Q&A in that window.')));
  } else {
    console.log(boxLine(palette.error(ICON_FAIL + ' Failed to open Claude bootstrap window.')));
    console.log(box.sep(W));
    console.log(boxLine(palette.info('Run: ' + toPosixPath(path.join(project.stateDir, 'bootstrap-launch.ps1'))), 1));
    console.log(boxLine(palette.dim('Or fix terminal/permissions, then rerun AutoFish.'), 1));
  }

  console.log(box.footer(W));
  console.log('');
}

function buildProjectRecord(projectDir) {
  const normalizedProjectDir = normalizePath(projectDir);
  const hash = crypto.createHash('sha1').update(normalizedProjectDir.toLowerCase()).digest('hex').slice(0, 8);
  const baseName = sanitizeName(path.basename(normalizedProjectDir) || 'project');
  const id = `${baseName}-${hash}`;
  const stateDir = normalizePath(path.join(PROJECTS_DIR, id));
  const runtimeDir = normalizePath(path.join(stateDir, 'runtime'));

  return {
    id,
    name: path.basename(normalizedProjectDir) || id,
    root: toPosixPath(ROOT),
    projectDir: toPosixPath(normalizedProjectDir),
    stateDir: toPosixPath(stateDir),
    configFile: toPosixPath(path.join(stateDir, 'config.json')),
    projectDoc: toPosixPath(path.join(stateDir, 'project.md')),
    runtimeDir: toPosixPath(runtimeDir),
    createdAt: new Date().toISOString(),
    lastSelectedAt: new Date().toISOString(),
  };
}

function normalizeProjectRecord(project) {
  return {
    ...project,
    root: toPosixPath(project.root || ROOT),
    projectDir: toPosixPath(project.projectDir),
    stateDir: toPosixPath(project.stateDir),
    configFile: toPosixPath(project.configFile),
    projectDoc: toPosixPath(project.projectDoc),
    runtimeDir: toPosixPath(project.runtimeDir),
  };
}

function loadRegistry() {
  const registry = readJson(REGISTRY_FILE, {
    version: 1,
    lastProjectId: null,
    projects: [],
  });

  if (!Array.isArray(registry.projects)) {
    registry.projects = [];
  }

  registry.projects = registry.projects.map(normalizeProjectRecord);
  return registry;
}

function saveRegistry(registry) {
  writeJson(REGISTRY_FILE, registry);
}

function upsertProject(registry, project) {
  const index = registry.projects.findIndex((item) => item.id === project.id || samePath(item.projectDir, project.projectDir));
  if (index >= 0) {
    registry.projects[index] = normalizeProjectRecord({ ...registry.projects[index], ...project });
  } else {
    registry.projects.push(normalizeProjectRecord(project));
  }
}

function mergeDeep(base, override) {
  if (!isPlainObject(base)) {
    return cloneValue(override);
  }
  const result = cloneValue(base);
  if (!isPlainObject(override)) {
    return result;
  }

  for (const [key, value] of Object.entries(override)) {
    if (isPlainObject(value) && isPlainObject(result[key])) {
      result[key] = mergeDeep(result[key], value);
    } else {
      result[key] = cloneValue(value);
    }
  }

  return result;
}

function cloneValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => cloneValue(item));
  }
  if (isPlainObject(value)) {
    const out = {};
    for (const [key, item] of Object.entries(value)) {
      out[key] = cloneValue(item);
    }
    return out;
  }
  return value;
}

function isPlainObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJson(filePath, value) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function normalizeInputPath(inputPath) {
  const stripped = inputPath.replace(/^"|"$/g, '').trim();
  if (!stripped) {
    return null;
  }

  const resolved = normalizePath(stripped);
  if (!fs.existsSync(resolved)) {
    console.log(`\n${colorize('warn', `[PATH] Path not found -> ${resolved}`)}\n`);
    return null;
  }

  const stat = fs.statSync(resolved);
  return stat.isDirectory() ? resolved : path.dirname(resolved);
}

function normalizePath(targetPath) {
  return path.resolve(targetPath);
}

function toPosixPath(targetPath) {
  return normalizePath(targetPath).replace(/\\/g, '/');
}

function samePath(left, right) {
  return normalizePath(left).toLowerCase() === normalizePath(right).toLowerCase();
}

function sanitizeName(name) {
  return name.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '') || 'project';
}

function padRight(value, length) {
  return String(value).padEnd(length, ' ');
}

function psSingleQuote(value) {
  return String(value).replace(/'/g, "''");
}

function commandExists(command) {
  const checker = process.platform === 'win32' ? 'where' : 'command';
  const args = process.platform === 'win32' ? [command] : ['-v', command];
  const result = spawnSync(checker, args, { encoding: 'utf8', windowsHide: true, shell: process.platform !== 'win32' });
  return result.status === 0;
}

function colorize(kind, text) {
  const painter = COLOR[kind] || ((value) => value);
  return painter(String(text));
}

function ask(question) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

async function confirm(question, defaultYes) {
  const answer = (await ask(question)).trim().toLowerCase();
  if (!answer) {
    return defaultYes;
  }
  return answer === 'y' || answer === 'yes';
}
