#pragma once
#include <cmath>

// 보는 방향(우클릭 드래그로 판을 돌려 보는 것).
//
// ── 왜 각도 둘이 아니라 행렬인가 (2026-08-18) ────────────────────────────────
//
// 전에는 좌우 각(yaw)과 위아래 각(pitch) 두 숫자로 방향을 정했다. 그 방식은 위아래 각이
// 90도를 지날 때 **반드시** 무너진다 — `cos(90°) = 0` 이라 화면 세로가 한 점으로 눌렸다가
// 넘어가면 상하가 뒤집힌 채 다시 펴진다(짐벌락). 사용자 보고:
//   · 「특정 각도까지 회전하면 락돼버려」  ← ±89도에서 세워 두었을 때
//   · 「일정 각도만큼 움직이면 갑자기 180도 뒤집혀」  ← 그 제한을 풀었을 때
// 둘은 같은 원인의 앞뒷면이고, **값을 조정해서는 못 고친다.**
//
// 그래서 방향을 **회전 행렬 하나로 통째로** 들고 다니고, 마우스가 움직인 만큼 **지금 보고
// 있는 화면의 가로축·세로축을 기준으로** 돌린다(arcball). 화면 기준이라 어느 방향으로
// 아무리 돌려도 뭉개지는 축이 없다.
//
// ── 왜 헤더인가 ──────────────────────────────────────────────────────────────
//
// 이 판을 그리는 곳이 둘이다 — 격자 렌더(`Sim.cu`)와 점 렌더(`RenderField.cu`).
// 회전 계산이 `Sim.cu` 안에만 있어서 **점 렌더는 회전을 아예 못 받았고**, 배율이 조금만
// 커도 화면이 통째로 점 렌더가 되므로 우클릭이 아무 일도 하지 않았다.

struct ViewRot {
    // 행 우선 3×3. 각 행이 화면의 축이다 — 첫 행이 가로, 둘째가 세로, **셋째가 깊이**다.
    // 궤도 모드(직교 투영)는 앞 둘만 쓰고, 자유 비행 모드(원근)는 셋째도 쓴다.
    float m[9];
    // **회전의 축이 되는 점 — 화면 한가운데에 놓인 판 좌표다.**
    //
    // 여태 판의 한가운데(0.5, 0.5, 0.5)를 고정 축으로 썼다. 그러면 화면을 끌어 옮긴 뒤
    // (pan) 돌릴 때 **축이 화면 밖에 있어** 보던 자리가 크게 휩쓸려 나간다. 사용자 요청:
    // 「회전할때 카메라 기준 가운데가 회전돼야해」.
    //
    // 화면 좌표는 `u = (px - 0.5 + panX)·zoom + 0.5` 이므로, 화면 한가운데(u = 0.5)에
    // 오는 판 좌표는 `px = 0.5 - panX` 다. 그 점을 축으로 삼는다.
    // 궤도 모드에서는 **회전축**(위 설명), 자유 비행 모드에서는 **카메라가 있는 자리**다.
    // 둘 다 「이 점을 원점으로 옮겨 놓고 화면 축에 투영한다」는 같은 일을 하므로 자리를
    // 나눠 쓴다.
    float cx, cy, cz;
    int   on;
    // 1 이면 원근 투영(자유 비행). 0 이면 직교(궤도).
    int   fly;
    // 세로 시야각의 절반의 탄젠트. 원근에서 화면 크기를 정한다.
    float tanHalfFov;
};

// 판 안의 한 점을 돌려 화면 좌표로 옮긴다. 판 밖으로 나가면 false.
//
// 판은 정육면체라 비스듬히 보면 대각선이 한 변의 1.73배가 되어 모서리가 화면을 벗어난다.
// 줄여서 다 담으면 똑바로 볼 때보다 작아 보이므로, 여기서는 자르고 확대·축소는 사용자에게
// 맡긴다 — 알갱이는 대개 가운데 모여 있어 잘리는 것은 빈 모서리다.
//
// **`__device__` 는 CUDA 컴파일러(nvcc)만 아는 낱말이다.** 이 헤더는 마우스 처리(`main.cpp`)
// 와 제어 채널(`ControlBridge.cpp`) 같은 보통 C++ 파일도 읽으므로, 거기서는 이 함수를
// 아예 안 보이게 접는다 — 그쪽은 아래 호스트 도구들만 쓴다.
#ifdef __CUDACC__
__device__ inline bool rotPoint(float px, float py, float pz, const ViewRot& r,
                                float& ox, float& oy) {
    // 축을 원점으로 옮겨 돌린 뒤 **화면 한가운데(0.5)** 로 놓는다. 그래야 그 축이
    // 언제나 화면 정중앙에 오고, 돌려도 보던 자리가 제자리에 남는다.
    const float fx = px - r.cx, fy = py - r.cy, fz = pz - r.cz;
    ox = r.m[0] * fx + r.m[1] * fy + r.m[2] * fz + 0.5f;
    oy = r.m[3] * fx + r.m[4] * fy + r.m[5] * fz + 0.5f;
    return (ox >= 0.f && ox < 1.f && oy >= 0.f && oy < 1.f);
}

// 점 렌더 전용 투영. 궤도(직교)와 자유 비행(원근)을 한 함수로 가른다.
//
// **`rotPoint` 와 나눠 둔 이유**: 그쪽은 격자 렌더가 쓰고 판 밖을 잘라내야 하는데,
// 원근에서는 화면 밖 판정 기준이 달라서(깊이가 있다) 같은 함수로 묶을 수 없다.
//
// 돌려주는 값은 **화면 좌표 [0,1]²** 다 — 궤도 모드는 확대·이동을 호출부가 마저 하고,
// 원근 모드는 여기서 이미 다 끝난다(원근은 거리로 나누는 순간 배율이 정해진다).
// `depth` 는 카메라에서의 앞쪽 거리로, 알갱이를 몇 픽셀로 그릴지 정하는 데 쓴다.
__device__ inline bool projectPoint(float px, float py, float pz, const ViewRot& r,
                                    float& ox, float& oy, float& depth) {
    const float fx = px - r.cx, fy = py - r.cy, fz = pz - r.cz;
    const float xc = r.m[0] * fx + r.m[1] * fy + r.m[2] * fz;
    const float yc = r.m[3] * fx + r.m[4] * fy + r.m[5] * fz;
    if (r.fly) {
        const float zc = r.m[6] * fx + r.m[7] * fy + r.m[8] * fz;
        // 카메라 뒤에 있거나 코앞인 것은 안 그린다. 코앞을 안 자르면 나누기가 폭발해
        // 알갱이 하나가 화면을 통째로 덮는다.
        if (zc < 1e-3f) return false;
        const float k = 0.5f / (zc * r.tanHalfFov);
        ox = xc * k + 0.5f;
        oy = yc * k + 0.5f;
        depth = zc;
        return true;
    }
    ox = xc + 0.5f;
    oy = yc + 0.5f;
    depth = 1.f;
    return true;
}
#endif  // __CUDACC__

// ── 호스트 쪽 행렬 도구 ──────────────────────────────────────────────────────

inline void viewRotIdentity(float m[9]) {
    m[0] = 1.f; m[1] = 0.f; m[2] = 0.f;
    m[3] = 0.f; m[4] = 1.f; m[5] = 0.f;
    m[6] = 0.f; m[7] = 0.f; m[8] = 1.f;
}

inline void viewRotMul(float out[9], const float a[9], const float b[9]) {
    float t[9];
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) {
            float s = 0.f;
            for (int k = 0; k < 3; ++k) s += a[i * 3 + k] * b[k * 3 + j];
            t[i * 3 + j] = s;
        }
    for (int i = 0; i < 9; ++i) out[i] = t[i];
}

// **행렬을 계속 곱하면 부동소수 오차가 쌓여 직교가 깨진다** — 그러면 판이 조금씩 늘어나거나
// 기울어 보인다. 그람-슈미트로 매번 바로잡는다. 3×3 이라 비용이 없다시피 하다.
inline void viewRotOrthonormalize(float m[9]) {
    auto norm3 = [](float* v) {
        const float L = std::sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        if (L > 1e-12f) { v[0] /= L; v[1] /= L; v[2] /= L; }
    };
    float* r0 = m; float* r1 = m + 3; float* r2 = m + 6;
    norm3(r0);
    const float d01 = r1[0]*r0[0] + r1[1]*r0[1] + r1[2]*r0[2];
    r1[0] -= d01 * r0[0]; r1[1] -= d01 * r0[1]; r1[2] -= d01 * r0[2];
    norm3(r1);
    // 셋째 행은 앞 둘의 외적으로 다시 세운다 — 오른손 좌표계가 유지된다.
    r2[0] = r0[1]*r1[2] - r0[2]*r1[1];
    r2[1] = r0[2]*r1[0] - r0[0]*r1[2];
    r2[2] = r0[0]*r1[1] - r0[1]*r1[0];
}

// **화면 기준으로 돌린다 — 이것이 arcball 의 전부다.**
//
// `dx` 는 마우스 가로 이동(라디안), `dy` 는 세로 이동. 가로로 끌면 **화면의 세로축**을
// 기준으로, 세로로 끌면 **화면의 가로축**을 기준으로 돈다.
//
// **왼쪽에서 곱한다**(`R_new = R_delta · R_old`). 오른쪽에서 곱하면 「판 자신의 축」 기준이
// 되어 예전과 같은 짐벌락이 돌아온다. 왼쪽 곱셈이라야 언제나 지금 보이는 화면 기준이다.
inline void viewRotOrbit(float m[9], float dx, float dy) {
    const float cy = std::cos(dx), sy = std::sin(dx);
    const float cx = std::cos(dy), sx = std::sin(dy);
    const float Ry[9] = {  cy, 0.f,  sy,
                          0.f, 1.f, 0.f,
                          -sy, 0.f,  cy };
    const float Rx[9] = { 1.f, 0.f, 0.f,
                          0.f,  cx, -sx,
                          0.f,  sx,  cx };
    float d[9];
    viewRotMul(d, Rx, Ry);      // 세로 회전 뒤 가로 회전을 한 번에
    viewRotMul(m, d, m);        // 화면 기준이므로 왼쪽에서
    viewRotOrthonormalize(m);
}

// **보는 방향을 축으로 화면을 굴린다(roll).**
//
// 위 `viewRotOrbit` 이 화면의 가로축·세로축으로 돌리는 것과 짝이다. 셋을 다 갖춰야
// 어떤 자세든 만들 수 있다 — 앞 둘만으로는 「고개는 그대로 두고 화면만 기울이기」가
// 안 된다. 원반을 비스듬히 볼 때 수평을 맞추려면 이것이 필요하다.
//
// 축이 화면 깊이축(셋째 행)이므로 회전 행렬은 화면 가로·세로 평면 안에서 돈다.
// 여기서도 **왼쪽에서 곱한다** — 지금 보이는 화면 기준이어야 한다.
inline void viewRotRoll(float m[9], float dz) {
    const float c = std::cos(dz), s = std::sin(dz);
    const float Rz[9] = {   c,  -s, 0.f,
                            s,   c, 0.f,
                          0.f, 0.f, 1.f };
    viewRotMul(m, Rz, m);
    viewRotOrthonormalize(m);
}

// 각도 둘로 방향을 못 박는다. 마우스가 아니라 **밖에서 지정할 때만** 쓴다(제어 채널로
// 같은 방향의 그림을 여러 번 얻고 싶을 때). 내부 상태는 언제나 행렬이다.
inline void viewRotFromAngles(float m[9], float yaw, float pitch) {
    viewRotIdentity(m);
    viewRotOrbit(m, yaw, pitch);
}

inline bool viewRotIsIdentity(const float m[9]) {
    const float eye[9] = { 1.f,0.f,0.f, 0.f,1.f,0.f, 0.f,0.f,1.f };
    for (int i = 0; i < 9; ++i)
        if (std::fabs(m[i] - eye[i]) > 1e-6f) return false;
    return true;
}

// 회전 상태와 **화면 한가운데의 판 좌표**로 ViewRot 을 만든다.
//
// ── 드래그는 화면 축 방향이어야 한다 (2026-08-18) ──────────────────────────
//
// 전에는 `cx = 0.5 - panX` 로 두었다. 그러면 화면을 끌 때 **판에 고정된 x·y 축**으로
// 움직인다 — 안 돌렸을 때는 그것이 화면 축과 같아 티가 안 났지만, 돌려 놓으면 판의
// x축이 화면 가로가 아니라서 엉뚱한 방향으로 간다. 사용자 보고: 「마우스 드래그가
// 보고있는 화면 기준으로 드래그 되야하는데 초기 화면 기준으로 드래그돼서 이상하게 움직여」.
//
// **회전 행렬의 첫 두 줄이 곧 화면의 가로축·세로축**이 판에서 어느 방향인지다
// (`ox = row0·(p-c)`, `oy = row1·(p-c)`). 그 방향으로 축을 옮기면, 끈 양이 그대로
// 화면 이동량이 된다 — 행이 정규직교라 `row0·row0 = 1`, `row0·row1 = 0` 이기 때문이다.
inline ViewRot makeViewRot(const float m[9], float panX, float panY) {
    ViewRot r{};
    for (int i = 0; i < 9; ++i) r.m[i] = m[i];
    r.cx = 0.5f - panX * m[0] - panY * m[3];
    r.cy = 0.5f - panX * m[1] - panY * m[4];
    r.cz = 0.5f - panX * m[2] - panY * m[5];
    r.on = 1;   // 축이 판 한가운데가 아닐 수 있으므로 pan 이 있으면 계산을 건너뛸 수 없다
    return r;
}

// 화면을 옮기지 않은 회전(격자 렌더용). 격자 쪽은 pan 을 자기가 따로 처리한다.
inline ViewRot makeViewRot(const float m[9]) {
    ViewRot r{};
    for (int i = 0; i < 9; ++i) r.m[i] = m[i];
    r.cx = r.cy = r.cz = 0.5f;
    r.on = viewRotIsIdentity(m) ? 0 : 1;
    return r;
}

// 자유 비행 카메라. 축이 아니라 **카메라가 있는 자리**를 원점으로 삼고 원근으로 그린다.
inline ViewRot makeFlyRot(const float m[9], const float pos[3], float fovY) {
    ViewRot r{};
    for (int i = 0; i < 9; ++i) r.m[i] = m[i];
    r.cx = pos[0]; r.cy = pos[1]; r.cz = pos[2];
    r.on = 1;
    r.fly = 1;
    r.tanHalfFov = std::tan(fovY * 0.5f);
    return r;
}
