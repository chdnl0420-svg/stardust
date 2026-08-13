#!/usr/bin/env node
// MCP 서버 회귀 테스트 — server.js 를 실제 stdio 로 띄워 앱을 조종해 본다.
// 앱 창이 실제로 뜨고, 설정 변경이 반영되고, 화면이 PNG 로 저장되는지까지 확인한다.
'use strict';
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const srv = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
  stdio: ['pipe', 'pipe', 'inherit'],
});

let seq = 1;
const pending = new Map();
let buf = '';

srv.stdout.setEncoding('utf8');
srv.stdout.on('data', chunk => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    const r = pending.get(msg.id);
    if (r) { pending.delete(msg.id); r(msg); }
  }
});

function rpc(method, params) {
  const id = seq++;
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`${method} 응답 없음`)); } }, 60000);
  });
}

async function call(name, args = {}) {
  const m = await rpc('tools/call', { name, arguments: args });
  const text = m.result?.content?.[0]?.text ?? '';
  if (m.result?.isError) throw new Error(`${name}: ${text}`);
  try { return JSON.parse(text); } catch { return { raw: text }; }
}

let pass = 0, fail = 0;
function check(ok, label, detail) {
  if (ok) { pass++; console.log(`  [PASS] ${label.padEnd(40)} ${detail}`); }
  else    { fail++; console.log(`  [FAIL] ${label.padEnd(40)} ${detail}`); }
}

(async () => {
  console.log('=== nbody MCP 회귀 테스트 ===\n');

  const init = await rpc('initialize', {});
  check(init.result?.serverInfo?.name === 'nbody-simulator', 'initialize 응답',
        `serverInfo=${JSON.stringify(init.result?.serverInfo)}`);

  const list = await rpc('tools/list', {});
  const names = (list.result?.tools || []).map(t => t.name);
  check(names.length >= 9, 'tools/list 가 도구를 노출한다', `${names.length}개: ${names.join(', ')}`);

  console.log('\n[1] 앱 실행');
  const st0 = await call('nbody_launch', { particleCount: 500000, gridSize: 1024 });
  check(st0.ok === 1 && st0.particleCount === 500000,
        '실행 후 상태 조회가 응답한다',
        `particleCount=${st0.particleCount} grid=${st0.gridSize} boundary=${st0.boundary}`);

  console.log('\n[2] 설정 변경이 반영된다');
  const before = await call('nbody_status');
  const after = await call('nbody_set', { gravity: 1.4, sortInterval: 12, colormap: 'thermal' });
  check(Math.abs(after.gravity - 1.4) < 1e-3 && after.sortInterval === 12,
        '중력·정렬주기 변경 반영',
        `gravity ${before.gravity} -> ${after.gravity}, sortInterval ${before.sortInterval} -> ${after.sortInterval}`);

  const g2 = await call('nbody_set', { particleCount: 2000000, gridSize: 2048 });
  check(g2.particleCount === 2000000 && g2.gridSize === 2048,
        '파티클 수·격자 재할당 반영',
        `N=${g2.particleCount} G=${g2.gridSize} 총질량=${g2.totalMass}`);

  console.log('\n[3] 프리셋 전환');
  const web = await call('nbody_preset', { preset: 'web' });
  check(web.preset === 'web' && web.boundary === 'periodic',
        '구조형성 프리셋이 주기 경계로 함께 바뀐다',
        `preset=${web.preset} boundary=${web.boundary} 점유셀=${web.occupiedCells}`);

  const spiral = await call('nbody_preset', { preset: 'spiral' });
  check(spiral.preset === 'spiral' && spiral.boundary === 'isolated',
        '나선팔 프리셋이 고립 경계로 돌아온다',
        `preset=${spiral.preset} boundary=${spiral.boundary} 점유셀=${spiral.occupiedCells}`);

  console.log('\n[3-b] 프리셋이 경계·압력·팽창을 함께 바꾼다');
  await call('nbody_set', { pressure: 1, gravity: 0.6 });
  const pSpiral = await call('nbody_preset', { preset: 'spiral' });
  const pShock  = await call('nbody_preset', { preset: 'shock' });
  const pWeb    = await call('nbody_preset', { preset: 'web' });
  check(pSpiral.pressure === 0 && pShock.pressure === 1,
        '충격파만 압력이 켜진다',
        `나선팔 pressure=${pSpiral.pressure}, 충격파 pressure=${pShock.pressure}`);
  check(pWeb.boundary === 'periodic' && pWeb.expansion === 0 && pShock.boundary === 'isolated',
        '경계와 팽창도 시나리오에 맞게 바뀐다',
        `구조형성 boundary=${pWeb.boundary} expansion=${pWeb.expansion}, 충격파 boundary=${pShock.boundary}`);

  console.log('\n[3-c] CFL 클램프가 강한 중력에서 작동한다');
  await call('nbody_set', { gravity: 2.0, pressure: 0, particleCount: 500000, gridSize: 1024 });
  await call('nbody_preset', { preset: 'spiral' });
  await call('nbody_run', { running: false });
  const cfl = await call('nbody_step', { count: 300 });
  check(cfl.dtUsed > 0 && cfl.maxSpeed < 1000,
        '시간 간격이 잘리고 속도가 폭주하지 않는다',
        `dtUsed=${cfl.dtUsed} 최대속력=${cfl.maxSpeed} 서브스텝=${cfl.substeps} 총질량=${cfl.totalMass}`);

  console.log('\n[4] 스텝 제어 — 멈춘 상태에서 진행');
  await call('nbody_run', { running: false });
  const s1 = await call('nbody_status');
  const s2 = await call('nbody_step', { count: 120 });
  check(s2.simTime > s1.simTime, '스텝 진행으로 시각이 나아간다',
        `t ${s1.simTime} -> ${s2.simTime}, 최대밀도 ${s1.maxDensity} -> ${s2.maxDensity}`);

  console.log('\n[5] 중력이 실제로 물리를 바꾼다 (MCP 로 확인)');
  // 순서가 중요하다: 중력을 먼저 정하고 나서 프리셋으로 리셋해야 한다.
  // 리셋 시점의 중력을 재서 궤도 속도를 넣기 때문에, 리셋 뒤에 중력을 바꾸면
  // 궤도 속도만 남아 파티클이 판 밖으로 날아가 경계에 쌓인다(실측: 최대밀도 41만).
  await call('nbody_set', { gravity: 0.0, pressure: 0, particleCount: 500000, gridSize: 1024 });
  await call('nbody_preset', { preset: 'spiral' });
  await call('nbody_run', { running: false });
  const off = await call('nbody_step', { count: 200 });

  await call('nbody_set', { gravity: 0.8, pressure: 0 });
  await call('nbody_preset', { preset: 'spiral' });
  await call('nbody_run', { running: false });
  const on = await call('nbody_step', { count: 200 });
  check(on.maxDensity > off.maxDensity * 1.5, '중력을 켜면 더 뭉친다',
        `중력0 최대밀도=${off.maxDensity}  중력0.8 최대밀도=${on.maxDensity}`);

  console.log('\n[6] 화면 캡처');
  const shotPath = path.join(__dirname, '..', 'build', 'mcp-shot.png');
  const shot = await call('nbody_screenshot', { path: shotPath });
  const exists = fs.existsSync(shot.path);
  const size = exists ? fs.statSync(shot.path).size : 0;
  check(exists && size > 2000, 'PNG 파일이 저장된다',
        `${shot.width}x${shot.height}, ${(size / 1024).toFixed(0)} KB, ${shot.path}`);

  console.log('\n[7] 종료');
  const q = await call('nbody_quit');
  check(q.ok === 1, '앱이 종료된다', JSON.stringify(q));

  console.log(`\n=== 결과: ${pass} PASS / ${fail} FAIL ===`);
  srv.stdin.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => {
  console.error('\n예외:', e.message);
  try { srv.stdin.end(); } catch (_) {}
  process.exit(2);
});
