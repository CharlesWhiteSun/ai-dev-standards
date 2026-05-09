#!/usr/bin/env node
// 知識庫 v3 CLI — 主題化 + facet + FTS 整合
// 純 Node ESM、無外部相依（FTS 採 Node 22.5+ 內建 node:sqlite，不可用時優雅降級）。
// Commands: rebuild | new-trap | new-decision | health | taxonomy | audit | facets | topics | search | bulk-tag | start-check | finish-check | repair-*

import { readFile, writeFile, readdir, mkdir, unlink } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const KB_ROOT = path.resolve(__dirname, '..');
const TRAPS_DIR = path.join(KB_ROOT, 'traps');
const TOPICS_DIR = path.join(TRAPS_DIR, 'topics');
const TRAPS_INDEX = path.join(TRAPS_DIR, 'index.jsonl');
const TAXONOMY = path.join(TRAPS_DIR, 'topics-taxonomy.yml');
const MODULES_DIR = path.join(KB_ROOT, 'modules');
const AGENT_DIR = path.join(KB_ROOT, 'agent');
const AGENT_GENERATED_DIR = path.join(AGENT_DIR, 'generated');
const AGENT_GUARDS = path.join(AGENT_GENERATED_DIR, 'guards.json');
const AGENT_BY_COMMAND = path.join(AGENT_GENERATED_DIR, 'by-command.json');
const AGENT_BY_TOOL = path.join(AGENT_GENERATED_DIR, 'by-tool.json');
const AGENT_BY_ERROR = path.join(AGENT_GENERATED_DIR, 'by-error.json');
const AGENT_BY_PATH = path.join(AGENT_GENERATED_DIR, 'by-path.json');
const FTS_DB = path.join(TRAPS_DIR, 'fts.db');
const PROJECT_ROOT = path.resolve(KB_ROOT, '..', '..');
const VSCODE_ROOT = path.resolve(KB_ROOT, '..');
const DEFAULT_RUNTIME_DIR = path.join(KB_ROOT, 'runtime');
const REPAIR_RETRY_LIMIT = 2;
const REPAIR_FAILURES_FILE = 'failures.jsonl';
const REPAIR_FALSE_POSITIVES_FILE = 'false-positives.json';
const AGENT_GUARD_FIELDS = ['bad_commands', 'bad_tools', 'bad_paths', 'error_patterns', 'preferred_actions', 'deny_when', 'recover_with'];

// 嘗試載入 node:sqlite（Node 22.5+），不可用時優雅降級
let DatabaseSync = null;
let sqliteUnavailableReason = '';
try {
  ({ DatabaseSync } = await import('node:sqlite'));
} catch (e) {
  sqliteUnavailableReason = e.message;
}
// 抑制 SQLite ExperimentalWarning（Node 22.5–23.x）
process.on('warning', (w) => {
  if (w.name === 'ExperimentalWarning' && /SQLite/i.test(w.message)) return;
  console.warn(w);
});

// =================================================================
//  Frontmatter parser/serializer  — 支援 block 字串列表 + CJK
// =================================================================
const FM_RE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

function parseFrontmatter(text) {
  const m = text.match(FM_RE);
  if (!m) return { data: {}, body: text };
  const data = {};
  const lines = m[1].split(/\r?\n/);
  let i = 0;
  while (i < lines.length) {
    const raw = lines[i];
    if (!raw.trim() || raw.trim().startsWith('#')) { i++; continue; }
    const km = raw.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!km) { i++; continue; }
    const key = km[1];
    const inline = km[2];
    if (inline === '' || inline === undefined) {
      const items = [];
      i++;
      while (i < lines.length) {
        const L = lines[i];
        if (/^[A-Za-z_][\w-]*:/.test(L)) break;
        const dm = L.match(/^\s+-\s+(.*)$/);
        if (dm) { items.push(unquote(dm[1].trim())); i++; continue; }
        if (!L.trim()) { i++; continue; }
        break;
      }
      data[key] = items;
    } else if (inline.startsWith('[') && inline.endsWith(']')) {
      const inner = inline.slice(1, -1).trim();
      data[key] = inner ? splitCsv(inner).map(unquote) : [];
      i++;
    } else if (/^-?\d+$/.test(inline)) {
      data[key] = Number(inline);
      i++;
    } else {
      data[key] = unquote(inline);
      i++;
    }
  }
  return { data, body: text.slice(m[0].length) };
}

function splitCsv(s) {
  const out = []; let cur = ''; let q = null;
  for (const ch of s) {
    if (q) { if (ch === q) { q = null; } else { cur += ch; } continue; }
    if (ch === '"' || ch === "'") { q = ch; continue; }
    if (ch === ',') { out.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

function unquote(s) { return s.replace(/^["']|["']$/g, ''); }

function stringifyFrontmatter(data) {
  const lines = ['---'];
  for (const [k, v] of Object.entries(data)) {
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      if (v.length === 0) { lines.push(`${k}: []`); continue; }
      const allShortSafe = v.every(x => typeof x === 'string' && !x.includes('\n') && x.length < 80 && !/[:#\[\]&*!|>'"%@`,]/.test(x));
      if (allShortSafe) {
        lines.push(`${k}: [${v.map(s => /[\s]/.test(s) ? JSON.stringify(s) : s).join(', ')}]`);
      } else {
        lines.push(`${k}:`);
        for (const item of v) lines.push(`  - ${needsQuote(item) ? JSON.stringify(String(item)) : String(item)}`);
      }
    } else if (typeof v === 'number') {
      lines.push(`${k}: ${v}`);
    } else {
      const s = String(v);
      lines.push(needsQuote(s) ? `${k}: ${JSON.stringify(s)}` : `${k}: ${s}`);
    }
  }
  lines.push('---', '');
  return lines.join('\n');
}

function needsQuote(s) {
  return /^[\s>!|*&%@`]/.test(s) || /[:#\[\]"']/.test(s) || s === '' || /^(true|false|null|yes|no)$/i.test(s) || /^-?\d/.test(s);
}

// =================================================================
//  File helpers
// =================================================================
async function ensureDir(d) { await mkdir(d, { recursive: true }); }
async function readUtf8(p) {
  const buf = await readFile(p);
  if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) return buf.slice(3).toString('utf8');
  return buf.toString('utf8');
}
async function writeUtf8(p, content) {
  await ensureDir(path.dirname(p));
  await writeFile(p, content, { encoding: 'utf8' });
}
async function listMd(dir) {
  if (!existsSync(dir)) return [];
  const e = await readdir(dir, { withFileTypes: true });
  return e.filter(x => x.isFile() && x.name.endsWith('.md')).map(x => path.join(dir, x.name));
}
function pad(n, w = 3) { return String(n).padStart(w, '0'); }

function sha256(text) {
  return createHash('sha256').update(String(text || '')).digest('hex');
}

function normalizeCommand(command) {
  return String(command || '')
    .replace(/(['"])(?:[A-Za-z]:)?[\\/][^'"\s]+\1/g, '$1<path>$1')
    .replace(/(?:[A-Za-z]:)?[\\/][^\s]+/g, '<path>')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizePathValue(value) {
  if (!value) return '';
  const normalized = normalizeFile(value);
  const root = PROJECT_ROOT.replace(/[\\/]+/g, '/').toLowerCase();
  return normalized.toLowerCase().startsWith(root) ? normalized.slice(root.length).replace(/^\//, '') : normalized;
}

function redactSensitive(text) {
  return String(text || '')
    .replace(/([A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|KEY|PWD)[A-Za-z0-9_]*\s*[=:]\s*)[^\s'";]+/gi, '$1<redacted>')
    .replace(/Bearer\s+[A-Za-z0-9._~+\-/]+=*/gi, 'Bearer <redacted>')
    .replace(/sk-[A-Za-z0-9]{12,}/gi, 'sk-<redacted>')
    .replace(/[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{24,}/g, '<jwt-redacted>')
    .slice(0, 400);
}

function hasPlaceholder(value) {
  return /<[^>]+>|\{[^}]+\}|\$\{[^}]+\}|\bTODO\b|模組|檔案|關鍵字/i.test(String(value || ''));
}

function runtimeDir() {
  const env = process.env.KB_RUNTIME_DIR;
  return env ? path.resolve(env) : DEFAULT_RUNTIME_DIR;
}

async function appendJsonl(file, row) {
  await ensureDir(path.dirname(file));
  let prefix = '';
  if (existsSync(file)) {
    const old = readFileSync(file, 'utf8');
    prefix = old && !old.endsWith('\n') ? '\n' : '';
  }
  await writeFile(file, prefix + JSON.stringify(row) + '\n', { encoding: 'utf8', flag: 'a' });
}

function readJsonlIfExists(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line, index) => {
      try { return JSON.parse(line); }
      catch { return { invalid: true, line: index + 1, raw: line }; }
    });
}

function readJsonIfExists(file, fallback) {
  if (!existsSync(file)) return fallback;
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch { return fallback; }
}

function makeFingerprint(opts) {
  const tool = String(opts.tool || 'unknown').toLowerCase();
  const cwd = normalizePathValue(opts.cwd || PROJECT_ROOT) || '.';
  const command = normalizeCommand(opts.command || '');
  const targetPath = normalizePathValue(opts.path || '');
  const exitCode = String(opts.exitCode ?? opts['exit-code'] ?? '');
  const errorSummary = redactSensitive(opts.error || opts.stderr || opts.message || '');
  const errorHash = errorSummary ? sha256(errorSummary).slice(0, 16) : '';
  const intent = String(opts.intent || '').trim();
  const source = [tool, cwd, command, targetPath, exitCode, errorHash, intent].join('|');
  return {
    id: sha256(source).slice(0, 20),
    tool,
    cwd,
    command,
    path: targetPath,
    exit_code: exitCode,
    error_hash: errorHash,
    intent,
  };
}

function groupByFingerprint(records) {
  const map = new Map();
  for (const record of records.filter(x => !x.invalid)) {
    const id = record.fingerprint?.id || record.id;
    if (!id) continue;
    if (!map.has(id)) map.set(id, []);
    map.get(id).push(record);
  }
  return map;
}

function normalizeGuardValue(value) {
  return String(value || '').trim().toLowerCase();
}

function guardMatches(value, pattern) {
  const v = normalizeGuardValue(value);
  const p = normalizeGuardValue(pattern);
  return !!p && (v === p || v.includes(p));
}

function extractListFromBody(body, heading) {
  const lines = String(body || '').split(/\r?\n/);
  const headingRe = new RegExp(`^##\\s+${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'i');
  const start = lines.findIndex(line => headingRe.test(line));
  if (start < 0) return [];
  const section = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) break;
    section.push(lines[i]);
  }
  return section
    .map(line => line.match(/^\s*[-*]\s+(.+?)\s*$/)?.[1])
    .filter(Boolean);
}

// =================================================================
//  Taxonomy loader  — 簡單 YAML 解析
// =================================================================
function loadTaxonomy() {
  if (!existsSync(TAXONOMY)) return { topics: [], slugs: new Set() };
  const text = readFileSync(TAXONOMY, 'utf8');
  const topics = [];
  let cur = null;
  for (const raw of text.split(/\r?\n/)) {
    if (raw.startsWith('#') || !raw.trim()) continue;
    const startM = raw.match(/^\s*-\s*slug:\s*(.+?)\s*$/);
    if (startM) { if (cur) topics.push(cur); cur = { slug: startM[1].trim() }; continue; }
    if (!cur) continue;
    const kv = raw.match(/^\s+(\w+):\s*(.+?)\s*$/);
    if (!kv) continue;
    const [, k, v] = kv;
    if (k === 'keywords') {
      cur.keywords = v.startsWith('[') ? splitCsv(v.slice(1, -1)).map(unquote) : [];
    } else {
      cur[k] = unquote(v);
    }
  }
  if (cur) topics.push(cur);
  return { topics, slugs: new Set(topics.map(t => t.slug)) };
}

// =================================================================
//  Trap loader
// =================================================================
async function loadAllTraps() {
  const files = (await listMd(TRAPS_DIR)).filter(f => /trap-\d+\.md$/.test(path.basename(f)));
  const traps = [];
  for (const f of files) {
    const text = await readUtf8(f);
    const { data, body } = parseFrontmatter(text);
    traps.push({ file: path.basename(f), body, ...data });
  }
  return traps.sort((a, b) => (a.id || 0) - (b.id || 0));
}

// =================================================================
//  rebuild  — index.jsonl + facets + topics + (optional) FTS
// =================================================================
async function cmdRebuild(args) {
  const opts = parseOpts(args);
  const traps = await loadAllTraps();
  const seen = new Set();
  const errors = [];
  const lines = [];
  for (const t of traps) {
    if (typeof t.id !== 'number') { errors.push(`${t.file}: missing numeric id`); continue; }
    if (seen.has(t.id)) { errors.push(`duplicate id ${t.id} in ${t.file}`); continue; }
    seen.add(t.id);
    const expected = `trap-${pad(t.id)}.md`;
    if (t.file !== expected) errors.push(`${t.file}: filename should be ${expected}`);
    lines.push(JSON.stringify({
      id: t.id,
      title: t.title || '',
      module: t.module || '',
      topics: t.topics || [],
      symptoms: t.symptoms || [],
      related: t.related || [],
      date: t.date || '',
      status: t.status || 'fixed',
      severity: t.severity || '',
      tags: t.tags || [],
      files: t.files || [],
      file: t.file,
    }));
  }
  await writeUtf8(TRAPS_INDEX, lines.join('\n') + (lines.length ? '\n' : ''));
  console.log(`[rebuild] wrote ${lines.length} entries to traps/index.jsonl`);

  await buildFacets(traps);
  await buildAgentGuardFacets(traps);
  await buildTopicPages(traps);

  if (opts.fts !== false) {
    try { await buildFtsIndex(traps); }
    catch (e) { errors.push('fts build failed: ' + e.message); }
  }

  if (errors.length) {
    console.error('[rebuild] errors:'); for (const e of errors) console.error('  ' + e);
    process.exitCode = 1;
  }
}

// =================================================================
//  facets  — by-module / by-tag / by-topic / by-file / by-symptom
// =================================================================
async function cmdFacets() { await buildFacets(await loadAllTraps()); }

async function buildFacets(traps) {
  const active = traps.filter(t => (t.status || 'fixed') !== 'archived');
  const byModule = {}, byTag = {}, byTopic = {}, byFile = {}, bySymptom = {};
  const push = (m, k, id) => { if (!k) return; (m[k] = m[k] || []).push(id); };
  for (const t of active) {
    push(byModule, t.module, t.id);
    for (const x of t.tags || []) push(byTag, x, t.id);
    for (const x of t.topics || []) push(byTopic, x, t.id);
    for (const f of t.files || []) push(byFile, normalizeFile(f), t.id);
    for (const s of t.symptoms || []) push(bySymptom, normalizeSymptom(s), t.id);
  }
  for (const m of [byModule, byTag, byTopic, byFile, bySymptom]) {
    for (const k of Object.keys(m)) m[k] = [...new Set(m[k])].sort((a, b) => a - b);
  }
  await writeUtf8(path.join(TRAPS_DIR, 'by-module.json'), JSON.stringify(byModule, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-tag.json'), JSON.stringify(byTag, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-topic.json'), JSON.stringify(byTopic, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-file.json'), JSON.stringify(byFile, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-symptom.json'), JSON.stringify(bySymptom, null, 2) + '\n');
  console.log(`[facets] modules=${Object.keys(byModule).length} tags=${Object.keys(byTag).length} topics=${Object.keys(byTopic).length} files=${Object.keys(byFile).length} symptoms=${Object.keys(bySymptom).length}`);
}

function normalizeFile(f) {
  return String(f).trim().replace(/[\\/]+/g, '/').replace(/^\.\//, '');
}
function normalizeSymptom(s) {
  return String(s).trim().replace(/\s+/g, ' ').slice(0, 60);
}

async function buildAgentGuardFacets(traps) {
  await ensureDir(AGENT_GENERATED_DIR);
  const operational = traps.filter(t => (t.status || 'fixed') !== 'archived' && (t.tags || []).includes('operational'));
  const guards = [];
  for (const trap of operational) {
    const guard = {
      id: trap.id,
      file: trap.file,
      title: trap.title || '',
      topics: trap.topics || [],
      severity: trap.severity || '',
    };
    for (const field of AGENT_GUARD_FIELDS) {
      const value = trap[field];
      guard[field] = Array.isArray(value) ? value : [];
    }
    guard.body_commands = extractListFromBody(trap.body || '', 'Bad Commands');
    guard.body_paths = extractListFromBody(trap.body || '', 'Bad Paths');
    guard.body_errors = extractListFromBody(trap.body || '', 'Error Patterns');
    guards.push(guard);
  }

  const byCommand = {}, byTool = {}, byError = {}, byPath = {};
  const push = (map, key, id) => {
    const normalized = normalizeGuardValue(key);
    if (!normalized) return;
    (map[normalized] = map[normalized] || []).push(id);
  };

  for (const guard of guards) {
    for (const item of [...guard.bad_commands, ...guard.body_commands]) push(byCommand, item, guard.id);
    for (const item of guard.bad_tools || []) push(byTool, item, guard.id);
    for (const item of [...guard.error_patterns, ...guard.body_errors]) push(byError, item, guard.id);
    for (const item of [...guard.bad_paths, ...guard.body_paths]) push(byPath, item, guard.id);
  }

  for (const map of [byCommand, byTool, byError, byPath]) {
    for (const key of Object.keys(map)) map[key] = [...new Set(map[key])].sort((a, b) => a - b);
  }

  await writeUtf8(AGENT_GUARDS, JSON.stringify(guards, null, 2) + '\n');
  await writeUtf8(AGENT_BY_COMMAND, JSON.stringify(byCommand, null, 2) + '\n');
  await writeUtf8(AGENT_BY_TOOL, JSON.stringify(byTool, null, 2) + '\n');
  await writeUtf8(AGENT_BY_ERROR, JSON.stringify(byError, null, 2) + '\n');
  await writeUtf8(AGENT_BY_PATH, JSON.stringify(byPath, null, 2) + '\n');
  console.log(`[agent] guards=${guards.length}`);
}

// =================================================================
//  topics  — 自動產生 topics/{slug}.md + topics/INDEX.md
//  AUTO 區由 <!-- AUTO_BEGIN --> ... <!-- AUTO_END --> 包覆，僅覆寫此區
// =================================================================
async function cmdTopics() { await buildTopicPages(await loadAllTraps()); }

const AUTO_BEGIN = '<!-- AUTO_BEGIN -->';
const AUTO_END = '<!-- AUTO_END -->';

async function buildTopicPages(traps) {
  const { topics } = loadTaxonomy();
  const active = traps.filter(t => (t.status || 'fixed') !== 'archived');
  const byTopic = new Map();
  for (const t of active) for (const slug of t.topics || []) {
    if (!byTopic.has(slug)) byTopic.set(slug, []);
    byTopic.get(slug).push(t);
  }
  await ensureDir(TOPICS_DIR);
  for (const topic of topics) {
    const list = (byTopic.get(topic.slug) || []).sort((a, b) => a.id - b.id);
    const tableRows = list.length
      ? list.map(t => `| ${t.id} | ${t.title || ''} | ${(t.files || []).slice(0, 2).join(', ')} | [→](../trap-${pad(t.id)}.md) |`).join('\n')
      : '| - | _尚無相關 trap_ | - | - |';
    const auto = [
      AUTO_BEGIN,
      `**定義**：${topic.desc || ''}`,
      `**關鍵字**：${(topic.keywords || []).join(', ')}`,
      `**相關 trap 數**：${list.length}`,
      '',
      '## 相關 Trap',
      '',
      '| id | 一句話 | 主要檔案 | 連結 |',
      '|----|--------|---------|------|',
      tableRows,
      AUTO_END,
    ].join('\n');
    const file = path.join(TOPICS_DIR, `${topic.slug}.md`);
    let manualTail = '';
    if (existsSync(file)) {
      const old = await readUtf8(file);
      const m = old.match(/<!-- AUTO_END -->([\s\S]*)$/);
      if (m) manualTail = m[1].replace(/^\s*\n/, '\n');
    } else {
      manualTail = '\n\n## 防呆原則\n\n（手動編輯，CLI 不會覆寫此區）\n';
    }
    const content = `# Topic: ${topic.name || topic.slug}\n\n> 自動產生 — \`AUTO_BEGIN/AUTO_END\` 之間請勿手動編輯（會被 \`kb.mjs rebuild\` 覆寫）。\n\n${auto}\n${manualTail}`;
    await writeUtf8(file, content);
  }
  const idxRows = topics.map(t => {
    const n = (byTopic.get(t.slug) || []).length;
    return `| ${t.slug} | ${t.name || ''} | ${n} | [→](${t.slug}.md) |`;
  }).join('\n');
  const orphan = [];
  for (const t of active) for (const s of t.topics || []) {
    if (!topics.find(x => x.slug === s)) orphan.push(`#${t.id} → ${s}`);
  }
  const orphanSec = orphan.length
    ? `\n\n## 未登記的 topic slug（請補入 topics-taxonomy.yml）\n\n${[...new Set(orphan)].sort().map(x => '- ' + x).join('\n')}\n`
    : '';
  const idx = `# 主題目錄（Topics Index）\n\n> 由 \`kb.mjs rebuild\` 自動產生。AI 啟動任務時讀本檔即可掌握所有主題分布。\n\n| slug | 名稱 | 相關 trap 數 | 連結 |\n|------|------|-------------|------|\n${idxRows}\n\n## 用法\n\n- 想知道某類問題以前發生過幾次 → 看上表的「相關 trap 數」\n- 命中主題 → 讀對應 \`topics/{slug}.md\`（含相關 trap 表 + 防呆原則）\n- 模糊查詢 → \`node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"\`${orphanSec}\n`;
  await writeUtf8(path.join(TOPICS_DIR, 'INDEX.md'), idx);
  console.log(`[topics] wrote ${topics.length} topic page(s) + INDEX${orphan.length ? ` (${orphan.length} orphan slugs)` : ''}`);
}

// =================================================================
//  taxonomy lint  — frontmatter topics 必須在 taxonomy 內
// =================================================================
async function cmdTaxonomy(args) {
  const sub = args[0];
  if (sub === 'lint') {
    const { slugs, topics } = loadTaxonomy();
    const traps = await loadAllTraps();
    const errors = [];
    const unmapped = [];
    for (const t of traps) {
      const list = t.topics || [];
      if (list.length === 0 && (t.status || 'fixed') !== 'archived') unmapped.push(t.id);
      for (const s of list) if (!slugs.has(s)) errors.push(`#${t.id}: unknown topic slug "${s}"`);
    }
    console.log(`[taxonomy lint] topics=${topics.length} traps=${traps.length} unmapped=${unmapped.length} errors=${errors.length}`);
    if (unmapped.length) console.log('  unmapped trap ids: ' + unmapped.join(','));
    for (const e of errors) console.error('  ERROR ' + e);
    if (errors.length) process.exitCode = 1;
  } else if (sub === 'stats') {
    const { topics } = loadTaxonomy();
    const traps = await loadAllTraps();
    const counts = new Map();
    for (const t of traps) for (const s of t.topics || []) counts.set(s, (counts.get(s) || 0) + 1);
    console.log('slug\tcount\tname');
    for (const t of topics) console.log(`${t.slug}\t${counts.get(t.slug) || 0}\t${t.name || ''}`);
  } else {
    console.log('Usage: kb.mjs taxonomy <lint|stats>');
  }
}

// =================================================================
//  audit  — 找候選拆分
// =================================================================
async function cmdAudit() {
  const traps = await loadAllTraps();
  const splitCandidates = [];
  for (const t of traps) {
    const lines = (t.body || '').split(/\r?\n/);
    const headings = lines.filter(L => /^##?\s+(症狀|根因|修正|測試|問題)/.test(L));
    if (lines.length > 60 && headings.length >= 3) splitCandidates.push({ id: t.id, lines: lines.length, heads: headings.length });
  }
  console.log(`[audit] split candidates (lines>60 & 多段 症狀/根因): ${splitCandidates.length}`);
  for (const s of splitCandidates) console.log(`  #${s.id}  lines=${s.lines}  headings=${s.heads}`);
}

// =================================================================
//  bulk-tag  — 一次性套用 trap → topics 對照表
// =================================================================
async function cmdBulkTag(args) {
  const opts = parseOpts(args);
  let mapJson;
  if (opts.file) mapJson = await readUtf8(opts.file);
  else mapJson = await new Promise((res, rej) => {
    let s = ''; process.stdin.setEncoding('utf8');
    process.stdin.on('data', c => s += c); process.stdin.on('end', () => res(s)); process.stdin.on('error', rej);
  });
  const map = JSON.parse(mapJson);
  const { slugs } = loadTaxonomy();
  const traps = await loadAllTraps();
  let updated = 0;
  const unknown = new Set();
  for (const t of traps) {
    const key = String(t.id);
    if (!map[key]) continue;
    const newTopics = map[key];
    for (const s of newTopics) if (!slugs.has(s)) unknown.add(s);
    const file = path.join(TRAPS_DIR, t.file);
    const text = await readUtf8(file);
    const { data, body } = parseFrontmatter(text);
    data.topics = newTopics;
    if (!data.symptoms) data.symptoms = [];
    await writeUtf8(file, stringifyFrontmatter(data) + body);
    updated++;
  }
  console.log(`[bulk-tag] updated ${updated} trap(s)`);
  if (unknown.size) {
    console.error('  unknown slugs (not in taxonomy):');
    for (const s of unknown) console.error('    ' + s);
    process.exitCode = 1;
  }
}

// =================================================================
//  FTS5  — 採 Node 22.5+ 內建 node:sqlite，不可用時降級
// =================================================================
function stripMd(s) {
  s = s.replace(/```[\s\S]*?```/g, ' ');
  s = s.replace(/`[^`]+`/g, ' $& ');
  s = s.replace(/^#{1,6}\s+/gm, '');
  s = s.replace(/[*_]{1,3}([^*_]+)[*_]{1,3}/g, '$1');
  return s;
}

async function buildFtsIndex(traps) {
  if (!DatabaseSync) {
    console.log(`[fts] skipped — node:sqlite unavailable (need Node 22.5+; ${sqliteUnavailableReason})`);
    return;
  }
  if (existsSync(FTS_DB)) await unlink(FTS_DB);
  const db = new DatabaseSync(FTS_DB);
  db.exec("PRAGMA journal_mode=MEMORY");
  db.exec(`CREATE VIRTUAL TABLE traps_fts USING fts5(
    id UNINDEXED,
    title,
    module UNINDEXED,
    topics,
    symptoms,
    body,
    files UNINDEXED,
    tokenize='unicode61 remove_diacritics 2'
  )`);
  const ins = db.prepare("INSERT INTO traps_fts(id,title,module,topics,symptoms,body,files) VALUES (?,?,?,?,?,?,?)");
  let n = 0;
  for (const t of traps) {
    if ((t.status || 'fixed') === 'archived') continue;
    ins.run(
      Number(t.id) || 0,
      String(t.title || ''),
      String(t.module || ''),
      (t.topics || []).join(' '),
      (t.symptoms || []).join(' '),
      stripMd(String(t.body || '')),
      (t.files || []).join(' ')
    );
    n++;
  }
  db.exec("INSERT INTO traps_fts(traps_fts) VALUES('optimize')");
  db.close();
  console.log(`[fts] indexed ${n} trap(s) → traps/fts.db`);
}

async function cmdSearch(args) {
  const opts = parseOpts(args);
  const q = args.filter(a => !a.startsWith('--')).join(' ');
  if (!q) { console.error('Usage: kb.mjs search "<query>" [--limit=20] [--json]'); process.exit(2); }
  if (!DatabaseSync) {
    console.error(`[fts] node:sqlite unavailable — need Node 22.5+ (got ${process.version}). Reason: ${sqliteUnavailableReason}`);
    process.exit(1);
  }
  if (!existsSync(FTS_DB)) { console.error('fts.db not found — run `kb.mjs rebuild` first'); process.exit(1); }
  const limit = Math.max(1, Math.min(200, Number(opts.limit) || 20));
  const db = new DatabaseSync(FTS_DB, { readOnly: true });
  let rows;
  try {
    const stmt = db.prepare(`SELECT id, title, module, topics,
      snippet(traps_fts, 5, '«', '»', '…', 12) AS hit,
      bm25(traps_fts) AS rank
      FROM traps_fts WHERE traps_fts MATCH ? ORDER BY rank LIMIT ?`);
    rows = stmt.all(q, limit);
  } catch (e) {
    console.error('[fts] error: ' + e.message);
    process.exit(1);
  }
  db.close();
  if (opts.json) { console.log(JSON.stringify(rows, null, 2)); return; }
  if (!rows.length) { console.log('no match for: ' + q); return; }
  console.log(`[fts] query="${q}"  hits=${rows.length}`);
  for (const r of rows) {
    const id = String(r.id).padStart(3, '0');
    const rank = Number(r.rank).toFixed(3);
    console.log(`  #${id}  rank=${rank}  [${r.module}]  ${r.title}`);
    if (r.hit) console.log(`        ↳ ${String(r.hit).replace(/\s+/g, ' ')}`);
  }
}

// =================================================================
//  new-trap / new-decision
// =================================================================
async function cmdNewTrap(args) {
  const opts = parseOpts(args);
  if (!opts.title) { console.error('Usage: kb.mjs new-trap --module=X --title="..." [--topics=slug1,slug2] [--symptoms="A;B"] [--tags=a,b] [--files=...] [--tests=...] [--related=12,34]'); process.exit(2); }
  const { slugs } = loadTaxonomy();
  const topics = opts.topics ? opts.topics.split(',').map(s => s.trim()).filter(Boolean) : [];
  for (const s of topics) if (!slugs.has(s)) { console.error(`unknown topic slug: ${s}`); process.exit(2); }
  const traps = await loadAllTraps();
  const nextId = traps.reduce((m, t) => Math.max(m, t.id || 0), 0) + 1;
  const today = new Date().toISOString().slice(0, 10);
  const fm = {
    id: nextId,
    title: opts.title,
    module: opts.module || '',
    topics,
    symptoms: opts.symptoms ? opts.symptoms.split(/[;；]/).map(s => s.trim()).filter(Boolean) : [],
    related: opts.related ? opts.related.split(',').map(s => Number(s.trim())).filter(Boolean) : [],
    date: today,
    status: 'fixed',
    severity: opts.severity || 'bug',
    tags: opts.tags ? opts.tags.split(',').map(s => s.trim()).filter(Boolean) : [],
    files: opts.files ? opts.files.split(',').map(s => s.trim()).filter(Boolean) : [],
    tests: opts.tests ? opts.tests.split(',').map(s => s.trim()).filter(Boolean) : [],
  };
  const body = `## 症狀\n\n（待補）\n\n## 根因\n\n（待補）\n\n## 修正\n\n（待補）\n\n## 測試\n\n（待補）\n`;
  const out = path.join(TRAPS_DIR, `trap-${pad(nextId)}.md`);
  await writeUtf8(out, stringifyFrontmatter(fm) + body);
  console.log(`[new-trap] created trap #${nextId} at traps/${path.basename(out)}`);
  await cmdRebuild(['--no-fts']);
}

async function cmdNewDecision(args) {
  const opts = parseOpts(args);
  if (!opts.module || !opts.title) { console.error('Usage: kb.mjs new-decision --module=X --title="..."'); process.exit(2); }
  const dir = path.join(MODULES_DIR, opts.module.toLowerCase(), 'decisions');
  await ensureDir(dir);
  const existing = (await listMd(dir)).map(f => parseInt(path.basename(f).match(/decision-(\d+)/)?.[1] || '0', 10));
  const nextId = (existing.length ? Math.max(...existing) : 0) + 1;
  const today = new Date().toISOString().slice(0, 10);
  const fm = { id: nextId, title: opts.title, module: opts.module, date: today, related_traps: [] };
  const body = `## 決策\n\n（待補）\n\n## 原因\n\n（待補）\n`;
  const out = path.join(dir, `decision-${pad(nextId)}.md`);
  await writeUtf8(out, stringifyFrontmatter(fm) + body);
  console.log(`[new-decision] created at ${path.relative(KB_ROOT, out)}`);
}

// =================================================================
//  health
// =================================================================
async function cmdHealth() {
  const errors = [];
  const warnings = [];
  const traps = await loadAllTraps();
  const seen = new Set();
  const { slugs } = loadTaxonomy();
  for (const t of traps) {
    if (typeof t.id !== 'number') errors.push(`${t.file}: missing numeric id`);
    if (seen.has(t.id)) errors.push(`duplicate id ${t.id} in ${t.file}`);
    seen.add(t.id);
    if (`trap-${pad(t.id)}.md` !== t.file) errors.push(`${t.file}: filename != id`);
    if (!t.title) warnings.push(`${t.file}: empty title`);
    if (!t.module) warnings.push(`${t.file}: empty module`);
    for (const s of t.topics || []) if (!slugs.has(s)) errors.push(`${t.file}: unknown topic "${s}"`);
    if (!(t.topics || []).length && (t.status || 'fixed') !== 'archived') warnings.push(`${t.file}: empty topics (run kb.mjs taxonomy lint)`);
  }
  if (existsSync(TRAPS_INDEX)) {
    const idxLines = (await readUtf8(TRAPS_INDEX)).split(/\r?\n/).filter(Boolean);
    if (idxLines.length !== traps.length) errors.push(`traps/index.jsonl out of date: ${idxLines.length} vs ${traps.length} fragments — run rebuild`);
  } else if (traps.length) errors.push('traps/index.jsonl missing — run rebuild');
  for await (const p of walk(KB_ROOT)) {
    if (!p.endsWith('.md')) continue;
    const buf = await readFile(p);
    if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) errors.push(`${path.relative(KB_ROOT, p)}: UTF-8 BOM detected`);
    if (buf.toString('utf8').includes('\uFFFD')) errors.push(`${path.relative(KB_ROOT, p)}: contains U+FFFD (encoding corruption)`);
    for (const issue of checkMarkdownLinks(p, buf.toString('utf8'))) {
      errors.push(issue);
    }
  }
  if (existsSync(MODULES_DIR)) {
    for await (const p of walk(MODULES_DIR)) {
      if (path.basename(p) === 'quickref.md') {
        const lines = (await readUtf8(p)).split(/\r?\n/).length;
        if (lines > 150) warnings.push(`${path.relative(KB_ROOT, p)}: ${lines} lines > 150 (quickref should be terse)`);
      }
    }
  }
  for (const issue of collectAgentGeneratedHealthIssues()) warnings.push(issue);
  for (const issue of collectWorkspaceSettingsHealthIssues()) errors.push(issue);
  console.log(`[health] traps=${traps.length}, errors=${errors.length}, warnings=${warnings.length}`);
  for (const e of errors) console.error('  ERROR ' + e);
  for (const w of warnings) console.warn('  WARN  ' + w);
  if (errors.length) process.exitCode = 1;
}

function checkMarkdownLinks(file, text) {
  const issues = [];
  const relFile = normalizeFile(path.relative(KB_ROOT, file));
  const linkRe = /\[[^\]]+\]\(([^)]+)\)/g;
  let match;
  while ((match = linkRe.exec(text)) !== null) {
    const rawTarget = match[1].trim();
    if (!rawTarget || rawTarget.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(rawTarget)) continue;
    const withoutAnchor = rawTarget.split('#')[0];
    if (!withoutAnchor) continue;
    const decoded = decodeURIComponent(withoutAnchor);
    const target = path.resolve(path.dirname(file), decoded);
    if (!target.startsWith(KB_ROOT) || !existsSync(target)) {
      issues.push(`${relFile}: broken markdown link ${rawTarget}`);
    }
  }
  return issues;
}

function collectAgentGeneratedHealthIssues() {
  const warnings = [];
  if (!existsSync(path.join(AGENT_DIR, 'INDEX.md'))) {
    warnings.push('agent/INDEX.md missing — Agent guard disabled');
  }
  const generated = [AGENT_GUARDS, AGENT_BY_COMMAND, AGENT_BY_TOOL, AGENT_BY_ERROR, AGENT_BY_PATH];
  const missing = generated.filter(file => !existsSync(file));
  if (missing.length) warnings.push('agent/generated facets missing — run kb.mjs rebuild');
  return warnings;
}

function collectWorkspaceSettingsHealthIssues() {
  const issues = [];
  const settingsPath = path.join(VSCODE_ROOT, 'settings.json');
  if (!existsSync(settingsPath)) return ['.vscode/settings.json missing'];
  let settings;
  try { settings = JSON.parse(readFileSync(settingsPath, 'utf8')); }
  catch (e) { return [`.vscode/settings.json invalid JSON: ${e.message}`]; }
  if (settings['chat.promptFiles'] !== true) issues.push('.vscode/settings.json missing chat.promptFiles=true');
  const locations = settings['chat.promptFilesLocations'] || {};
  if (locations['.vscode'] !== true || locations['.vscode/prompts'] !== true) {
    issues.push('.vscode/settings.json missing chat.promptFilesLocations for .vscode and .vscode/prompts');
  }
  if (settings['files.encoding'] && settings['files.encoding'] !== 'utf8') {
    issues.push('.vscode/settings.json files.encoding must be utf8');
  }
  return issues;
}

async function cmdFinishCheck(args) {
  await cmdTaxonomy(['lint']);
  await cmdHealth();
  const previousExitCode = process.exitCode || 0;
  await cmdRepairHealth(args);
  if (previousExitCode || process.exitCode) process.exitCode = 1;
}

async function cmdStartCheck(args) {
  const opts = parseOpts(args);
  const moduleName = opts.module || opts.m || '';
  const file = opts.file || '';
  const query = opts.query || args.filter(a => !a.startsWith('--')).join(' ');
  console.log('[start-check] required reads');
  console.log('  - .vscode/knowledge/agent/INDEX.md');
  console.log('  - .vscode/knowledge/INDEX.md');
  if (moduleName) console.log(`  - .vscode/knowledge/modules/${String(moduleName).toLowerCase()}/quickref.md`);
  else console.log('  - module quickref: infer module first; do not run placeholder command');
  console.log('  - .vscode/knowledge/traps/topics/INDEX.md');
  if (file && existsSync(path.join(TRAPS_DIR, 'by-file.json'))) {
    const byFile = readJsonIfExists(path.join(TRAPS_DIR, 'by-file.json'), {});
    const key = normalizeFile(file);
    const hits = byFile[key] || [];
    console.log(`[start-check] by-file ${key}: ${hits.length ? hits.map(id => '#' + id).join(', ') : 'no direct trap hit'}`);
  }
  if (query) {
    if (hasPlaceholder(query)) console.log('[start-check] query has placeholder; replace with concrete keyword before search');
    else console.log(`[start-check] optional search: node .vscode/knowledge/scripts/kb.mjs search ${JSON.stringify(query)}`);
  }
  await cmdRepairStatus(['--quiet-ok']);
}

function loadGuards() {
  return readJsonIfExists(AGENT_GUARDS, []);
}

async function cmdRepairPreflight(args) {
  const opts = parseOpts(args);
  const command = String(opts.command || '').trim();
  const tool = String(opts.tool || '').trim().toLowerCase();
  const targetPath = String(opts.path || '').trim();
  const intent = String(opts.intent || '').trim();
  const decisions = [];
  if (hasPlaceholder(command) || hasPlaceholder(targetPath) || hasPlaceholder(intent)) {
    decisions.push({ level: 'deny', reason: 'placeholder detected; infer concrete values before execution' });
  }
  if (/\s&&\s/.test(command)) decisions.push({ level: 'deny', reason: 'PowerShell 5.1 does not use &&; use semicolon or separate commands' });
  if (/Get-Content\b[\s\S]*\|[\s\S]*Set-Content\b|\bSet-Content\b|\(\s*Get-Content\s*\)[\s\S]*-replace/i.test(command)) {
    decisions.push({ level: 'deny', reason: 'PowerShell text rewrite risks UTF-8 corruption; use editor/apply_patch-safe workflow' });
  }
  if ((tool === 'search' || /grep|rg|search/i.test(command)) && /(^|[\\/])\.vscode([\\/]|$)|\.vscode\/knowledge/i.test(command + ' ' + targetPath)) {
    decisions.push({ level: 'warn', reason: '.vscode may be ignored by search tools; prefer direct read/list_dir or include ignored files' });
  }

  const guards = loadGuards();
  for (const guard of guards) {
    if ((guard.bad_tools || []).some(item => guardMatches(tool, item))) decisions.push({ level: 'deny', trap: guard.id, reason: guard.title || 'bad tool guard' });
    if ([...(guard.bad_commands || []), ...(guard.body_commands || [])].some(item => guardMatches(command, item))) decisions.push({ level: 'deny', trap: guard.id, reason: guard.title || 'bad command guard' });
    if ([...(guard.bad_paths || []), ...(guard.body_paths || [])].some(item => guardMatches(targetPath, item))) decisions.push({ level: 'warn', trap: guard.id, reason: guard.title || 'bad path guard' });
  }

  const level = decisions.some(d => d.level === 'deny') ? 'deny' : decisions.some(d => d.level === 'warn') ? 'warn' : 'allow';
  console.log(`[repair-preflight] ${level}`);
  if (tool) console.log(`  tool: ${tool}`);
  if (command) console.log(`  command: ${normalizeCommand(command)}`);
  if (targetPath) console.log(`  path: ${normalizePathValue(targetPath)}`);
  if (intent) console.log(`  intent: ${intent}`);
  for (const decision of decisions) console.log(`  ${decision.level.toUpperCase()}${decision.trap ? ` #${decision.trap}` : ''}: ${decision.reason}`);
  if (level === 'deny') process.exitCode = 1;
}

async function cmdRepairRecord(args) {
  const opts = parseOpts(args);
  const fingerprint = makeFingerprint(opts);
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const row = {
    schema: 1,
    ts: new Date().toISOString(),
    fingerprint,
    error: redactSensitive(opts.error || opts.stderr || opts.message || ''),
    resolved: false,
  };
  await appendJsonl(file, row);
  const count = (groupByFingerprint(readJsonlIfExists(file)).get(fingerprint.id) || []).length;
  console.log(`[repair-record] ${fingerprint.id} count=${count}`);
  if (count >= REPAIR_RETRY_LIMIT) {
    console.log('  pending repair: same fingerprint repeated; change method or create/update operational trap');
    process.exitCode = 1;
  }
}

async function cmdRepairStatus(args) {
  const opts = parseOpts(args);
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const falsePositives = readJsonIfExists(path.join(runtimeDir(), REPAIR_FALSE_POSITIVES_FILE), {});
  const grouped = groupByFingerprint(readJsonlIfExists(file));
  const pending = [];
  for (const [id, records] of grouped) {
    if (records.length < REPAIR_RETRY_LIMIT) continue;
    const fp = falsePositives[id];
    if (fp && (!fp.expires || new Date(fp.expires) >= new Date())) continue;
    pending.push({ id, count: records.length, latest: records[records.length - 1] });
  }
  if (!opts['quiet-ok'] || pending.length) console.log(`[repair-status] pending=${pending.length}`);
  for (const item of pending) {
    const fp = item.latest.fingerprint || {};
    console.log(`  ${item.id} count=${item.count} tool=${fp.tool || ''} command=${fp.command || ''} intent=${fp.intent || ''}`);
  }
  if (pending.length) process.exitCode = 1;
}

async function cmdRepairHealth(args) {
  const previous = process.exitCode || 0;
  process.exitCode = 0;
  await cmdRepairStatus(args);
  const pendingExit = process.exitCode || 0;
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const records = readJsonlIfExists(file);
  const invalid = records.filter(r => r.invalid);
  const secretLike = records.filter(r => /\.env|TOKEN|SECRET|PASSWORD|BEGIN RSA|PRIVATE KEY|Bearer\s+[A-Za-z0-9]/i.test(JSON.stringify(r))).length;
  console.log(`[repair-health] records=${records.length} invalid=${invalid.length} secret_like=${secretLike}`);
  for (const row of invalid) console.error(`  ERROR invalid jsonl line ${row.line}`);
  if (secretLike) console.error('  ERROR runtime ledger may contain sensitive data; redact or delete the entry');
  if (previous || pendingExit || invalid.length || secretLike) process.exitCode = 1;
}

async function* walk(d) {
  if (!existsSync(d)) return;
  for (const e of await readdir(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) {
      if (['backups', 'runtime'].includes(e.name)) continue;
      yield* walk(p);
    }
    else yield p;
  }
}

// =================================================================
//  arg parser
// =================================================================
function parseOpts(argv) {
  const out = {};
  for (const a of argv) {
    if (a === '--no-fts') { out.fts = false; continue; }
    const m = a.match(/^--([\w-]+)(?:=(.*))?$/);
    if (m) out[m[1]] = m[2] ?? true;
  }
  return out;
}

// =================================================================
//  main
// =================================================================
const HELP = `kb.mjs — knowledge base v3 CLI

Commands:
  rebuild [--no-fts]     重建 index.jsonl + facets + topics + (FTS db)
  new-trap               --module=X --title="..." [--topics=slug1,slug2] [--symptoms="A;B"]
                         [--tags=a,b] [--files=...] [--tests=...] [--related=12,34]
  new-decision           --module=X --title="..."
  taxonomy lint|stats    校驗 / 統計 topic 覆蓋率
  facets                 只重建 facet JSON
  topics                 只重建 topics/*.md（保留手動防呆原則段落）
  audit                  找拆分候選（行數 > 60 且多段症狀/根因）
  bulk-tag --file=X.json 一次性套用 trap → topics 對照
  search "<query>"       SQLite FTS5 全文檢索（需 Node 22.5+）
  start-check            任務啟動必讀包與 Agent Repair Context
  repair-preflight       --tool=X --command="..." [--path=...] [--intent=...]
  repair-record          --tool=X --command="..." --exit-code=N --error="..."
  repair-status          檢查 repeated failure pending repair
  repair-health          任務收尾 repair gate，pending/secret/invalid 必須為 0
  health                 健康檢查
  finish-check           taxonomy lint + health + repair-health
`;

const [, , cmd, ...rest] = process.argv;
try {
  switch (cmd) {
    case 'rebuild': await cmdRebuild(rest); break;
    case 'new-trap': await cmdNewTrap(rest); break;
    case 'new-decision': await cmdNewDecision(rest); break;
    case 'taxonomy': await cmdTaxonomy(rest); break;
    case 'facets': await cmdFacets(); break;
    case 'topics': await cmdTopics(); break;
    case 'audit': await cmdAudit(); break;
    case 'bulk-tag': await cmdBulkTag(rest); break;
    case 'search': await cmdSearch(rest); break;
    case 'start-check': await cmdStartCheck(rest); break;
    case 'repair-preflight': await cmdRepairPreflight(rest); break;
    case 'repair-record': await cmdRepairRecord(rest); break;
    case 'repair-status': await cmdRepairStatus(rest); break;
    case 'repair-health': await cmdRepairHealth(rest); break;
    case 'health': await cmdHealth(); break;
    case 'finish-check': await cmdFinishCheck(rest); break;
    default: console.log(HELP); break;
  }
} catch (e) {
  console.error(e.stack || e.message);
  process.exit(1);
}