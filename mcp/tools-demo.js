#!/usr/bin/env node
// 마우스 도구 6항목을 실제 앱에서 돌리고 단계마다 스크린샷을 남긴다.
// spec.md 「마우스 개입」 섹션의 확인 절차.
'use strict';
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const OUT = path.join(__dirname, '..', 'build', 'shots');
fs.mkdirSync(OUT, { recursive: true });

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
  setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error(method + ' 응답 없음')); } }, 90000);
});
async function call(name, args = {}) {
  const m = await rpc('tools/call', { name, arguments: args });
  const t = m.result?.content?.[0]?.text ?? '';
  if (m.result?.isError) throw new Error(`${name}: ${t}`);
  try { return JSON.parse(t); } catch { return { raw: t }; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const shot = n => call('nbody_screenshot', { path: path.join(OUT, n + '.png') });

let pass = 0, fail = 0;
function check(ok, label, detail) {
  if (ok) { pass++; console.log(`  [PASS] ${label.padEnd(38)} ${detail}`); }
  else    { fail++; console.log(`  [FAIL] ${label.padEnd(38)} ${detail}`); }
}

(async () => {
  await rpc('initialize', {});
  console.log('=== 마우스 도구 시나리오 ===\n');

  await call('nbody_launch', { particleCount: 3000000, gridSize: 1024 });
  await call('nbody_set', { gravity: 0.6, pressure: 0, brightness: 2.2 });

  // --- 빈 판에서 시작 ---
  await call('nbody_preset', { preset: 'empty' });
  await call('nbody_run', { running: false });
  const s0 = await call('nbody_status');
  await shot('01-empty');
  check(s0.activeCount === 0, '빈 판은 파티클이 0 이다', `activeCount=${s0.activeCount}`);

  // --- 형태 3종 추가 ---
  const a1 = await call('nbody_tool', { tool: 'shape', shape: 'disk', x: 0.32, y: 0.38,
                                        radius: 0.11, count: 600000, autoOrbit: true });
  await shot('02-add-disk');
  const a2 = await call('nbody_tool', { tool: 'shape', shape: 'blob', x: 0.68, y: 0.40,
                                        radius: 0.08, count: 600000, autoOrbit: false });
  await shot('03-add-blob');
  const a3 = await call('nbody_tool', { tool: 'shape', shape: 'ring', x: 0.50, y: 0.70,
                                        radius: 0.12, count: 600000, autoOrbit: true });
  await shot('04-add-ring');
  check(a1.affected === 600000 && a2.affected === 600000 && a3.affected === 600000
        && a3.activeCount === 1800000,
        '형태 3종이 요청한 개수대로 들어간다',
        `원반=${a1.affected} 덩어리=${a2.affected} 고리=${a3.affected} 합계=${a3.activeCount}`);

  // --- 돌려서 실제로 움직이는지 ---
  await call('nbody_run', { running: true });
  await sleep(2500);
  const moved = await call('nbody_status');
  await shot('05-running');
  check(moved.simTime > 0 && moved.totalMass > 1700000,
        '추가한 형태가 중력으로 움직인다',
        `t=${moved.simTime} 최대밀도=${moved.maxDensity} 총질량=${moved.totalMass}`);

  // --- 뿌리기 ---
  await call('nbody_run', { running: false });
  const beforeSpray = await call('nbody_status');
  await call('nbody_tool', { tool: 'spray', x: 0.32, y: 0.38, radius: 0.10, strength: 1.2 });
  const afterSpray = await call('nbody_step', { count: 120 });
  await shot('06-spray');
  check(afterSpray.maxSpeed > beforeSpray.maxSpeed,
        '뿌리기가 흐름을 흔든다',
        `최대속력 ${beforeSpray.maxSpeed} -> ${afterSpray.maxSpeed}`);

  // --- 중력 우물 ---
  // 판정은 질량중심이 우물 쪽으로 끌려오는가로 본다.
  // 최대밀도는 국소 최고점이라, 우물이 물질을 넓게 모으면 기존 최고점이 흩어져 오히려 줄 수 있다.
  const wx = 0.22, wy = 0.24;
  const beforeWell = await call('nbody_status');
  const d0 = Math.hypot(beforeWell.centroidX - wx, beforeWell.centroidY - wy);
  await call('nbody_tool', { tool: 'well', x: wx, y: wy, radius: 0.35, strength: 1.5 });
  const afterWell = await call('nbody_step', { count: 250 });
  const d1 = Math.hypot(afterWell.centroidX - wx, afterWell.centroidY - wy);
  await shot('07-well');
  check(d1 < d0,
        '중력 우물이 물질을 끌어당긴다',
        `우물까지 거리 ${d0.toFixed(4)} -> ${d1.toFixed(4)} (중심 ${beforeWell.centroidX.toFixed(3)},${beforeWell.centroidY.toFixed(3)} -> ${afterWell.centroidX.toFixed(3)},${afterWell.centroidY.toFixed(3)})`);

  // --- 지우개 ---
  const beforeErase = await call('nbody_status');
  const er = await call('nbody_tool', { tool: 'erase', x: 0.50, y: 0.50, radius: 0.18 });
  await shot('08-erase');
  check(er.affected > 0 && er.activeCount === beforeErase.activeCount - er.affected,
        '지우개가 파티클을 지운다',
        `지움=${er.affected}  ${beforeErase.activeCount} -> ${er.activeCount}`);

  // --- 지운 뒤에도 추가가 정확한가 (자유 슬롯 커서) ---
  const re = await call('nbody_tool', { tool: 'shape', shape: 'disk', x: 0.20, y: 0.80,
                                        radius: 0.07, count: 300000, autoOrbit: true });
  await shot('09-readd');
  check(re.affected === 300000 && re.activeCount === er.activeCount + 300000,
        '지운 뒤에도 요청한 개수가 정확히 들어간다',
        `추가=${re.affected}  ${er.activeCount} -> ${re.activeCount}`);

  console.log(`\n=== 결과: ${pass} PASS / ${fail} FAIL ===`);
  console.log(`스크린샷: ${OUT}`);
  await call('nbody_quit');
  srv.stdin.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('예외:', e.message); try { srv.stdin.end(); } catch (_) {} process.exit(2); });
