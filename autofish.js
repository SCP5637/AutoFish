#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const readline = require('readline');
const { spawnSync } = require('child_process');

const ROOT = normalizePath(process.env.AUTOFISH_ROOT || __dirname);
const ROOT_CONFIG_FILE = path.join(ROOT, 'config.json');
const STATE_DIR = path.join(ROOT, 'state');
const PROJECTS_DIR = path.join(STATE_DIR, 'projects');
const REGISTRY_FILE = path.join(STATE_DIR, 'configList.json');
const BASH = process.env.AUTOFISH_BASH || 'bash';

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

main().catch((error) => {
  console.error(`[FATAL] ${error.message}`);
  process.exit(1);
});

async function main() {
  ensureDir(STATE_DIR);
  ensureDir(PROJECTS_DIR);

  const registry = loadRegistry();
  const selection = await selectProject(registry);

  if (!selection) {
    console.log('\nAutoFish exited.');
    return;
  }

  if (!fs.existsSync(selection.projectDir)) {
    console.log('\n=== Project missing ===');
    console.log(`Path: ${selection.projectDir}`);
    console.log('Re-register project with New Project.');
    return;
  }

  let projectConfig = ensureProjectState(selection);
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

  if (!fs.existsSync(selection.projectDoc)) {
    const reason = 'project.md missing';
    projectConfig = markBootstrapLaunch(selection, projectConfig, 'new');
    const launched = openBootstrapWindow(selection, projectConfig, 'new', reason);
    printBootstrapLaunchResult(selection, projectConfig, launched, reason);
    return;
  }

  if (!isBootstrapConfirmed(projectConfig)) {
    const reason = bootstrapReason(projectConfig);
    projectConfig = markBootstrapLaunch(selection, projectConfig, 'review');
    const launched = openBootstrapWindow(selection, projectConfig, 'review', reason);
    printBootstrapLaunchResult(selection, projectConfig, launched, reason);
    return;
  }

  ensureRuntimeFiles(selection);
  maybeOpenMonitorWindow(selection);
  runLoop(selection, projectConfig);
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
        console.log('\n[INPUT] No last project.\n');
        continue;
      }

      const last = registry.projects.find((project) => project.id === registry.lastProjectId);
      if (!last) {
        console.log('\n[INPUT] Last project missing from registry.\n');
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

    console.log('\n[INPUT] Invalid selection.\n');
  }
}

function printMenu(registry) {
  console.log('');
  console.log('================ AutoFish ================');
  console.log('');
  console.log('Root:');
  console.log(`  ${toPosixPath(ROOT)}`);
  console.log('');
  console.log('Last:');

  if (registry.lastProjectId) {
    const last = registry.projects.find((project) => project.id === registry.lastProjectId);
    if (last) {
      console.log(`  0. ${padRight(last.name, 28)} [${projectStatus(last)}]`);
      console.log(`     ${last.projectDir}`);
    } else {
      console.log('  0. none');
    }
  } else {
    console.log('  0. none');
  }

  console.log('');
  console.log('Projects:');
  if (registry.projects.length === 0) {
    console.log('  (none)');
  } else {
    registry.projects.forEach((project, index) => {
      console.log(`  ${String(index + 1).padEnd(2)} ${padRight(project.name, 28)} [${projectStatus(project)}]`);
      console.log(`     ${project.projectDir}`);
    });
  }

  console.log('');
  console.log('Actions:');
  console.log(`  ${registry.projects.length + 1}. New Project`);
  console.log('  X. Exit');
  console.log('');
  console.log('==========================================');
}

async function createNewProjectInteractive(registry) {
  while (true) {
    console.log('\n=== New Project ===\n');
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
      console.log(`\nUsing existing project -> ${existing.name}\n`);
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
  const normalizedInput = normalizeInputPath(inputPath);
  if (!normalizedInput) {
    console.log('\n[PATH] Path invalid.\n');
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
  console.log('=== Detected projects ===');
  console.log('Current path is not a git project. Found multiple nearby projects:');
  candidates.forEach((candidate, index) => {
    console.log(`  ${index + 1}. ${candidate}`);
  });
  console.log('');
  console.log('Actions:');
  console.log('  C. Use current path anyway');
  console.log('  R. Re-enter path');
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

    console.log('\n[INPUT] Invalid selection.\n');
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
  return normalized;
}

function normalizeBootstrapState(currentBootstrap, hasProjectDoc) {
  const bootstrap = { ...DEFAULT_BOOTSTRAP, ...(currentBootstrap || {}) };

  if (!currentBootstrap) {
    if (hasProjectDoc) {
      bootstrap.status = 'awaiting_project_confirmation';
      bootstrap.phase = 4;
      bootstrap.project_doc_source = 'manual_existing';
    }
  }

  return bootstrap;
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
  const prompt = `${bootstrapSeed}\n## AutoFish runtime context\n\n- AUTOFISH_ROOT: ${project.root}\n- AUTOFISH_PROJECT_ID: ${project.id}\n- AUTOFISH_PROJECT_DIR: ${project.projectDir}\n- AUTOFISH_STATE_DIR: ${project.stateDir}\n- AUTOFISH_RUNTIME_DIR: ${project.runtimeDir}\n- AUTOFISH_PROJECT_DOC: ${project.projectDoc}\n- AUTOFISH_PROJECT_CONFIG: ${project.configFile}\n- AUTOFISH_BOOTSTRAP_MODE: ${mode}\n- AUTOFISH_BOOTSTRAP_STATUS: ${projectConfig.bootstrap.status}\n- BOOTSTRAP_REASON: ${reason}\n\n## Required first actions\n\n1. Read: ${toPosixPath(path.join(ROOT, 'PROJECT_SPEC.md'))}\n2. Read target project README / build config / test config / key entry files\n3. Follow the five bootstrap phases strictly. Do not skip phases.\n4. Do not write ${project.projectDoc} before phase 4 explicit confirmation.\n5. Do not write ${project.configFile} before phase 5 config decision.\n6. After bootstrap is complete, stop. Do not modify business code.\n`;

  const scriptPath = path.join(project.stateDir, 'bootstrap-launch.ps1');
  const script = `$ErrorActionPreference = 'Stop'\n$Host.UI.RawUI.WindowTitle = 'AutoFish Bootstrap - ${psSingleQuote(project.name)}'\n$bootstrapPrompt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('${Buffer.from(prompt, 'utf8').toString('base64')}'))\n$env:AUTOFISH_PROJECT_CONFIG = '${psSingleQuote(project.configFile)}'\n$env:AUTOFISH_PROJECT_DOC = '${psSingleQuote(project.projectDoc)}'\n$env:AUTOFISH_BOOTSTRAP_MODE = '${psSingleQuote(mode)}'\n$env:AUTOFISH_BOOTSTRAP_STATUS = '${psSingleQuote(projectConfig.bootstrap.status)}'\nSet-Location -LiteralPath '${psSingleQuote(project.projectDir)}'\nif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {\n  Write-Host '[ERROR] claude not found in PATH.' -ForegroundColor Red\n  Write-Host 'Close this window after fixing PATH, then rerun AutoFish.' -ForegroundColor DarkYellow\n  return\n}\n& claude -n 'AutoFish Bootstrap - ${psSingleQuote(project.name)}' $bootstrapPrompt\nWrite-Host ''\nWrite-Host 'Bootstrap session ended. Return to AutoFish when project.md/config confirmation is done.' -ForegroundColor DarkYellow\n`;
  fs.writeFileSync(scriptPath, script, 'utf8');

  const result = spawnSync('cmd.exe', ['/c', 'start', '', 'powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', scriptPath], {
    cwd: project.projectDir,
    env: process.env,
    windowsHide: false,
  });

  return result.status === 0 && !result.error;
}

function runLoop(project, projectConfig) {
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

  const result = spawnSync(BASH, [toPosixPath(path.join(ROOT, 'run-loop.sh'))], {
    cwd: ROOT,
    env,
    stdio: 'inherit',
    windowsHide: false,
  });

  process.exit(result.status || 0);
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

  const blockedFile = path.join(normalized.runtimeDir, 'task-blocked.txt');
  if (fs.existsSync(blockedFile) && fs.readFileSync(blockedFile, 'utf8').includes('ALL_BLOCKED')) {
    return 'blocked';
  }

  if (fs.existsSync(path.join(normalized.runtimeDir, 'WhatNeedToDo.md'))) {
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
  const bootstrap = projectConfig.bootstrap;
  console.log('');
  console.log('=== Selected project ===');
  console.log(`Name:        ${project.name}`);
  console.log(`Status:      ${status}`);
  console.log(`Project:     ${project.projectDir}`);
  console.log(`State dir:   ${project.stateDir}`);
  console.log(`Project doc: ${project.projectDoc}`);
  console.log(`Config:      ${project.configFile}`);
  console.log(`Bootstrap:   status=${bootstrap.status}, phase=${bootstrap.phase}, confirmed=${bootstrap.project_doc_confirmed}, config=${bootstrap.config_decision}`);
  console.log('');
}

function printBootstrapLaunchResult(project, projectConfig, launched, reason) {
  console.log('=== Bootstrap required ===');
  console.log(`Reason:      ${reason}`);
  console.log(`Project:     ${project.projectDir}`);
  console.log(`Project doc: ${project.projectDoc}`);
  console.log(`Config:      ${project.configFile}`);
  console.log(`Bootstrap:   status=${projectConfig.bootstrap.status}, phase=${projectConfig.bootstrap.phase}`);
  console.log('');

  if (launched) {
    console.log('Opened Claude bootstrap window.');
    console.log('Finish the five-stage Q&A there.');
    console.log('After final confirmation, rerun AutoFish from this terminal.');
  } else {
    console.log('[ERROR] Failed to open Claude bootstrap window.');
    console.log(`Bootstrap script: ${toPosixPath(path.join(project.stateDir, 'bootstrap-launch.ps1'))}`);
    console.log('Run that script manually or fix terminal/permissions, then rerun AutoFish.');
  }

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
    console.log(`\n[PATH] Path not found -> ${resolved}\n`);
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
