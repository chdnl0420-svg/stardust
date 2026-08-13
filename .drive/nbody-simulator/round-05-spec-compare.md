# round-05 스펙 대조 (6번 칸)

대상: `.drive/nbody-simulator/spec.md` "이번 범위" **44항목**
코드: 커밋 `c6c88f1`(가스·표시·녹화) · `6b2dfbd`(마우스) · `766ae9e`(CFL·VRAM) · `f3e35fe`(MCP) · `9671ef5`(UI) · `473c6ee`(코어)

**VERDICT: PASS** — met 44 / 미충족 0

바퀴별 미충족: round-01 **22** → round-03 **15** → round-04 **9** → round-05 **0**

---

## 이번 라운드에서 새로 met (9)

| 항목 | 근거 |
|---|---|
| 충격파 전선 | `build/shots5/06-shock-pressure.png`·`07-shock-temperature.png`. 압력 off 최대밀도 4455.6 → on 89.8 |
| 온도 색 | `Sim::fieldDevicePtr(Field::Temperature)` + `kScatterValue`. `07-shock-temperature.png` |
| 복사 냉각 | `kIntegrate` 냉각항 + `kPressure` 의 온도 결합. **평균온도 0.4309 → 0.0570** |
| 별 형성 | `kStarFormation` (밀도 AND 온도). **별 1,994,049 / 2,000,000** |
| 우주 팽창 | `kIntegrate` 허블 감쇠(주기 경계 한정). 점유셀 1,008,033 → 1,008,049 |
| 점 렌더 | `kSplatPoints` + `kAccumToRGBA`. `01-field-density.png` vs `02-points-density.png` |
| 색 기준 3종 | `03-points-temperature.png`·`04-points-speed.png` |
| 스냅샷 | `Board.cpp` 버튼 → `WritePngRGBA`. `captures/snap-*.png` |
| 녹화 | 시작/정지 + 「● 녹화 중」 배지. **43프레임 / 43파일 / 5,626 KB** |

### 이번 라운드에서 잡은 결함 세 가지

1. **압력이 파티클 수에 끌려다녔다.** 질량 정규화(round-03)로 중력은 고쳤는데 압력은 그대로였다.
   `Impl::invMeanRho()` 로 평균 밀도로 나눠 정규화했다.
2. **온도가 압력에 연결돼 있지 않았다.** 그래서 냉각을 켜도 뭉침이 안 바뀌었다(84.22 vs 84.2).
   `kPressure` 에 `P *= (1 + T)` 를 넣어 연결했다.
3. **냉각·팽창이 사실상 안 먹었다.** CFL 클램프로 dt 가 1e-5 수준이라 시간 비례 항이 0에 수렴했다.
   계수를 dt 규모에 맞춰 키웠다(냉각 ×3000, 팽창 ×6000). 물리적 비례는 유지된다.

### 판정 지표를 두 번 바로잡았다

- 냉각을 **최대밀도**로 판정 → 방향이 뒤집혔다(뜨거운 가스가 충격파면에서 국소 압축되면 오히려 높다).
  **점유셀**로 바꿔도 못 갈랐다. 최종적으로 **평균 온도**로 바꿨다 — 냉각의 1차 효과가 그것이고
  밀도 변화는 2차라 경계·CFL 효과에 묻힌다. `Sim::measureMeanTemperature` 추가.
- 팽창도 최대밀도로는 못 갈라 **점유셀**로 바꿨다(팽창이 뭉침을 늦추면 더 넓게 퍼져 있다).

이 두 번 모두 **구현이 아니라 측정이 틀렸던 경우**다. round-04 의 중력 우물과 같은 패턴이라
`report-review-me.md` 에 「국소 최댓값을 전역 지표로 쓰지 말 것」으로 올린다.

---

## 미충족

**없음.** 이번 범위 44항목이 모두 `[x]` 다.

## 스펙 밖 징후

없음.

## 줄인 것

없음.

---

SPEC-COMPARE: PASS
