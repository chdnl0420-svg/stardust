#!/usr/bin/env node
// round-05 검증 — 가스(충격파·온도색·냉각·별형성)·우주 팽창·표시(점 렌더·색 기준)·녹화.
'use strict';
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const OUT = path.join(__dirname, '..', 'build', 'shots5');
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
// 화면을 남기면서 그때의 상태도 함께 받는다 — 그림만 저장하고 통과시키면 회귀를 못 잡는다.
const shotAndStatus = async n => { await shot(n); return call('nbody_status'); };
let pass = 0, fail = 0;
function check(ok, label, detail) {
  if (ok) { pass++; console.log(`  [PASS] ${label.padEnd(36)} ${detail}`); }
  else    { fail++; console.log(`  [FAIL] ${label.padEnd(36)} ${detail}`); }
}

(async () => {
  await rpc('initialize', {});
  console.log('=== round-05 가스·우주·표시·녹화 ===\n');
  await call('nbody_launch', { particleCount: 2000000, gridSize: 1024 });

  // ---- 표시: 점 렌더 / 색 기준 ----
  console.log('[표시]');
  await call('nbody_preset', { preset: 'spiral' });
  await call('nbody_set', { gravity: 0.6, brightness: 2.0 });
  await call('nbody_run', { running: true }); await sleep(1500);
  await call('nbody_run', { running: false });

  const f = await call('nbody_set', { renderMode: 'field', colorBy: 'density' });
  await shot('01-field-density');
  const p = await call('nbody_set', { renderMode: 'points', colorBy: 'density' });
  await shot('02-points-density');
  check(f.renderMode === 'field' && p.renderMode === 'points',
        '밀도 필드 ↔ 파티클 점 전환', `${f.renderMode} -> ${p.renderMode}`);

  const cT = await call('nbody_set', { renderMode: 'points', colorBy: 'temperature', colormap: 'thermal' });
  await shot('03-points-temperature');
  const cS = await call('nbody_set', { colorBy: 'speed', colormap: 'astro' });
  await shot('04-points-speed');
  await call('nbody_set', { colorBy: 'density' });
  check(cT.colorBy === 'temperature' && cS.colorBy === 'speed',
        '색 기준 밀도/온도/속도 전환', `${cT.colorBy}, ${cS.colorBy}`);

  // ---- 가스: 충격파 ----
  console.log('\n[가스]');
  await call('nbody_set', { renderMode: 'field', colorBy: 'density', colormap: 'astro',
                            brightness: 1.5, temperature: 1 });
  await call('nbody_set', { pressureK: 0.0 });
  await call('nbody_preset', { preset: 'shock' });
  await call('nbody_run', { running: false });
  const noP = await call('nbody_step', { count: 900 });
  await shot('05-shock-nopressure');

  await call('nbody_set', { pressureK: 1.2, pressure: 1 });
  await call('nbody_preset', { preset: 'shock' });
  await call('nbody_run', { running: false });
  const withP = await call('nbody_step', { count: 900 });
  await shot('06-shock-pressure');
  check(withP.maxDensity < noP.maxDensity,
        '압력이 충돌면에서 밀도를 떠받친다',
        `압력off 최대밀도=${noP.maxDensity}  압력on=${withP.maxDensity}`);

  // 온도: 충돌하면 달아오른다
  await call('nbody_set', { colorBy: 'temperature', colormap: 'thermal', brightness: 1.0 });
  const tempSt = await shotAndStatus('07-shock-temperature');
  // 전에는 check(true, ...) 로 무조건 통과시켜 온도가 0 이 돼도 못 잡았다(round-06 리뷰 P2 #38).
  check(tempSt.meanTemp > 0.01 && tempSt.colorBy === 'temperature',
        '충돌면이 실제로 달아오른다',
        `평균온도=${tempSt.meanTemp}  색기준=${tempSt.colorBy}  shots5/07-shock-temperature.png`);

  // ---- 가스: 복사 냉각 ----
  const runCool = async (on) => {
    await call('nbody_set', { pressure: 1, pressureK: 1.2, temperature: 1,
                              cooling: on ? 1 : 0, coolingRate: 0.9 });
    await call('nbody_preset', { preset: 'shock' });
    await call('nbody_run', { running: false });
    return call('nbody_step', { count: 700 });
  };
  const coolOff = await runCool(false);
  const coolOn  = await runCool(true);
  await shot('08-cooling-on');
  // 냉각의 1차 효과는 온도 감소다. 밀도·점유셀 변화는 2차라 경계·CFL 효과에 묻혀
  // 방향이 뒤집히기도 한다(실측: 최대밀도로도 점유셀로도 못 갈랐다). 온도를 직접 본다.
  check(coolOn.meanTemp < coolOff.meanTemp * 0.5,
        '냉각을 켜면 가스가 식는다',
        `평균온도 냉각off=${coolOff.meanTemp}  on=${coolOn.meanTemp}`);

  // ---- 가스: 별 형성 ----
  await call('nbody_set', { starFormation: 1, starDensity: 40, starTemp: 0.5,
                            cooling: 1, coolingRate: 0.9 });
  await call('nbody_preset', { preset: 'shock' });
  await call('nbody_run', { running: false });
  const stars = await call('nbody_step', { count: 900 });
  await shot('09-star-formation');
  check(stars.starCount > 0,
        '조밀·차가운 가스가 별로 바뀐다',
        `별 ${stars.starCount} 개 / 파티클 ${stars.activeCount}`);
  await call('nbody_set', { starFormation: 0, cooling: 0 });

  // ---- 우주 팽창 ----
  console.log('\n[우주]');
  const runWeb = async (expansion) => {
    await call('nbody_set', { pressure: 0, expansion: expansion ? 1 : 0, hubble: 0.5,
                              colorBy: 'density', colormap: 'astro', brightness: 1.5 });
    await call('nbody_preset', { preset: 'web' });
    // 프리셋이 팽창을 끄므로 리셋 뒤에 다시 켠다
    await call('nbody_set', { expansion: expansion ? 1 : 0, hubble: 0.5 });
    await call('nbody_run', { running: false });
    return call('nbody_step', { count: 1200 });
  };
  const noExp = await runWeb(false);
  await shot('10-web-noexpansion');
  const withExp = await runWeb(true);
  await shot('11-web-expansion');
  // 팽창은 물질이 뭉치는 것을 늦추므로 아직 넓게 퍼져 있어야 한다 = 점유 칸이 더 많다.
  check(withExp.occupiedCells > noExp.occupiedCells,
        '팽창이 구조 형성을 늦춘다',
        `팽창off 점유셀=${noExp.occupiedCells}  on=${withExp.occupiedCells} (최대밀도 ${noExp.maxDensity} / ${withExp.maxDensity})`);

  // ---- 녹화 ----
  console.log('\n[녹화]');
  const capDir = path.join(__dirname, '..', 'build', 'Release', 'captures');
  // 이전 실행이 남긴 파일과 섞이지 않게 지우고 시작한다.
  if (fs.existsSync(capDir))
    for (const f of fs.readdirSync(capDir)) if (f.startsWith('rec-')) fs.unlinkSync(path.join(capDir, f));
  await call('nbody_run', { running: true });
  await call('nbody_record', { on: true, every: 1 });
  await sleep(2000);
  const recSt = await call('nbody_record', { on: false });
  const files = fs.existsSync(capDir) ? fs.readdirSync(capDir).filter(f => f.startsWith('rec-')) : [];
  const size = files.length ? fs.statSync(path.join(capDir, files[0])).size : 0;
  check(recSt.recordedFrames > 0 && files.length === recSt.recordedFrames && size > 10000,
        '녹화가 PNG 시퀀스를 남긴다',
        `프레임=${recSt.recordedFrames}  파일=${files.length}개  첫 파일 ${(size / 1024).toFixed(0)}KB`);

  console.log(`\n=== 결과: ${pass} PASS / ${fail} FAIL ===`);
  console.log(`스크린샷: ${OUT}`);
  await call('nbody_quit');
  srv.stdin.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('예외:', e.message); try { srv.stdin.end(); } catch (_) {} process.exit(2); });
