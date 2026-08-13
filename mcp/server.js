#!/usr/bin/env node
// nbody-simulator MCP 서버 — 창이 있는 앱을 자동으로 검증하기 위한 제어 통로.
//
// 앱과는 파일로 주고받는다(src/app/ControlBridge.cpp 참조).
//   여기서 <dir>\cmd.txt 를 쓰면  ->  앱이 읽고 지운다  ->  <dir>\resp.txt 로 답한다
// 소켓을 안 쓰는 이유는 방화벽·포트 충돌·권한 문제를 피하기 위해서다.
//
// 외부 의존성 0 — Node 내장 모듈만 쓴다. PNG 인코딩도 내장 zlib 으로 직접 만든다.

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawn } = require('child_process');

const CONTROL_DIR = process.env.NBODY_CONTROL_DIR || path.join(os.tmpdir(), 'nbody-mcp');
const EXE_PATH = process.env.NBODY_EXE ||
  path.resolve(__dirname, '..', 'build', 'Release', 'nbody.exe');

const CMD_FILE   = path.join(CONTROL_DIR, 'cmd.txt');
const RESP_FILE  = path.join(CONTROL_DIR, 'resp.txt');
const READY_FILE = path.join(CONTROL_DIR, 'ready.txt');

let child = null;

// ---------------------------------------------------------------- 유틸

const sleep = ms => new Promise(r => setTimeout(r, ms));

function ensureDir() {
  fs.mkdirSync(CONTROL_DIR, { recursive: true });
}

// 명령 하나를 보내고 응답을 기다린다.
// 응답은 "key=value" 줄이라 그대로 객체로 바꾼다.
//
// 한 번에 하나씩만 보낸다(sendQueue). 명령 파일과 응답 파일이 하나뿐이라 두 호출이 겹치면
// 뒤엣것이 앞엣것의 명령을 덮어쓰고, 남의 응답을 자기 것으로 읽거나 둘 다 타임아웃한다.
let sendQueue = Promise.resolve();
function send(kv, timeoutMs = 15000) {
  const run = sendQueue.then(() => sendNow(kv, timeoutMs));
  // 앞 호출이 실패해도 줄이 끊기면 안 되므로 큐 자체는 항상 성공으로 이어 붙인다.
  sendQueue = run.then(() => {}, () => {});
  return run;
}

// key=value 한 줄로 나가는 값이라 줄바꿈이 들어가면 그 자리에서 새 명령이 된다.
// 예를 들어 경로에 "\ncmd=quit" 을 넣으면 스크린샷 대신 앱이 종료된다.
function encodeValue(v) {
  const s = String(v);
  if (/[\r\n]/.test(s))
    throw new Error(`값에 줄바꿈을 넣을 수 없습니다: ${JSON.stringify(s)}`);
  return s;
}

async function sendNow(kv, timeoutMs) {
  ensureDir();
  try { fs.unlinkSync(RESP_FILE); } catch (_) {}
  const body = Object.entries(kv).map(([k, v]) => `${k}=${encodeValue(v)}`).join('\n') + '\n';
  fs.writeFileSync(CMD_FILE, body, 'utf8');

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(RESP_FILE)) {
      const text = fs.readFileSync(RESP_FILE, 'utf8');
      try { fs.unlinkSync(RESP_FILE); } catch (_) {}
      const out = {};
      for (const line of text.split('\n')) {
        const i = line.indexOf('=');
        if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).replace(/\r$/, '');
      }
      return out;
    }
    await sleep(40);
  }
  throw new Error(`앱이 ${timeoutMs}ms 안에 응답하지 않았습니다. 앱이 떠 있는지 확인하세요.`);
}

function appAlive() {
  return child !== null && child.exitCode === null;
}

// RGBA raw(앱이 저장한 형식) -> PNG. 외부 라이브러리 없이 zlib 만으로 만든다.
function rawToPng(rawPath, pngPath) {
  const buf = fs.readFileSync(rawPath);
  const nl = buf.indexOf(0x0a);
  if (nl < 0) throw new Error('raw 헤더를 찾지 못했습니다');
  const head = buf.slice(0, nl).toString('ascii').split(' ');
  if (head[0] !== 'NBRAW1') throw new Error(`알 수 없는 raw 형식: ${head[0]}`);
  const w = parseInt(head[1], 10), h = parseInt(head[2], 10);
  const px = buf.slice(nl + 1);

  // PNG 는 줄마다 앞에 필터 바이트(0 = 필터 없음)를 붙인다.
  const stride = w * 4;
  const rawWithFilter = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    rawWithFilter[y * (stride + 1)] = 0;
    px.copy(rawWithFilter, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0, 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;  // 8비트 RGBA

  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(rawWithFilter, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
  fs.writeFileSync(pngPath, png);
  return { width: w, height: h, bytes: png.length };
}

let CRC_TABLE = null;
function crc32(buf) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      CRC_TABLE[n] = c;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// 스크린샷 저장 경로를 검사한다.
// 이 서버는 자기 권한으로 파일을 쓰므로, 경로를 그대로 받으면 호출자가 아무 파일이나
// PNG 로 덮어쓸 수 있다(소스·설정·사용자 문서). 확장자를 .png 로 묶고 쓰기 가능한 위치를
// 프로젝트 폴더와 제어 폴더로 한정한다.
const PROJECT_ROOT = path.resolve(__dirname, '..');
function safeShotPath(p) {
  const abs = path.resolve(p);
  if (path.extname(abs).toLowerCase() !== '.png')
    throw new Error(`스크린샷 경로는 .png 여야 합니다: ${abs}`);
  const roots = [PROJECT_ROOT, path.resolve(CONTROL_DIR)];
  const inside = roots.some(r => abs === r || abs.startsWith(r + path.sep));
  if (!inside)
    throw new Error(`허용된 폴더 밖입니다(프로젝트 폴더 또는 제어 폴더 안이어야 합니다): ${abs}`);
  return abs;
}

// 문자열 응답을 숫자로 바꿔 읽기 좋게 만든다.
function typed(resp) {
  const out = {};
  for (const [k, v] of Object.entries(resp)) {
    out[k] = (/^-?\d+(\.\d+)?$/.test(v)) ? Number(v) : v;
  }
  return out;
}

// ---------------------------------------------------------------- 도구 구현

const tools = {
  async nbody_launch({ particleCount, gridSize, preset, waitMs = 6000 }) {
    if (appAlive()) return { ok: true, note: '이미 실행 중입니다', pid: child.pid };
    if (!fs.existsSync(EXE_PATH)) throw new Error(`실행 파일이 없습니다: ${EXE_PATH}`);
    ensureDir();
    try { fs.unlinkSync(READY_FILE); } catch (_) {}

    child = spawn(EXE_PATH, [`--control-dir=${CONTROL_DIR}`], {
      cwd: path.dirname(EXE_PATH),
      detached: false,
      stdio: 'ignore',
    });
    child.on('exit', () => { child = null; });

    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      if (fs.existsSync(READY_FILE)) break;
      await sleep(80);
    }
    if (!fs.existsSync(READY_FILE)) throw new Error('앱이 준비 표식을 남기지 않았습니다');

    // 초기 설정이 있으면 바로 적용한다.
    const set = {};
    if (particleCount) set.particleCount = particleCount;
    if (gridSize) set.gridSize = gridSize;
    if (preset) {
      await send({ cmd: 'preset', preset });
    }
    if (Object.keys(set).length) await send({ cmd: 'set', ...set });
    return typed(await send({ cmd: 'status' }));
  },

  async nbody_status() {
    return typed(await send({ cmd: 'status' }));
  },

  async nbody_set(args) {
    const allowed = ['particleCount', 'gridSize', 'boundary', 'law', 'gravity',
                     'softeningCells', 'timeScale', 'sortInterval', 'pressure',
                     'pressureK', 'gamma', 'temperature', 'brightness',
                     'displayGamma', 'hud', 'colormap', 'zoom', 'panX', 'panY',
                     'cooling', 'coolingRate', 'starFormation', 'starDensity', 'starTemp',
                     'expansion', 'hubble', 'renderMode', 'colorBy'];
    const kv = { cmd: 'set' };
    for (const k of allowed) if (args[k] !== undefined) kv[k] = args[k];
    if (Object.keys(kv).length === 1) throw new Error('바꿀 값이 하나도 없습니다');
    return typed(await send(kv, 30000));
  },

  async nbody_preset({ preset }) {
    return typed(await send({ cmd: 'preset', preset }, 30000));
  },

  async nbody_run({ running }) {
    return typed(await send({ cmd: 'run', running: running ? 1 : 0 }));
  },

  async nbody_step({ count = 1 }) {
    const queued = typed(await send({ cmd: 'step', count }));
    // 스텝은 프레임에 하나씩 소비된다. 앱이 남았다고 말하는 동안 기다린다.
    // 전에는 count*4ms 만 자고 성공을 돌려줬는데, 프레임이 그보다 느린 환경(무거운 격자·
    // 큰 파티클 수)에서는 대부분이 안 돈 채로 "다 됐다"가 나갔다.
    const deadline = Date.now() + Math.min(600000, 10000 + count * 80);
    let st = typed(await send({ cmd: 'status' }, 30000));
    while (st.pendingSteps > 0 && Date.now() < deadline) {
      await sleep(30);
      st = typed(await send({ cmd: 'status' }, 30000));
    }
    if (st.pendingSteps > 0)
      throw new Error(`스텝 ${count} 개 중 ${st.pendingSteps} 개가 남은 채로 시간이 지났습니다`);
    return { ...queued, ...st };
  },

  async nbody_reset() {
    return typed(await send({ cmd: 'reset' }, 30000));
  },

  async nbody_screenshot({ path: outPath }) {
    const raw = path.join(CONTROL_DIR, `shot-${Date.now()}.raw`);
    const resp = typed(await send({ cmd: 'screenshot', path: raw }));
    if (!resp.ok) throw new Error('앱이 화면을 저장하지 못했습니다');
    const png = outPath ? safeShotPath(outPath)
                        : path.join(CONTROL_DIR, `shot-${Date.now()}.png`);
    const info = rawToPng(raw, png);
    try { fs.unlinkSync(raw); } catch (_) {}
    return { ok: 1, path: png, ...info };
  },

  async nbody_tool({ tool, x, y, radius, strength, shape, count, autoOrbit }) {
    const kv = { cmd: 'tool', tool, x, y };
    if (radius !== undefined) kv.radius = radius;
    if (strength !== undefined) kv.strength = strength;
    if (shape !== undefined) kv.shape = shape;
    if (count !== undefined) kv.count = count;
    if (autoOrbit !== undefined) kv.autoOrbit = autoOrbit ? 1 : 0;
    return typed(await send(kv, 30000));
  },

  async nbody_record({ on = true, every }) {
    const kv = { cmd: 'record', on: on ? 1 : 0 };
    if (every !== undefined) kv.every = every;
    return typed(await send(kv, 30000));
  },

  async nbody_quit() {
    if (!appAlive()) return { ok: 1, note: '이미 종료되었습니다' };
    try { await send({ cmd: 'quit' }, 5000); } catch (_) {}
    await sleep(600);
    if (appAlive()) { try { child.kill(); } catch (_) {} }
    child = null;
    return { ok: 1 };
  },
};

const TOOL_SCHEMA = [
  { name: 'nbody_launch', description: '시뮬레이터를 실행하고 준비될 때까지 기다린다. 이미 떠 있으면 그대로 쓴다.',
    inputSchema: { type: 'object', properties: {
      particleCount: { type: 'integer', description: '파티클 수' },
      gridSize: { type: 'integer', enum: [1024, 2048, 4096] },
      preset: { type: 'string', enum: ['spiral', 'tidal', 'shock', 'web', 'empty'] },
    } } },
  { name: 'nbody_status', description: 'FPS·프레임 시간·파티클 수·격자·최대밀도·점유셀·총질량 등 현재 상태를 읽는다.',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'nbody_set', description: '설정 값을 바꾸고 바뀐 상태를 돌려준다.',
    inputSchema: { type: 'object', properties: {
      particleCount: { type: 'integer' }, gridSize: { type: 'integer', enum: [1024, 2048, 4096] },
      boundary: { type: 'string', enum: ['isolated', 'periodic'] },
      law: { type: 'string', enum: ['inverse_square', 'inverse_r'] },
      gravity: { type: 'number' }, softeningCells: { type: 'number' },
      timeScale: { type: 'number' }, sortInterval: { type: 'integer' },
      pressure: { type: 'integer', enum: [0, 1] }, pressureK: { type: 'number' },
      gamma: { type: 'number' }, temperature: { type: 'integer', enum: [0, 1] },
      brightness: { type: 'number' }, displayGamma: { type: 'number' },
      hud: { type: 'integer', enum: [0, 1] },
      colormap: { type: 'string', enum: ['astro', 'gray', 'thermal'] },
      zoom: { type: 'number' }, panX: { type: 'number' }, panY: { type: 'number' },
      cooling: { type: 'integer', enum: [0, 1] }, coolingRate: { type: 'number' },
      starFormation: { type: 'integer', enum: [0, 1] },
      starDensity: { type: 'number' }, starTemp: { type: 'number' },
      expansion: { type: 'integer', enum: [0, 1] }, hubble: { type: 'number' },
      renderMode: { type: 'string', enum: ['field', 'points'] },
      colorBy: { type: 'string', enum: ['density', 'temperature', 'speed'] },
    } } },
  { name: 'nbody_record', description: '앱의 녹화(PNG 시퀀스)를 켜고 끈다. captures/ 폴더에 쌓인다.',
    inputSchema: { type: 'object', properties: {
      on: { type: 'boolean' }, every: { type: 'integer', minimum: 1 } } } },
  { name: 'nbody_preset', description: '초기조건 프리셋을 바꾸고 리셋한다. 경계 조건도 시나리오에 맞게 함께 바뀐다.',
    inputSchema: { type: 'object', required: ['preset'], properties: {
      preset: { type: 'string', enum: ['spiral', 'tidal', 'shock', 'web', 'empty'] },
    } } },
  { name: 'nbody_run', description: '시뮬레이션을 재생하거나 일시정지한다.',
    inputSchema: { type: 'object', required: ['running'], properties: {
      running: { type: 'boolean' } } } },
  { name: 'nbody_step', description: '멈춘 상태에서 지정한 스텝 수만큼 진행한 뒤 상태를 돌려준다.',
    inputSchema: { type: 'object', properties: { count: { type: 'integer', minimum: 1 } } } },
  { name: 'nbody_reset', description: '현재 프리셋으로 초기 상태를 다시 만든다.',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'nbody_screenshot', description: '현재 화면을 PNG 로 저장하고 경로를 돌려준다.',
    inputSchema: { type: 'object', properties: {
      path: { type: 'string', description: '저장할 절대 경로(.png). 생략하면 제어 폴더에 만든다' } } } },
  { name: 'nbody_tool', description: '마우스 도구를 좌표로 직접 적용한다(창을 클릭하지 않고 검증할 때).',
    inputSchema: { type: 'object', required: ['tool', 'x', 'y'], properties: {
      tool: { type: 'string', enum: ['shape', 'spray', 'well', 'erase'] },
      x: { type: 'number', description: '시뮬 좌표 0~1' },
      y: { type: 'number', description: '시뮬 좌표 0~1' },
      radius: { type: 'number' }, strength: { type: 'number' },
      shape: { type: 'string', enum: ['disk', 'blob', 'ring'], description: 'tool=shape 일 때' },
      count: { type: 'integer', description: 'tool=shape 일 때 넣을 파티클 수' },
      autoOrbit: { type: 'boolean' },
    } } },
  { name: 'nbody_quit', description: '시뮬레이터를 종료한다.',
    inputSchema: { type: 'object', properties: {} } },
];

// ---------------------------------------------------------------- MCP (stdio, JSON-RPC 2.0)

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
}
function replyError(id, message) {
  process.stdout.write(JSON.stringify({
    jsonrpc: '2.0', id, error: { code: -32000, message } }) + '\n');
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    return reply(id, {
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'nbody-simulator', version: '0.1.0' },
    });
  }
  if (method === 'notifications/initialized') return;      // 알림에는 답하지 않는다
  if (method === 'tools/list') return reply(id, { tools: TOOL_SCHEMA });
  if (method === 'tools/call') {
    const fn = tools[params?.name];
    if (!fn) return replyError(id, `모르는 도구: ${params?.name}`);
    try {
      const out = await fn(params.arguments || {});
      return reply(id, { content: [{ type: 'text', text: JSON.stringify(out, null, 1) }] });
    } catch (e) {
      return reply(id, {
        content: [{ type: 'text', text: `실패: ${e.message}` }], isError: true });
    }
  }
  if (id !== undefined) replyError(id, `지원하지 않는 method: ${method}`);
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    handle(msg).catch(e => { if (msg.id !== undefined) replyError(msg.id, e.message); });
  }
});

process.on('exit', () => { if (appAlive()) { try { child.kill(); } catch (_) {} } });
