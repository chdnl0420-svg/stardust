#!/usr/bin/env node
// 1000만 파티클에서 프레임 예산(16.7ms / 60FPS)을 지키는지 실측한다.
// spec.md 「파티클 1000만 개에서 60 FPS 로 돈다」의 확인 절차.
'use strict';
const { spawn } = require('child_process');
const path = require('path');

const srv = spawn(process.execPath, [path.join(__dirname, 'server.js')],
                  { stdio: ['pipe', 'pipe', 'inherit'] });
let seq = 1; const pending = new Map(); let buf = '';
srv.stdout.setEncoding('utf8');
srv.stdout.on('data', c => {
  buf += c; let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    const r = pending.get(m.id); if (r) { pending.delete(m.id); r(m); }
  }
});
const rpc = (method, params) => new Promise((res, rej) => {
  const id = seq++; pending.set(id, res);
  srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error(method + ' 응답 없음')); } }, 120000);
});
async function call(name, args = {}) {
  const m = await rpc('tools/call', { name, arguments: args });
  const t = m.result?.content?.[0]?.text ?? '';
  if (m.result?.isError) throw new Error(`${name}: ${t}`);
  try { return JSON.parse(t); } catch { return { raw: t }; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  await rpc('initialize', {});
  console.log('=== 1000만 파티클 프레임 예산 실측 ===\n');
  await call('nbody_launch', { particleCount: 1000000, gridSize: 1024 });

  const rows = [];
  for (const [n, g] of [[1000000, 1024], [10000000, 1024], [10000000, 2048], [10000000, 4096]]) {
    await call('nbody_set', { particleCount: n, gridSize: g, gravity: 0.6, pressure: 0 });
    await call('nbody_preset', { preset: 'spiral' });
    await call('nbody_run', { running: true });
    await sleep(4000);                       // 프레임 시간이 안정될 때까지 돌린다
    const s = await call('nbody_status');
    rows.push({ n: s.particleCount, g: s.gridSize, fps: s.fps, frameMs: s.frameMs,
                stepMs: s.stepMs, sub: s.substeps, vram: s.vramFreeMB });
  }

  console.log('  N            격자    FPS      프레임ms  스텝ms  서브스텝  VRAM여유MB  판정');
  let allPass = true;
  for (const r of rows) {
    const ok = r.frameMs <= 16.7;
    if (r.n >= 10000000 && !ok) allPass = false;
    console.log(`  ${String(r.n).padStart(10)}  ${String(r.g + '^2').padStart(6)}  ` +
                `${String(r.fps).padStart(7)}  ${String(r.frameMs).padStart(8)}  ` +
                `${String(r.stepMs).padStart(6)}  ${String(r.sub).padStart(8)}  ` +
                `${String(r.vram).padStart(10)}  ${ok ? 'OK' : '초과'}`);
  }
  console.log(`\n판정: 1000만에서 16.7ms 이하 = ${allPass ? 'PASS' : 'FAIL'}`);

  const shot = await call('nbody_screenshot',
                          { path: path.join(__dirname, '..', 'build', 'bench-10m.png') });
  console.log(`스크린샷: ${shot.path}`);
  await call('nbody_quit');
  srv.stdin.end();
  process.exit(allPass ? 0 : 1);
})().catch(e => { console.error('예외:', e.message); try { srv.stdin.end(); } catch (_) {} process.exit(2); });
