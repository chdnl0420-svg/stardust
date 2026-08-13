#!/usr/bin/env node
// 제어 채널(ControlBridge) 경로 회귀 테스트.
//
// 왜 따로 있나: tests/sim_tests.cpp 는 Sim 을 직접 부르므로 설정 보드·제어 채널을 안 탄다.
// round-06 리뷰에서 나온 결함(설정이 app.cfg 에만 남고 코어에 안 가던 것)은 바로 그 구간에 있었고,
// 코어 테스트 24건이 전부 통과하는 동안 아무도 못 잡았다.
//
// 판정 지표는 ControlBridge::statusBody 가 실제로 내보내는 이름만 쓴다
// (round-06 에서 steps·msFrame·gridMass 같은 없는 이름을 지어내 4항목을 오판했다).
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
let pass = 0, fail = 0;
function check(ok, label, detail) {
  if (ok) { pass++; console.log(`  [PASS] ${label}\n         ${detail}`); }
  else    { fail++; console.log(`  [FAIL] ${label}\n         ${detail}`); }
}

(async () => {
  await rpc('initialize', {});
  console.log('=== 제어 채널 경로 회귀 테스트 ===\n');
  // 격자는 1024·2048·4096 만 받는다(ControlBridge 가 그 밖의 값을 무시한다).
  await call('nbody_launch', { particleCount: 1000000, gridSize: 1024 });

  // ---- 1. set 단독으로 바꾼 중력이 실제 계산에 닿는가 ----
  //   프리셋 명령은 자기 안에서 코어 반영을 하므로, 그것을 거치지 않고 set + reset 만으로 본다.
  //
  //   지표는 최대밀도가 아니라 최대속력이다. 밀도로 보면 CFL 클램프가 강한 중력에서 시간 간격을
  //   줄여 "같은 스텝 수 = 더 짧은 물리 시간"이 되고, 두 조건이 비슷한 밀도에 도달해 차이가 지워진다
  //   (round-06 QA-3 실측: 400스텝에서 g=0.2 와 g=1.8 이 똑같이 453.76).
  //   회전 프리셋은 리셋할 때 그 중력에 맞는 궤도 속도를 넣으므로, 속력은 중력이 코어에 닿았는지를
  //   CFL 과 무관하게 바로 보여준다.
  console.log('[1] set 단독 변경이 코어에 닿는다');
  await call('nbody_preset', { preset: 'spiral' });   // 여기서 초기조건이 잡힌다
  await call('nbody_set', { gravity: 0.2, pressure: 0 });
  await call('nbody_reset');
  await call('nbody_run', { running: false });
  const gLo = await call('nbody_step', { count: 5 });

  await call('nbody_set', { gravity: 1.8 });          // 프리셋을 안 거치는 단독 변경
  await call('nbody_reset');
  const gHi = await call('nbody_step', { count: 5 });
  // 궤도 속도는 중력의 제곱근에 비례한다 — 9배 중력이면 약 3배.
  check(gHi.maxSpeed > gLo.maxSpeed * 2.0,
        '중력을 set 만으로 바꿔도 물리가 달라진다',
        `최대속력 g=0.2 -> ${gLo.maxSpeed} / g=1.8 -> ${gHi.maxSpeed} ` +
        `(${(gHi.maxSpeed / (gLo.maxSpeed || 1)).toFixed(2)}배, 이론 3배)`);

  // ---- 2. 시간 배속을 내리면 시간 간격이 실제로 줄어든다 ----
  console.log('\n[2] 시간 배속이 시간 간격에 반영된다');
  const dtFor = async (ts) => {
    await call('nbody_set', { gravity: 0.8, timeScale: ts });
    await call('nbody_reset');
    await call('nbody_run', { running: false });
    return call('nbody_step', { count: 200 });
  };
  const norm = await dtFor(1.0);
  const slow = await dtFor(0.25);
  check(slow.dtUsed < norm.dtUsed * 0.5,
        '배속 0.25 는 1.0 보다 시간 간격이 작다',
        `dtUsed 1.0x=${norm.dtUsed}  0.25x=${slow.dtUsed} (simTime ${norm.simTime} vs ${slow.simTime})`);

  // ---- 3. 배속 > 1 은 한 프레임에 스텝을 여러 번 돌려서 낸다 ----
  //   지표는 프레임당 스텝 수다. 벽시계 시간당 진행량으로 보면 안 된다 —
  //   한 프레임에 3스텝을 돌면 그 프레임이 3배 오래 걸려 초당 프레임 수가 1/3 로 줄고,
  //   둘이 상쇄돼 총 진행량이 거의 그대로다(실측: 1.5초 동안 1.0x=0.012930 / 3.0x=0.015830, 1.22배).
  //   이건 배속이 안 먹은 게 아니라 GPU 가 이미 스텝 계산으로 포화라서 나오는 물리적 한계다.
  console.log('\n[3] 배속을 올리면 한 프레임에 여러 스텝을 돈다');
  const stepsPerFrameAt = async (ts) => {
    await call('nbody_set', { gravity: 0.8, timeScale: ts });
    await call('nbody_run', { running: true });
    await sleep(700);                       // 재생 상태의 프레임을 몇 개 지나 보낸다
    const st = await call('nbody_status');
    await call('nbody_run', { running: false });
    return st.stepsPerFrame;
  };
  const spf1 = await stepsPerFrameAt(1.0);
  const spf3 = await stepsPerFrameAt(3.0);
  check(spf1 === 1 && spf3 === 3,
        '배속 3.0 이면 프레임당 3스텝을 돈다',
        `프레임당 스텝  1.0x=${spf1}  3.0x=${spf3}`);
  await call('nbody_set', { timeScale: 1.0 });

  // ---- 4. 표시 설정을 상태로 되읽을 수 있다 ----
  console.log('\n[4] 표시 설정이 상태에 나온다');
  const st = await call('nbody_set', {
    colormap: 'gray', brightness: 0.4, displayGamma: 2.2, hud: 0,
    zoom: 3.0, panX: 0.25, panY: -0.1, renderMode: 'points', colorBy: 'speed' });
  const missing = ['colormap', 'brightness', 'displayGamma', 'hud', 'zoom', 'panX', 'panY']
                    .filter(k => st[k] === undefined);
  check(missing.length === 0 && st.colormap === 'gray' && st.brightness === 0.4 &&
        st.hud === 0 && st.zoom === 3,
        '컬러맵·밝기·대비·HUD·줌팬을 되읽을 수 있다',
        missing.length ? `없는 필드: ${missing.join(', ')}`
                       : `colormap=${st.colormap} brightness=${st.brightness} ` +
                         `displayGamma=${st.displayGamma} hud=${st.hud} zoom=${st.zoom} ` +
                         `panX=${st.panX} panY=${st.panY}`);
  await call('nbody_set', { colormap: 'astro', brightness: 2.0, displayGamma: 1.6, hud: 1,
                            zoom: 1.0, panX: 0, panY: 0, renderMode: 'field', colorBy: 'density' });

  // ---- 5. 프리셋 전환이 옛 초기조건을 남기지 않는다 ----
  //   보드 버튼과 같은 규칙(ApplyPresetDefaults -> 코어 반영 -> reset)을 제어 채널로 확인한다.
  //   지표로 점유셀을 쓰면 안 된다 — 프리셋마다 경계 조건이 달라 격자 크기 자체가 바뀌므로
  //   (고립은 패딩으로 폭이 2배) 두 수를 나란히 놓을 수 없다.
  //   빈 판은 살아 있는 파티클이 0 개라, 배치가 실제로 다시 만들어졌는지를 애매함 없이 보여준다.
  console.log('\n[5] 프리셋을 바꾸면 그 프리셋으로 배치된다');
  await call('nbody_set', { gravity: 0.8 });
  const web    = await call('nbody_preset', { preset: 'web' });
  const empty  = await call('nbody_preset', { preset: 'empty' });
  const spiral = await call('nbody_preset', { preset: 'spiral' });
  check(web.boundary === 'periodic' && spiral.boundary === 'isolated' &&
        empty.activeCount === 0 && spiral.activeCount === 1000000,
        '프리셋을 바꾸면 경계와 배치가 함께 바뀐다',
        `web=${web.boundary}/${web.activeCount}개, empty=${empty.boundary}/${empty.activeCount}개, ` +
        `spiral=${spiral.boundary}/${spiral.activeCount}개`);

  // ---- 6. 제어 채널이 명령 주입과 범위 밖 경로를 막는다 ----
  //   명령은 "key=value" 줄로 나가므로 값에 줄바꿈이 들어가면 그 자리가 새 명령이 된다.
  //   스크린샷 경로는 서버 권한으로 쓰이므로 아무 파일이나 덮어쓸 수 있으면 안 된다.
  console.log('\n[6] 명령 주입과 범위 밖 경로를 막는다');
  let injectBlocked = false, pathBlocked = false, outsideBlocked = false;
  try { await call('nbody_preset', { preset: 'spiral\ncmd=quit' }); }
  catch (e) { injectBlocked = /줄바꿈/.test(e.message); }
  try { await call('nbody_screenshot', { path: 'C:\\Windows\\System32\\drivers\\etc\\hosts' }); }
  catch (e) { pathBlocked = /\.png/.test(e.message); }
  try { await call('nbody_screenshot', { path: 'C:\\Windows\\Temp\\nbody-escape.png' }); }
  catch (e) { outsideBlocked = /허용된 폴더/.test(e.message); }
  // 주입이 통했다면 앱이 종료됐을 것이다 — 상태를 읽어 살아 있는지 함께 본다.
  const alive = await call('nbody_status');
  check(injectBlocked && pathBlocked && outsideBlocked && alive.ok === 1,
        '줄바꿈 주입·확장자·폴더 범위를 모두 거부한다',
        `주입차단=${injectBlocked} 확장자차단=${pathBlocked} 폴더차단=${outsideBlocked} 앱생존=${alive.ok === 1}`);

  // ---- 7. 동시 호출이 서로를 덮어쓰지 않는다 ----
  //   명령 파일과 응답 파일이 하나씩뿐이라 겹치면 남의 응답을 읽거나 둘 다 타임아웃한다.
  console.log('\n[7] 동시 호출이 뒤섞이지 않는다');
  const many = await Promise.all([
    call('nbody_status'), call('nbody_status'), call('nbody_status'),
    call('nbody_set', { gravity: 0.7 }), call('nbody_status'),
    call('nbody_set', { gravity: 0.9 }), call('nbody_status'),
  ]);
  const allOk = many.every(m => m && m.ok === 1 && typeof m.activeCount === 'number');
  check(allOk, '동시에 보낸 7개 명령이 모두 제 응답을 받는다',
        `ok 응답 ${many.filter(m => m && m.ok === 1).length}/7, 마지막 gravity=${many[6].gravity}`);

  console.log(`\n=== 결과: ${pass} PASS / ${fail} FAIL ===`);
  await call('nbody_quit');
  srv.stdin.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => {
  console.error('예외:', e.message);
  try { srv.stdin.end(); } catch (_) {}
  process.exit(2);
});
