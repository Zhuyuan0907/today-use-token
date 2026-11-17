// 今天蹬了多少 Token —— 讀 ccusage 的數據，給網頁用。
// 伺服器本身不需要任何 npm 套件；`npm install` 只會在專案裡裝一份 ccusage。
// Node 20+ 直接跑：node server.js

import http from 'node:http';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { readFile, readdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, 'public', 'index.html');

const PORT = Number(process.env.PORT) || 3000;
const HOST = process.env.HOST || '0.0.0.0';
const TZ = process.env.TZ_NAME || Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
const CACHE_MS = 60_000; // ccusage 一次要跑好幾秒，一分鐘內重複請求直接回快取
const DAYS = 60; // 網頁會依畫面高度決定顯示幾天

// ---------- 電費估算 ----------
// 每 100 萬個 token 大約耗多少 Wh（含伺服器主機、機房冷卻等損耗）。三組係數 = 樂觀／中間／保守：
//   low  Simon Couch 的「中等 context」係數：由 Epoch AI 估 GPT-4o 讀 1 萬 token、寫 500 token 約 2.5 Wh 推得
//   mid  Simon Couch 拿來算 Claude Code 的「長 context」係數：由 Epoch AI 估讀 10 萬 token 約 40 Wh 推得
//   high Projet Celsius（2026-11）給 Opus 5.5 這類大模型的係數：寫 2.8、讀 0.9 Wh／千 token，讀快取取讀的 1/10
//   （輸出：輸入 = 5:1、寫快取 = 輸入 ×1.25、讀快取 = 輸入 ×1/10，比例照 API 價格）
// 為什麼不能用一般聊天的數字：coding agent 每次呼叫都帶著十幾萬 token 的 context，
//   每輸出一個 token 都要把整段對話的 KV cache 從 GPU 記憶體讀一遍，也佔掉大量記憶體、讓同一批能跑的人變少。
// 驗證：2026-11-17 的 3,796 次實際呼叫（平均 context 16 萬）用 H100 頻寬／算力算 bottom-up，
//   中間情境約 31 度，跟 mid 的 36 度接近；樂觀到保守約 11–115 度。
const ENERGY_SCENARIOS = {
  low: { inputTokens: 200, outputTokens: 1000, cacheCreationTokens: 250, cacheReadTokens: 20 },
  mid: { inputTokens: 390, outputTokens: 1950, cacheCreationTokens: 490, cacheReadTokens: 39 },
  high: { inputTokens: 900, outputTokens: 2800, cacheCreationTokens: 1125, cacheReadTokens: 90 },
};
const KWH_PRICE = Number(process.env.KWH_PRICE) || 3.7823; // 台電平均電價（元／度），2026 年凍漲
const KWH_CURRENCY = process.env.KWH_CURRENCY || 'NT$';

// 回傳 { low, mid, high }，單位度（kWh）
function energyKwh(usage) {
  const out = {};
  for (const [name, whPerMillion] of Object.entries(ENERGY_SCENARIOS)) {
    let wh = 0;
    for (const [k, w] of Object.entries(whPerMillion)) wh += ((Number(usage[k]) || 0) / 1e6) * w;
    out[name] = wh / 1000;
  }
  return out;
}


// ---------- 日期工具 ----------

function todayIn(tz) {
  // en-CA 的格式剛好是 YYYY-MM-DD
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date());
}

function addDays(ymd, n) {
  const d = new Date(`${ymd}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// ---------- 執行 ccusage ----------

// 優先用專案自己裝的 ccusage（npm install 裝進 node_modules，版本固定），並用跑伺服器的同一個 node 執行，
// 不必管 PATH 上有沒有 node；沒裝的話才用 PATH 上的 ccusage。CCUSAGE_BIN 可以指定別的執行檔。
function resolveCcusage() {
  if (process.env.CCUSAGE_BIN) return { cmd: process.env.CCUSAGE_BIN, pre: [] };
  try {
    const pkgFile = path.join(__dirname, 'node_modules', 'ccusage', 'package.json');
    const pkg = JSON.parse(readFileSync(pkgFile, 'utf8'));
    const bin = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin?.ccusage;
    if (bin) return { cmd: process.execPath, pre: [path.join(path.dirname(pkgFile), bin)] };
  } catch {
    // 沒有 node_modules：用全域安裝的 ccusage
  }
  return { cmd: 'ccusage', pre: [] };
}
const CCUSAGE = resolveCcusage();

function runCcusage(args) {
  return new Promise((resolve, reject) => {
    execFile(
      CCUSAGE.cmd,
      [...CCUSAGE.pre, ...args],
      { timeout: 120_000, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, NO_COLOR: '1' } },
      (err, stdout, stderr) => {
        if (err) {
          const msg = (stderr || err.message || '').toString().trim().split('\n').slice(-3).join(' ');
          reject(new Error(msg || 'ccusage 執行失敗'));
          return;
        }
        try {
          resolve(JSON.parse(stdout));
        } catch {
          reject(new Error('ccusage 的輸出不是 JSON'));
        }
      },
    );
  });
}

async function loadDaily(since) {
  const args = ['daily', '--json', '--by-agent', '--since', since.replaceAll('-', ''), '-z', TZ];
  try {
    return await runCcusage(args);
  } catch (err) {
    // 抓不到線上價格表時，改用 ccusage 本機快取的價格再試一次
    console.warn(`[ccusage] ${err.message}；改用 --offline 重試`);
    return runCcusage([...args, '--offline']);
  }
}

// ---------- 整理成網頁要的格式 ----------

const KNOWN = ['claude', 'codex'];

function emptyAgent() {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    totalTokens: 0,
    totalCost: 0,
    models: [],
    sources: [],
  };
}

function addInto(target, src, sourceName) {
  for (const k of ['inputTokens', 'outputTokens', 'cacheCreationTokens', 'cacheReadTokens', 'totalTokens']) {
    target[k] += Number(src[k]) || 0;
  }
  target.totalCost += Number(src.totalCost) || 0;
  if (sourceName && !target.sources.includes(sourceName)) target.sources.push(sourceName);
  for (const m of src.modelBreakdowns || []) {
    const tokens =
      (Number(m.inputTokens) || 0) +
      (Number(m.outputTokens) || 0) +
      (Number(m.cacheCreationTokens) || 0) +
      (Number(m.cacheReadTokens) || 0);
    const existing = target.models.find((x) => x.name === m.modelName);
    if (existing) {
      existing.tokens += tokens;
      existing.cost += Number(m.cost) || 0;
    } else {
      target.models.push({ name: m.modelName, tokens, cost: Number(m.cost) || 0 });
    }
  }
}

function normalize(raw, since, today) {
  const byDate = new Map();
  for (const row of raw.daily || []) byDate.set(row.period, row);

  const days = [];
  for (let d = since; d <= today; d = addDays(d, 1)) {
    const row = byDate.get(d);
    const agents = { claude: emptyAgent(), codex: emptyAgent(), other: emptyAgent() };
    for (const a of row?.agents || []) {
      const key = KNOWN.includes(a.agent) ? a.agent : 'other';
      addInto(agents[key], a, key === 'other' ? a.agent : null);
    }
    for (const a of Object.values(agents)) {
      a.models.sort((x, y) => y.tokens - x.tokens);
      a.energyKwh = energyKwh(a);
    }
    const sum = (f) => Object.values(agents).reduce((s, a) => s + f(a), 0);
    const perScenario = (f) => Object.fromEntries(Object.keys(ENERGY_SCENARIOS).map((k) => [k, f(k)]));
    const kwh = perScenario((k) => sum((a) => a.energyKwh[k]));
    days.push({
      date: d,
      totalTokens: sum((a) => a.totalTokens),
      totalCost: sum((a) => a.totalCost),
      energyKwh: kwh, // { low, mid, high }
      electricityCost: perScenario((k) => kwh[k] * KWH_PRICE),
      agents,
    });
  }
  return days;
}

// ---------- 快取 ----------

let cache = null; // { data, at }
let inflight = null;

async function refresh() {
  if (inflight) return inflight;
  inflight = (async () => {
    const today = todayIn(TZ);
    const since = addDays(today, -(DAYS - 1));
    const raw = await loadDaily(since);
    const data = {
      generatedAt: new Date().toISOString(),
      timezone: TZ,
      today,
      electricity: { pricePerKwh: KWH_PRICE, currency: KWH_CURRENCY, whPerMillionTokens: ENERGY_SCENARIOS },
      days: normalize(raw, since, today),
    };
    cache = { data, at: Date.now() };
    return data;
  })();
  try {
    return await inflight;
  } finally {
    inflight = null;
  }
}

async function getUsage(force) {
  const fresh = cache && Date.now() - cache.at < CACHE_MS && cache.data.today === todayIn(TZ);
  if (fresh && !force) return cache.data;
  if (cache && !force && cache.data.today === todayIn(TZ)) {
    // 先回舊資料，背景更新，網頁不用乾等
    refresh().catch((err) => console.error('[refresh]', err.message));
    return cache.data;
  }
  return refresh();
}

// ---------- 現在有沒有在蹬：看 log 檔最後一次寫入的時間 ----------
// Claude Code 和 Codex 一邊跑一邊把對話（含 token 用量）寫進 .jsonl，
// 最近 ACTIVE_SECONDS 秒內有被寫入，就算正在蹬。

const ACTIVE_MS = (Number(process.env.ACTIVE_SECONDS) || 120) * 1000;
const STATUS_CACHE_MS = 3_000;
const HOME = os.homedir();

const WATCH = {
  claude: {
    // 跟 ccusage 一樣：有設 CLAUDE_CONFIG_DIR 就用它（可逗號分隔多個），否則看兩個預設位置
    dirs: (process.env.CLAUDE_CONFIG_DIR
      ? process.env.CLAUDE_CONFIG_DIR.split(',').map((d) => d.trim()).filter(Boolean)
      : [path.join(HOME, '.config', 'claude'), path.join(HOME, '.claude')]
    ).map((d) => path.join(d, 'projects')),
    // 專案/<session>.jsonl；子代理人寫在 專案/<session>/subagents/，算同一個工作階段
    session: (rel) => rel.split(path.sep).slice(0, 2).join('/').replace(/\.jsonl$/, ''),
  },
  codex: {
    dirs: [path.join(process.env.CODEX_HOME || path.join(HOME, '.codex'), 'sessions')],
    session: (rel) => rel, // 年/月/日/rollout-….jsonl，一個檔一個工作階段
  },
};

async function scanAgent({ dirs, session }) {
  const now = Date.now();
  let last = 0;
  const live = new Set();
  for (const dir of dirs) {
    let files;
    try {
      files = await readdir(dir, { recursive: true });
    } catch {
      continue; // 沒裝這個工具，或目錄還不存在
    }
    await Promise.all(
      files
        .filter((f) => f.endsWith('.jsonl'))
        .map(async (f) => {
          try {
            const { mtimeMs } = await stat(path.join(dir, f));
            if (mtimeMs > last) last = mtimeMs;
            if (now - mtimeMs < ACTIVE_MS) live.add(session(f));
          } catch {
            // 檔案剛好被刪掉之類的，略過
          }
        }),
    );
  }
  return {
    active: live.size > 0,
    sessions: live.size,
    lastActiveAt: last ? new Date(last).toISOString() : null,
    idleSeconds: last ? Math.max(0, Math.round((now - last) / 1000)) : null,
  };
}

let statusCache = null; // { data, at }
let statusInflight = null;

async function getStatus() {
  if (statusCache && Date.now() - statusCache.at < STATUS_CACHE_MS) return statusCache.data;
  if (!statusInflight) {
    statusInflight = (async () => {
      const entries = await Promise.all(Object.entries(WATCH).map(async ([k, w]) => [k, await scanAgent(w)]));
      const data = { checkedAt: new Date().toISOString(), activeWindowSeconds: ACTIVE_MS / 1000, agents: Object.fromEntries(entries) };
      statusCache = { data, at: Date.now() };
      return data;
    })().finally(() => {
      statusInflight = null;
    });
  }
  return statusInflight;
}

// ---------- HTTP ----------

function send(res, status, body, type) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname === '/' || url.pathname === '/index.html') {
      send(res, 200, await readFile(INDEX), 'text/html; charset=utf-8');
    } else if (url.pathname === '/api/usage') {
      const data = await getUsage(url.searchParams.has('fresh'));
      send(res, 200, JSON.stringify(data), 'application/json; charset=utf-8');
    } else if (url.pathname === '/api/status') {
      send(res, 200, JSON.stringify(await getStatus()), 'application/json; charset=utf-8');
    } else {
      send(res, 404, 'Not found', 'text/plain; charset=utf-8');
    }
  } catch (err) {
    console.error('[request]', err.message);
    send(res, 500, JSON.stringify({ error: err.message }), 'application/json; charset=utf-8');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`今天蹬了多少 Token：已啟動（時區 ${TZ}，ccusage：${CCUSAGE.pre[0] || CCUSAGE.cmd}）`);
  console.log(`  本機     http://localhost:${PORT}`);
  if (HOST === '0.0.0.0') {
    for (const list of Object.values(os.networkInterfaces())) {
      for (const n of list || []) {
        if (n.family === 'IPv4' && !n.internal) console.log(`  區網     http://${n.address}:${PORT}`);
      }
    }
  }
  refresh().catch((err) => console.error('[ccusage]', err.message));
});
