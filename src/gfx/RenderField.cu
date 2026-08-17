#include "gfx/RenderField.h"

#include <windows.h>
#include <GL/gl.h>
#include <cuda_runtime.h>
#include <cmath>
#include <cstdlib>

namespace {

// 천체 사진 느낌의 색 사다리. 어두운 쪽은 남색, 밝은 쪽으로 갈수록 보라 -> 주황 -> 흰노랑.
__device__ __forceinline__ float3 cmapAstro(float t) {
    t = fminf(fmaxf(t, 0.f), 1.f);
    const float3 c[7] = {
        {0.00f, 0.00f, 0.00f}, {0.05f, 0.06f, 0.19f}, {0.16f, 0.14f, 0.47f},
        {0.47f, 0.27f, 0.67f}, {0.88f, 0.55f, 0.27f}, {1.00f, 0.84f, 0.51f},
        {1.00f, 1.00f, 0.94f}
    };
    const float stops[7] = {0.00f, 0.18f, 0.38f, 0.58f, 0.76f, 0.90f, 1.00f};
    for (int i = 0; i < 6; ++i) {
        if (t <= stops[i + 1]) {
            float f = (t - stops[i]) / (stops[i + 1] - stops[i]);
            return make_float3(c[i].x + (c[i + 1].x - c[i].x) * f,
                               c[i].y + (c[i + 1].y - c[i].y) * f,
                               c[i].z + (c[i + 1].z - c[i].z) * f);
        }
    }
    return c[6];
}

// 표면 온도(켈빈)를 흑체 컬러맵의 자리 [0,1] 로 옮긴다.
//
// **흰색 지점을 6500K 에 맞춘다.** 실제 흑체가 그 온도에서 (255,249,253) 으로 거의 흰색이고,
// 아래는 주황·붉은, 위는 청백으로 갈린다. 전에 2000K~60000K 를 통째로 폈더니 태양(5800K)이
// 0.31 로 「붉은~흰」 구간의 아래쪽에 놓여 주황으로 그려졌다 — 실제 태양은 흰색에 가깝다.
//
// 로그를 쓰는 이유는 별의 색-온도 관계 자체가 로그에 가깝기 때문이다. 선형으로 펴면
// 3만 K 위가 전부 같은 청백으로 뭉쳐 백색왜성과 청색거성을 못 가른다.
//   1800K 붉은(0) · 5800K 태양(0.47) · 6500K 흰(0.5) · 15000K 백색왜성(0.69)
//   30000K 청색거성(0.84) · 60000K 이상(1.0, 중성자별은 여기에 붙는다)
__device__ __forceinline__ float tempToColorT(float tempK) {
    return __saturatef(0.5f + 0.22492f * __logf(fmaxf(tempK, 1.f) * (1.f / 6500.f)));
}

// 흑체복사 색. **별이 실제로 내는 빛의 색이다.**
//
// 열화상(cmapThermal)과 결정적으로 다른 점은 **끝이 파랗다**는 것이다. 열화상은
// 검정→빨강→노랑→흰에서 멈추는데, 실제 흑체는 그 위에 청백이 있고 **무거운 별이 바로
// 거기 있다.** 그 파란 끝이 없으면 「무거운 별일수록 푸르다」가 화면에 안 나온다.
//
//   3000K 붉은(적색왜성)  5800K 노란(태양)  7500K 흰  15000K+ 청백(거성)
//
// **인자 t 는 이제 밝기가 아니라 온도다**(0 = 2000K, 1 = 60000K, 로그로 편 값).
//
// 전에는 밝기를 그대로 온도로 읽었다 — 주계열 별만 있으면 `L = M^3.5`·`T ∝ M^0.5` 라
// 같은 축이어서 맞았다. 그런데 **잔해는 그 관계 밖에 있다**: `L = 4πR²σT⁴` 에서 백색왜성은
// 반지름이 태양의 100분의 1 이라 어두우면서 뜨겁고, 중성자별은 10km 라 거의 안 보이면서
// 백만 K 다. 밝기로 색을 정하면 그 둘이 「어두우니 붉다」로 그려져 적색왜성과 구분되지
// 않는다. 격자를 둘로 나눈 이유가 이것이다(`Sim::lightTempDevicePtr`).
__device__ __forceinline__ float3 cmapBlackbody(float t) {
    t = fminf(fmaxf(t, 0.f), 1.f);
    float r, g, b;
    if (t < 0.5f) {
        const float u = t * 2.0f;                 // 붉은 → 흰
        r = 1.0f;
        g = 0.32f + 0.68f * u;
        b = 0.08f + 0.80f * u * u;                // 파랑이 가장 늦게 올라온다
    } else {
        const float u = (t - 0.5f) * 2.0f;        // 흰 → 청백
        r = 1.0f - 0.38f * u;
        // **초록을 0.14 에서 0.30 으로 더 내린다(2026-08-17).**
        // 실제 20,000K 흑체가 (0.66, 0.77, 1.00) 인데 0.14 로는 g 가 0.86 에 머물렀고,
        // 아래 채도 강조가 그것을 **0.97 까지 올려** 파랑이 아니라 **청록**이 됐다 —
        // 사용자가 「진짜 우주는 저런 색이 아니야」라고 알린 그 색이다.
        g = 1.0f - 0.30f * u;
        b = 1.0f;
    }
    // **채도를 들지 않는다 — 들었더니 파랑이 아니라 청록이 나왔다(2026-08-17 실측).**
    //
    // 「차이를 눈에 보이게 한다」며 회색축에서 3배로 밀었는데, 파랑이 이미 1.0 이라
    // 더 못 올라가서 **빨강만 깎였다.** 2만 K 는 (0.81, 0.85, 1.00) → (0.72, 0.84, 1.00)
    // 이 되어 초록과 빨강의 벌어짐이 0.04 에서 0.12 로 세 배가 됐다.
    // 캡처 화면의 픽셀을 실제로 세니 **청록이 24.55%, 따뜻한 색이 11.09%** 였다.
    //
    // 실제 흑체도 g 가 r 보다 조금 높지만(40000K 에서 0.59, 0.73, 1.00) 빨강이 충분히
    // 남아 있어 눈에는 옅은 파랑으로 보인다. 그 빨강을 깎는 순간 청록이 된다 —
    // 채도 강조는 색조를 그대로 둔다는 전제가 **포화된 채널이 있으면 깨진다.**
    // **어두운 쪽은 실제로도 어둡다.** 붉은 왜성은 색만 붉은 게 아니라 흐리다 —
    // 여기서 안 눌러 주면 어두운 별이 선명한 빨강으로 떠서 은하가 붉은 점묘화가 된다.
    const float dim = fminf(t * 3.2f, 1.0f);
    return make_float3(r * dim, g * dim, b * dim);
}

__device__ __forceinline__ float3 cmapThermal(float t) {
    t = fminf(fmaxf(t, 0.f), 1.f);
    // 열화상: 검정 -> 빨강 -> 노랑 -> 흰. 충격파면이 달아오르는 것을 보기 좋다.
    float r = fminf(t * 2.2f, 1.f);
    float g = fminf(fmaxf((t - 0.32f) * 1.9f, 0.f), 1.f);
    float b = fminf(fmaxf((t - 0.70f) * 3.2f, 0.f), 1.f);
    return make_float3(r, g, b);
}

// 값이 있는 칸의 합과 개수를 센다 — 밝기를 실제 분포에 맞추기 위한 것.
//
// 밝기 기준을 오래 「알갱이 수 ÷ 격자 칸 수」로 잡았는데, 그것은 알갱이가 판 전체에
// 고르게 퍼져 있다는 가정이다. 식히기가 들어가면서 그 가정이 깨졌다 — 209만 칸 중
// 9천 칸(0.4%)에만 몰리니, 가정 평균으로 나누면 뭉친 자리는 포화되고 나머지는 평균의
// 100분의 1 아래로 떨어져 새까맣게 된다. 밝기 슬라이더를 끝까지 올려도 이 대비는
// 그대로다(2026-08-14 실측: 알갱이 399만이 격자 안에 다 있는데 화면이 검었다).
//
// 비용: 화면 격자 칸 수만큼(128² 이면 1만 6천). 알갱이 수와 무관하다.
// 값의 분포를 로그 구간 히스토그램으로 담는다. **백분위수를 정렬 없이 구하려는 것이다.**
//
// **왜 평균으로는 안 되나.** 초신성 하나가 은하 전체보다 밝다(별 1000억 개를 합친 것보다).
// 그런 값 하나가 평균을 통째로 끌어올리면 `bright = brightness / 평균` 이 작아져
// **나머지가 전부 검어진다.** 성운을 더해도 같은 일이 난다 — 더한 만큼 평균이 올라
// 그만큼 깎여, 2026-08-16 실측에서 `nebulaK` 를 올릴수록 흐린 픽셀이 **줄었다**(15.3% → 10.9%).
//
// 실제 천문 사진도 같은 문제를 겪고 노출을 여러 장 겹쳐(HDR) 푼다. 여기서는 **상위 몇 %
// 지점**을 기준으로 삼는다 — 초신성 하나는 그 위에 있어 기준을 못 움직인다.
//
// **비용**: 화면 격자 칸 수(128² = 1만 6천) × O(1). 정렬이 필요 없다.
__global__ void kHistLog(const float* g, int n, int* hist, int bins) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float v = g[i];
    if (v <= 0.f) return;
    // 값의 범위가 몇 자릿수라 로그로 담는다. 1e-4 ~ 1e8 을 bins 칸에 나눈다.
    const float t = (__logf(v) + 9.21f) / (18.42f + 9.21f);   // ln(1e-4)=-9.21, ln(1e8)=18.42
    int b = (int)(t * (float)bins);
    if (b < 0) b = 0;
    if (b >= bins) b = bins - 1;
    atomicAdd(&hist[b], 1);
}

__global__ void kSumNonZero(const float* g, int n, float* sum, int* cnt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float v = g[i];
    if (v <= 0.f) return;
    atomicAdd(sum, v);
    atomicAdd(cnt, 1);
}

// 앞 프레임의 격자에 이번 것을 조금씩 섞는다(a=1 이면 그대로 갈아탄다).
//
// 격자는 128칸인데 화면은 1600픽셀이라 한 칸이 12픽셀로 늘어난다. 거기에 뭉친 자리는
// 평균의 1700배까지 오르므로, 알갱이 몇 개가 칸 경계를 넘나드는 것만으로 그 자리가
// 켜졌다 꺼졌다 한다. 멈춰 세우고 두 프레임을 견주면 픽셀이 하나도 다르지 않으니
// (실측 0.00%) 그리기가 아니라 움직임이 원인이고, 그렇다면 시간으로 눌러야 한다.
//
// 비용: 격자 칸 수만큼(128² 이면 1만 6천) 읽고 쓰기 한 번. 화면 픽셀 수보다 훨씬 적다.
__global__ void kBlendGrid(float* dst, const float* src, int n, float a) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    dst[i] += (src[i] - dst[i]) * a;
}

// 격자를 화면 픽셀로 샘플링해 RGBA8 을 만든다.
// zoom/pan 은 화면 중앙을 기준으로 시뮬레이션 공간 [0,1]² 을 확대·이동한다.
__global__ void kShade(const float* rho, const float* tempSum, int G, uchar4* out, int W, int H,
                       float bright, float invGamma, int cmapKind,
                       float zoom, float panX, float panY) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= W || y >= H) return;

    // 화면을 정사각 시뮬레이션 공간에 맞춘다(짧은 변 기준). 남는 쪽은 검게 둔다.
    float aspect = (float)W / (float)H;
    float u = (x + 0.5f) / W;
    float v = (y + 0.5f) / H;
    if (aspect > 1.f) u = (u - 0.5f) * aspect + 0.5f;
    else              v = (v - 0.5f) / aspect + 0.5f;

    u = (u - 0.5f) / zoom + 0.5f - panX;
    v = (v - 0.5f) / zoom + 0.5f - panY;

    uchar4 px = make_uchar4(0, 0, 0, 255);
    if (u >= 0.f && u < 1.f && v >= 0.f && v < 1.f) {
        // 네 칸을 섞어 읽는다.
        //
        // 확대하면 격자 한 칸이 화면의 여러 픽셀을 덮는다. 가장 가까운 칸 하나만 읽으면
        // 그 칸 크기의 네모가 그대로 드러나 화면이 계단으로 보인다 — 확대할수록 심해진다.
        // 이웃 네 칸을 거리로 섞으면 같은 격자로도 매끄럽게 이어진다.
        const float gfx = u * G - 0.5f, gfy = v * G - 0.5f;
        int x0 = (int)floorf(gfx), y0 = (int)floorf(gfy);
        const float tx = gfx - x0, ty = gfy - y0;
        int x1 = x0 + 1, y1 = y0 + 1;
        x0 = min(max(x0, 0), G - 1); x1 = min(max(x1, 0), G - 1);
        y0 = min(max(y0, 0), G - 1); y1 = min(max(y1, 0), G - 1);
        const float d = rho[y0 * G + x0] * (1.f - tx) * (1.f - ty)
                      + rho[y0 * G + x1] * tx * (1.f - ty)
                      + rho[y1 * G + x0] * (1.f - tx) * ty
                      + rho[y1 * G + x1] * tx * ty;
        // 밀도는 범위가 매우 넓어(빈 곳 0, 중심 수천) 로그로 눌러야 구조가 보인다.
        //
        // **자르지 않고 눌러 담는다(Reinhard).** 전에는 `log(1+d·bright)·0.30` 을 1 에서
        // 잘랐는데, 그 지점이 `d·bright = 27` 이다. 별 밝기가 `L = M^3.5` 라 **질량이 2.5배만
        // 차이나도 27배**가 되므로 웬만한 별이 전부 `t = 1` 로 포화돼 같은 색이 됐다 —
        // 화면에서 어느 별이 더 무거운지 눈으로 구분이 안 된다는 지적이 여기서 나왔다.
        //
        // `x/(1+x)` 는 **절대 1 에 닿지 않으므로 잘리는 정보가 없다.** x=1 이면 0.5,
        // 10 이면 0.91, 100 이면 0.99 — 아무리 밝아도 차이가 계속 색으로 남는다.
        // 앞의 계수를 0.30 에서 0.6 으로 올린 것은 이 압축이 전체를 어둡게 만드는 몫을
        // 되돌리려는 것이다(x 가 두 배가 되면 어두운 쪽이 그만큼 올라온다).
        const float x = fmaxf(__logf(1.f + d * bright) * 0.60f, 0.f);
        float t = __powf(x / (1.f + x), invGamma);
        float3 c;
        if (cmapKind == 3 && tempSum) {
            // ── 색은 온도가, 밝기는 밝기가 정한다 ──────────────────────────
            //
            // `L = 4πR²σT⁴` 라 밝기는 **크기와 온도 둘 다**에 달려 있다. 밝기 하나로
            // 색을 정하면 그 둘의 조합이 통째로 사라져서, 작고 뜨거운 백색왜성이
            // 「어두우니 붉다」로 그려진다 — 실제로는 어두우면서 푸르다. 그 구분이
            // 없으면 작은 별·큰 별·중성자별·블랙홀이 화면에서 전부 흰 점이 된다.
            //
            // `tempSum` 은 밝기로 가중한 온도의 합이라 밝기로 나누면 대표 온도(K)다.
            // 밝기 격자와 **같은 방식으로 보간해야** 한다 — 한쪽만 보간하면 경계에서
            // 분자와 분모가 어긋나 색이 튄다.
            const float ts = tempSum[y0 * G + x0] * (1.f - tx) * (1.f - ty)
                           + tempSum[y0 * G + x1] * tx * (1.f - ty)
                           + tempSum[y1 * G + x0] * (1.f - tx) * ty
                           + tempSum[y1 * G + x1] * tx * ty;
            const float TK = (d > 1e-12f) ? (ts / d) : 0.f;
            c = cmapBlackbody(tempToColorT(TK));
            // 색에 밝기를 곱한다. 어두운 별은 같은 색이라도 어둡게 남아야 한다.
            //
            // **제곱근을 쓰는 이유 — 컬러맵이 깔고 있던 명도 바닥을 대신한다.**
            // 밝기로 색을 정하던 시절 `cmapBlackbody(0)` 은 (1, 0.32, 0.08) 이라 휘도가
            // **0.50** 이었다. 즉 가장 어두운 값도 절반 밝기로 그려졌고, 그 바닥이 화면
            // 전체를 떠받치고 있었다. 색을 온도로 옮기면 그 바닥이 사라져 `c × t` 가
            // 그대로 어두워진다 — 2026-08-17 실측: 켜진 픽셀 6.4% → **1.34%**.
            // `√t` 는 t=0.25 에서 0.5 를 돌려주므로 그 바닥을 근사하면서, 밝고 어두운
            // 차이는 그대로 남긴다(0.05→0.22, 0.8→0.89). 감마를 건드리면 다른 색 기준까지
            // 함께 바뀌므로 이 경로에서만 쓴다.
            const float tv = __fsqrt_rn(t);
            c.x *= tv; c.y *= tv; c.z *= tv;
        } else {
            c = (cmapKind == 3) ? cmapBlackbody(t)
              : (cmapKind == 2) ? cmapThermal(t)
              : (cmapKind == 1) ? make_float3(t, t, t)
                                : cmapAstro(t);
        }
        px = make_uchar4((unsigned char)(c.x * 255.f),
                         (unsigned char)(c.y * 255.f),
                         (unsigned char)(c.z * 255.f), 255);
    }
    // GL 텍스처는 아래에서 위로 쌓이므로 y 를 뒤집어 담는다.
    out[(H - 1 - y) * W + x] = px;
}

// 파티클을 화면에 더한다. 겹칠수록 밝아지므로 밀집한 곳이 자연히 도드라진다.
// uchar4 에는 atomicAdd 가 없어 float3 누적 버퍼에 모았다가 뒤에서 색으로 바꾼다.
// 코어가 3D 로 바뀌면서 위치·속도가 float4 가 됐다(x, y, z, 안 씀).
// 화면 격자(G²)를 **네 칸 섞어** 읽는다.
//
// **가장 가까운 칸 하나만 읽으면 같은 칸의 알갱이가 모두 같은 값을 받아 격자 무늬가
// 그대로 드러난다.** 알갱이는 격자보다 훨씬 촘촘한데 값이 칸 단위로 계단이 지기 때문이다.
// 특히 먼지처럼 **밝기를 깎는** 쪽은 그 계단이 **검은 네모**로 보인다 — 2026-08-17 에
// 사용자가 화면에서 그것을 발견했다.
//
// 성운·먼지·재가 모두 같은 방식으로 격자를 읽으므로 여기 한 번만 적는다.
__device__ __forceinline__ float sampleGrid2D(const float* g, float u, float v, int G) {
    const float fx = u * G - 0.5f, fy = v * G - 0.5f;
    int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
    const float tx = fx - x0, ty = fy - y0;
    int x1 = x0 + 1, y1 = y0 + 1;
    x0 = min(max(x0, 0), G - 1); x1 = min(max(x1, 0), G - 1);
    y0 = min(max(y0, 0), G - 1); y1 = min(max(y1, 0), G - 1);
    return g[y0 * G + x0] * (1.f - tx) * (1.f - ty)
         + g[y0 * G + x1] * tx * (1.f - ty)
         + g[y1 * G + x0] * (1.f - tx) * ty
         + g[y1 * G + x1] * tx * ty;
}

// 블랙홀 자리와 지평선 반지름. **커널 인자로 값을 통째로 넘긴다** — 최대 여덟 개라
// 128 바이트고, 별도 버퍼를 잡아 매 프레임 채우는 것보다 싸다.
struct BHDisk {
    float4 p[8];      // xyz = 자리, w = 지평선 반지름
    int    n = 0;
};

// 화면은 위에서 내려다보므로 여기서는 x, y 만 쓴다 — z 는 깊이라 투영에서 사라진다.
__global__ void kSplatPoints(const float4* pos, const float4* vel, const float* temp,
                             int n, float3* accum, int W, int H,
                             int colorBy, int cmapKind, float zoom, float panX, float panY,
                             float sizePx, float sunMass, float pulsePhase, BHDisk bh,
                             const float* spread, const float* spreadT, int gridG,
                             float nebulaK, const float* gasCol, float dustTau,
                             const float* ashProj) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;                       // 빈 슬롯

    float u = (p.x - 0.5f + panX) * zoom + 0.5f;
    float v = (p.y - 0.5f + panY) * zoom + 0.5f;
    float aspect = (float)W / (float)H;
    if (aspect > 1.f) u = (u - 0.5f) / aspect + 0.5f;
    else              v = (v - 0.5f) * aspect + 0.5f;
    if (u < 0.f || u >= 1.f || v < 0.f || v >= 1.f) return;

    // **실수 자리를 남겨 둔다 — 반올림해 버리면 별이 픽셀을 건너뛰며 깜빡인다.**
    // 아래 한 점 경로에서 이 값으로 네 픽셀에 나눠 찍는다(2026-08-17).
    const float fxp = u * W;
    const float fyp = (1.f - v) * H;             // GL 텍스처는 아래에서 위로 쌓인다
    int x = (int)fxp;
    int y = (int)fyp;
    if (x < 0 || x >= W || y < 0 || y >= H) return;

    // 색 기준: 0 밀도 / 1 온도 / 2 속력 / **3 별빛**.
    // 어느 쪽이든 색은 사용자가 고른 컬러맵(cmapKind: 0 천체 · 1 흑백 · 2 열화상)에서 뽑는다.
    // 전에는 컬러맵을 아예 안 받아서, 보드에서 흑백으로 바꿔도 점 렌더는 그대로였다
    // (round-06 리뷰 P2 #26).
    float t = 0.5f;
    if (colorBy == 1)      t = fminf(temp[i] * 0.5f, 1.f);
    else if (colorBy == 2) {
        // 속력은 3차원 전부를 센다. xy 만 보면 위아래로 빠르게 진동하는 알갱이가
        // 멈춰 있는 것처럼 보인다 — 원반이 3D 라 그 성분이 실제로 있다.
        const float4 v = vel[i];
        t = fminf(sqrtf(v.x * v.x + v.y * v.y + v.z * v.z) * 0.25f, 1.f);
    }

    float3 c;
    if (colorBy == 4) {
        // ── 재 = **은하의 나이 지도** ──────────────────────────────────────────
        //
        // 별이 죽으며 뿌린 무거운 원소가 쌓인 곳이 곧 별이 많이 태어나고 많이 죽은 곳이다.
        // 실제 은하는 중심이 진하고 바깥이 옅다(금속 기울기) — 이 판에서도 초기에
        // 안쪽이 칸당 479~2365배 진하다(round-25).
        //
        // 격자 값을 알갱이가 **읽기만** 한다(성운·먼지와 같은 수법). 재는 알갱이가 아니라
        // 격자에 있으므로 이 방법 말고는 알갱이 렌더에 실을 길이 없다.
        // 회색으로 쌓아 두면 아래 `kAccumToRGBA` 가 컬러맵을 씌운다 — 밀도 모드와 같다.
        if (!ashProj || gridG <= 0) return;
        // 네 칸을 섞어 읽는다 — 재는 알갱이가 아니라 격자에 있는 값이라 이음매가
        // 특히 눈에 걸린다(위 헬퍼 주석).
        const float a = sampleGrid2D(ashProj, p.x, p.y, gridG);
        if (a <= 0.f) return;
        // 재는 범위가 매우 넓다(빈 곳 0, 진한 곳 수억). 로그로 눌러야 구조가 보인다.
        const float w = __logf(1.f + a);
        c = make_float3(w, w, w);
    } else if (colorBy == 3) {
        // ── 별빛 — **여기가 실제로 화면에 나오는 경로다** ────────────────────
        //
        // 격자 쪽(`kShade`)에도 같은 계산이 있는데, 배율이 조금만 커지면 격자 한 칸이
        // 화면 여러 픽셀을 덮어 `pointMix` 가 1 로 포화된다. 그러면 격자는 아예 안
        // 그려지고 이 커널만 남는다 — 2026-08-17 실측: 배율 1.78·격자 128 에서 한 칸이
        // 12.5 픽셀이라 화면이 통째로 점 렌더였다. **격자만 고치면 화면은 안 바뀐다.**
        //
        // 색은 온도가, 밝기는 밝기가 정한다. `L = 4πR²σT⁴` 라 둘이 다른 축이고,
        // 그래서 백색왜성은 어두우면서 푸르다(자세한 근거는 `Sim.cu` 의 `starTempK`).
        // **두 곳에 같은 식이 있는 것은 번역 단위가 달라서다** — 한쪽을 고치면 다른
        // 쪽도 고쳐야 화면과 격자가 같은 색을 낸다.
        const float4 vv = vel[i];
        float L, TK;
        if (p.w > 0.f) {
            const float ratio = fmaxf(p.w / sunMass, 1e-3f);
            L = __powf(ratio, 3.5f);
            if (vv.w < -1.5f) {
                // ── 중성자별 = 펄서 ────────────────────────────────────────
                //
                // 표면은 백만 K 인데 반지름이 10km 라 열복사만 보면 태양의 1조분의 1 이라
                // **화면에 한 점도 안 찍힌다.** 그런데 실제 펄서는 눈에 보인다(게 성운) —
                // 그 빛은 열복사가 아니라 회전 에너지를 뽑아 쓰는 싱크로트론 복사이고,
                // 자기극에서 좁은 빔으로 나온다. 그 빔이 우리 쪽을 스칠 때만 밝다.
                //
                // 그래서 밝기가 두 몫이다 — 거의 없는 열복사 + 빔이 스칠 때의 밝은 섬광.
                // 지수 8 은 빔을 좁게 만든다(한 주기의 20% 남짓만 밝다). 위상은 알갱이
                // 번호에서 뽑아 **같은 별이 늘 같은 박자로** 깜빡인다.
                //
                // 실제 주기는 밀리초~초라 그대로 쓰면 프레임보다 빨라 안 보인다. 폭발을
                // 늘려 보여 주는 것과 같은 이유로 **보이는 길이로 늘린다**(약 1.5초).
                // **펄서 빔을 걷어냈다(2026-08-17).** 빔이 향할 때만 밝고 아닐 때
                // `L × 1e-6` 이라 **사실상 완전히 꺼졌다** — 중성자별 62개가 각자
                // 1.5초 주기로 소등과 점등을 반복했고, 사용자가 「까매졌다 원래색됐다
                // 하면서 깜박인다」고 알린 것이 이것이다.
                //
                // 물리로도 틀렸다. 중성자별은 표면이 100만 K 라 **꺼지지 않고 계속**
                // 빛나고, 가시광에서 펄서 빔이 보이는 것은 게 성운 펄서 급 극소수다.
                // 밝기는 `L = 4πR²σT⁴` 를 그대로 쓴다 — 반지름 10 km 는 태양의
                // 1.43e-5 배라 면적이 2.04e-10 배이고, 10⁶ K 는 태양의 172배라 T⁴ 가
                // 8.83e8 배다. 곱하면 **태양의 0.18배** — 뜨겁지만 너무 작아 어둡다.
                // 앞 별의 질량과 무관하게 정해지므로 `L` 을 이어받지 않고 덮어쓴다.
                TK = 1000000.f;
                L  = 0.18f;
            }
            else if (vv.w < 0.f) { TK = 15000.f;   L *= 1e-3f; }   // 백색왜성 — 반지름이 태양의 100분의 1
            else                   TK = 5800.f * __fsqrt_rn(ratio);
        } else if (p.w < 0.f) {
            L = 1.0e4f; TK = 30000.f;                              // 폭발 중
        } else {
            // ── 반사성운 — **가스는 스스로 안 빛나지만 별빛을 받아 산란한다** ──────
            //
            // 같은 구름이 근처에 별이 있으면 빛나고 없으면 안 보인다. 그것이 반사성운의
            // 성질이라 **곱셈**이다(더하기가 아니다).
            //
            // 알갱이가 이웃을 훑어 「내 둘레에 별이 얼마나 있나」를 세면 그 비용이
            // 2026-08-14 에 드라이버를 죽인 자리다. 대신 **격자를 한 번 만들어 읽기만**
            // 한다 — `kScatterLight` 가 뿌리고 `kBlurLine` 이 흐린 「퍼진 별빛」이 이미
            // 있으므로, 가스 알갱이는 자기 자리의 값을 한 번 읽으면 된다. 비용이
            // 알갱이 수에 정비례하는 읽기 두 번이고 원자 연산이 없다.
            //
            // 격자 좌표는 회전을 안 거친 `p.x, p.y` 를 쓴다 — 이 커널 자체가 회전을
            // 안 하므로(위 투영 코드) 그쪽과 일관된다.
            L = 0.f; TK = 0.f;
            if (!spread || nebulaK <= 0.f || gridG <= 0) return;
            // **네 칸을 섞어 읽는다** — 한 칸만 읽으면 격자 무늬가 드러난다(위 헬퍼 주석).
            const float sp = sampleGrid2D(spread, p.x, p.y, gridG);
            if (sp <= 1e-12f) return;                    // 별빛이 없는 자리의 가스는 검다
            L  = sp * nebulaK;
            // 반사광의 색은 **비추는 별의 색**이다. 퍼진 온도합을 퍼진 밝기로 나눈다.
            // 분자도 **같은 방식으로** 보간해야 경계에서 색이 튀지 않는다.
            TK = spreadT ? (sampleGrid2D(spreadT, p.x, p.y, gridG) / sp) : 6500.f;
        }

        // ── 블랙홀 강착원반 ────────────────────────────────────────────────
        //
        // **블랙홀 자체는 안 보인다 — 보이는 것은 떨어지는 물질이다.** 안으로 끌려 들어가는
        // 물질은 각운동량 때문에 곧장 못 떨어지고 원반을 이루며 돌고, 그 원반의 안쪽과
        // 바깥쪽이 다른 속도로 돌아 마찰로 데워진다. 그것이 빛난다.
        //
        // 표준 원반(샤쿠라-순야예프)에서 온도는 `T ∝ r^-3/4` 이고 단위면적 복사는
        // `T⁴ ∝ r^-3` 이다. 그 둘을 그대로 쓴다 — 안쪽이 뜨겁고 푸르며 훨씬 밝고,
        // 바깥으로 갈수록 식어 희어진다. **그래서 블랙홀은 「밝은 고리」로 보인다.**
        //
        // 가스든 별이든 원반 안에 있으면 데워진다(실제로도 블랙홀 가까이 간 별은 조석력에
        // 찢겨 원반이 된다). 자기 빛에 **더한다** — 별은 원래 밝기 위에 얹힌다.
        //
        // **비용**: 알갱이당 블랙홀 수만큼 거리 계산. 자리가 여덟뿐이라 100만 알갱이에
        // 800만 회이고, 제곱근 없이 `r²` 로 견주다 원반 안일 때만 한 번 편다. 블랙홀이
        // 없으면 루프를 통째로 건너뛴다.
        if (bh.n > 0) {
            for (int k = 0; k < bh.n; ++k) {
                const float4 b = bh.p[k];
                const float dx = p.x - b.x, dy = p.y - b.y, dz = p.z - b.z;
                const float r2 = dx * dx + dy * dy + dz * dz;
                const float rs = fmaxf(b.w, 1e-5f);
                // 원반 바깥 끝은 지평선의 **30배**. 전에 12배로 뒀는데 그것은 실제보다
                // 훨씬 작다 — 관측된 강착원반은 안쪽 안정 궤도(3 r_s)부터 **수백~수천 r_s**
                // 까지 뻗는다. 12배에서는 지평선이 0.0037 인 이 판의 블랙홀이 화면에서
                // 스무 픽셀짜리 점이 되어, 켜진 픽셀의 **0.10%** 밖에 안 됐다.
                const float rOut = rs * 30.0f;
                if (r2 >= rOut * rOut) continue;
                const float r = fmaxf(__fsqrt_rn(r2), rs);
                const float x = r / rs;                    // 지평선 단위 거리
                // 안쪽 5만 K — 초대질량 블랙홀 원반의 실측 범위다(항성질량은 1e7 K 급).
                const float Td = 50000.f * __powf(x, -0.75f);
                // **표준 원반 그대로 `r^-3` 이다.** 한 번 `-2` 로 완만하게 해 봤는데
                // (2026-08-17) 청록 픽셀이 0.10% → 0.36% 로 늘긴 했지만 화면 전체가
                // 눌려 켜진 픽셀이 32% → 4% 로 떨어졌다. 되돌렸다.
                //
                // **바깥 원반이 안 보이는 것은 버그가 아니라 물리다** — 서른 배 자리에서
                // 2만 7천분의 1 이라 실제로 안 보인다. 강착원반은 블랙홀 **아주 가까이**
                // 에서만 밝고, 은하 눈금에서 그것은 몇 픽셀이다. 줌인하면 보인다
                // (round-28 실측: 배율 1.78 에서 청록 0.62%).
                const float Ld = 100.0f  * __powf(x, -3.0f);
                // 밝기로 가중해 온도를 섞는다 — 별 위에 원반이 얹히면 밝은 쪽이 색을 정한다.
                TK = (L + Ld > 0.f) ? (TK * L + Td * Ld) / (L + Ld) : 0.f;
                L += Ld;
            }
        }
        if (L <= 0.f) return;                                       // 아무것도 안 빛난다

        // ── 암흑성운 — **같은 가스가 앞쪽 빛은 반사하고 뒤쪽 빛은 가린다** ──────────
        //
        // 실제 밤하늘에서 은하수를 갈라놓는 검은 띠가 이것이다. 별이 없어서 검은 것이
        // 아니라 **앞에 있는 먼지가 뒤쪽 별빛을 먹어서** 검다. 소광은 `I = I₀·e^(−τ)` 이고
        // `τ` 는 시선 방향으로 쌓인 먼지 양에 비례한다.
        //
        // **별이 구름 「안에」 있다는 것을 셈에 넣는다.**
        //
        // 처음에는 `e^(−τ)` 로 균일하게 깎았다. 그것은 **모든 별이 구름 뒤에 있다**고 보는
        // 것이라, 뭉친 자리에서 `τ` 가 수백이 되면 **화면이 완전히 검어진다** —
        // 2026-08-17 에 사용자가 「검은 네모들」로 발견했고, 네 칸 보간으로 계단을 없애자
        // 이번엔 부드러운 검은 구멍이 남았다. **근사 자체가 짙은 자리에서 무너진 것이다.**
        //
        // 실제로는 별이 구름 앞·속·뒤에 고루 있다. 광학깊이가 0~τ 로 고르다고 보고 적분하면
        //   ⟨e^(−t)⟩ = (1 − e^(−τ)) / τ
        // 가 나온다. τ→0 이면 1(안 가려짐), τ=1 이면 0.63, τ=3 이면 0.32,
        // **τ 가 아무리 커도 `1/τ` 로 천천히 줄 뿐 0 이 되지 않는다** — 구름 앞쪽 별은
        // 언제나 보이기 때문이다. z 방향 프리픽스 합 없이 앞뒤를 근사하는 정확한 식이다.
        if (gasCol && dustTau > 0.f) {
            // 네 칸을 섞어 읽는다 — 한 칸만 읽으면 칸 경계가 계단으로 드러난다.
            const float tau = sampleGrid2D(gasCol, p.x, p.y, gridG) * dustTau;
            if (tau > 1e-4f) L *= (1.f - __expf(-tau)) / tau;
            if (L <= 0.f) return;
        }

        const float tc = tempToColorT(TK);
        // **밝기를 로그로 눌러 쌓는다.** `L = M^3.5` 라 범위가 1e-3~1e7 로 극단적이라
        // 그대로 쌓으면 무거운 별 하나가 누적 버퍼를 통째로 삼켜 나머지가 전부 검어진다.
        // 로그를 씌우면 0.04~17.5 로 좁아져, 겹침(누적)과 개별 밝기가 같은 눈금에 온다.
        const float w = __logf(1.f + L);
        c = cmapBlackbody(tc);
        c.x *= w; c.y *= w; c.z *= w;
    } else if (colorBy == 0) {
        // 밀도 모드는 점마다 같은 색을 쌓아 겹친 수가 밝기가 되게 한다.
        // 그 한 가지 색을 컬러맵의 대표색으로 잡아 색조가 보드 설정과 어긋나지 않게 한다.
        c = (cmapKind == 1) ? make_float3(1.f, 1.f, 1.f)
          : (cmapKind == 2) ? cmapThermal(0.62f)
                            : make_float3(0.55f, 0.42f, 0.85f);
    } else {
        c = (cmapKind == 1) ? make_float3(t, t, t)
          : (cmapKind == 2) ? cmapThermal(t)
                            : cmapAstro(t);
    }

    // 알갱이 하나를 몇 픽셀로 찍을지 — **여기에 단단한 상한이 없으면 카드가 무너진다.**
    //
    // 2026-08-14 실측. 반지름을 12 까지 허용했더니 알 하나가 최대 625 픽셀에 원자 덧셈을
    // 하고, 퍼뜨린 값을 1 로 맞추려고 그 625 칸을 한 번 더 돌았다. 화면 안 알갱이가
    // 50만 개면 한 프레임에 6억 회가 넘는다. 드라이버 타임아웃(기본 2초)을 넘겨 강제
    // 재시작되고 그 와중에 시스템이 통째로 죽었다 — BugCheck 0x139(커널 자료구조 손상).
    //
    // 그래서 셋 중 하나만 쓴다: 한 점 · 3×3 · 5×5. 가중치는 이항 계수라 합이 정확히 1 이고
    // 루프도 나눗셈도 지수함수도 없다. 확대하면 화면 안 알갱이 수 자체가 배율의 제곱으로
    // 줄어들므로, 크게 그리지 않아도 하나하나가 또렷해진다.
    //
    // 게다가 **얼마나 많이 보이는지**로 한 번 더 막는다. 알갱이가 3000만인데 배율이 낮으면
    // 화면 전체가 알갱이라 5×5 로 칠하는 순간 22억 회가 된다 — 그때는 한 점으로 내린다.
    const float visible = (float)n / fmaxf(zoom * zoom, 1.0f);
    const int radCap = (visible > 8.0e6f) ? 0 : ((visible > 2.0e6f) ? 1 : 2);

    const float grow = fminf(sqrtf(fmaxf(zoom, 1.0f)), 4.0f);
    const float rr   = sizePx * grow;               // 알의 지름에 해당하는 크기(픽셀)
    int rad = (rr < 2.0f) ? 0 : ((rr < 4.0f) ? 1 : 2);
    if (rad > radCap) rad = radCap;

    if (rad == 0) {
        float3* px = &accum[y * W + x];
        atomicAdd(&px->x, c.x);
        atomicAdd(&px->y, c.y);
        atomicAdd(&px->z, c.z);
        return;
    }

    // 이항 커널. 가로세로 1차원 가중치를 곱해 쓰므로 2차원 합이 저절로 1 이 된다 —
    // 확대해서 크게 그려도 한 알의 총 밝기는 그대로다.
    const float k3[3] = { 0.25f,   0.5f,  0.25f };
    const float k5[5] = { 0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f };
    const float* kx = (rad == 1) ? k3 : k5;

    for (int dy = -rad; dy <= rad; ++dy) {
        const int yy = y + dy;
        if (yy < 0 || yy >= H) continue;
        const float wy = kx[dy + rad];
        for (int dx = -rad; dx <= rad; ++dx) {
            const int xx = x + dx;
            if (xx < 0 || xx >= W) continue;
            const float fall = wy * kx[dx + rad];
            float3* px = &accum[yy * W + xx];
            atomicAdd(&px->x, c.x * fall);
            atomicAdd(&px->y, c.y * fall);
            atomicAdd(&px->z, c.z * fall);
        }
    }
}

__global__ void kClearAccum(float3* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = make_float3(0.f, 0.f, 0.f);
}

// 누적값을 화면 색으로 바꾼다. 겹친 수가 넓은 범위를 가지므로 로그로 눌러야 다 보인다.
//
// useCmap 을 켜면 쌓인 양을 그대로 색 배열에 통과시킨다. 확대해서 격자 대신 알갱이를
// 그리게 됐을 때 쓴다 — 격자 쪽은 밀도에 따라 남색에서 주황을 거쳐 흰색으로 가는데
// 점 쪽이 한 가지 색이면 넘어가는 순간 화면 색이 통째로 바뀐 것처럼 보인다.
// blend 는 이 그림을 out 에 얼마나 실을지다(1 이면 덮어쓰고, 0.3 이면 30%만 섞인다).
// 격자에서 알갱이로 서서히 넘어가는 구간에서 쓴다.
__global__ void kAccumToRGBA(const float3* accum, uchar4* out, int n,
                             float bright, float invGamma, int useCmap, int cmapKind,
                             float blend, int reinhard) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float3 a = accum[i];
    float lum = (a.x + a.y + a.z) * 0.3333f;

    float r, g, b;
    if (useCmap) {
        const float t = __powf(fminf(__logf(1.f + lum * bright) * 0.42f, 1.f), invGamma);
        const float3 c = (cmapKind == 2) ? cmapThermal(t)
                       : (cmapKind == 1) ? make_float3(t, t, t)
                                         : cmapAstro(t);
        r = c.x; g = c.y; b = c.z;
    } else {
        // **별빛 모드는 자르지 않고 눌러 담는다(Reinhard).** 별 밝기가 `L = M^3.5` 라
        // 질량이 2.5배만 차이나도 27배가 되어, 1 에서 자르면 웬만한 별이 전부 흰 점으로
        // 포화된다 — 어느 별이 더 눈부신지 눈으로 못 가른다는 지적이 여기서 나왔다.
        // `x/(1+x)` 는 1 에 절대 닿지 않아 아무리 밝아도 차이가 색으로 남는다.
        float tone;
        if (reinhard) {
            const float x = fmaxf(__logf(1.f + lum * bright) * 0.42f, 0.f);
            tone = __powf(x / (1.f + x), invGamma);
        } else {
            tone = __powf(fminf(__logf(1.f + lum * bright) * 0.42f, 1.f), invGamma);
        }
        const float s = (lum > 1e-6f) ? tone / lum : 0.f;
        r = fminf(a.x * s, 1.f); g = fminf(a.y * s, 1.f); b = fminf(a.z * s, 1.f);
    }

    if (blend < 0.999f) {
        const uchar4 prev = out[i];
        const float k = 1.f - blend;
        r = r * blend + (prev.x * (1.f / 255.f)) * k;
        g = g * blend + (prev.y * (1.f / 255.f)) * k;
        b = b * blend + (prev.z * (1.f / 255.f)) * k;
    }
    out[i] = make_uchar4((unsigned char)(fminf(r, 1.f) * 255.f),
                         (unsigned char)(fminf(g, 1.f) * 255.f),
                         (unsigned char)(fminf(b, 1.f) * 255.f), 255);
}

} // namespace

void RenderField::init() {
    glGenTextures(1, &texId_);
    glBindTexture(GL_TEXTURE_2D, texId_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
}

void RenderField::shutdown() {
    if (texId_) { glDeleteTextures(1, &texId_); texId_ = 0; }
    texAllocW_ = texAllocH_ = 0;      // 텍스처를 지웠으니 저장소도 없다
    if (hostPixels_) { free(hostPixels_); hostPixels_ = nullptr; }
    if (devPixels_)  { cudaFree(devPixels_); devPixels_ = nullptr; devBytes_ = 0; }
    if (devAccum_)   { cudaFree(devAccum_);  devAccum_  = nullptr; }
    if (devSmooth_)  { cudaFree(devSmooth_); devSmooth_ = nullptr; }
    if (devSmoothT_) { cudaFree(devSmoothT_); devSmoothT_ = nullptr; }
    if (devSmoothNeb_)  { cudaFree(devSmoothNeb_);  devSmoothNeb_  = nullptr; }
    if (devSmoothNebT_) { cudaFree(devSmoothNebT_); devSmoothNebT_ = nullptr; }
    if (devSmoothGas_)  { cudaFree(devSmoothGas_);  devSmoothGas_  = nullptr; }
    if (devStat_)    { cudaFree(devStat_);   devStat_   = nullptr; }
    smoothCells_ = 0; smoothPrimed_ = false; liveMean_ = 0.f;
}

void RenderField::ensureSize(int w, int h) {
    // **버퍼는 줄이지 않는다. 커질 때만 다시 잡는다.**
    //
    // 「버거우면 절반 해상도」는 프레임 시간이 문턱 근처에서 오르내리면 매 프레임 전체와
    // 절반을 오간다. 그때마다 여기서 cudaFree + cudaMalloc 이 돌면 초당 수십 번 수 MB 를
    // 해제하고 다시 잡는 셈이고, 그 상태로 몇 분을 돌리면 그래픽 드라이버가 무너진다.
    // 2026-08-14 실측: BugCheck 0xD1, 참조 주소 0x80(널 + 오프셋) — 이 프로젝트에서
    // 매 프레임 glTexImage2D 를 부르다 죽었을 때와 **같은 서명**이다.
    //
    // 큰 쪽에 맞춰 한 번만 잡아 두고 작게 그릴 때는 그 버퍼의 앞부분만 쓴다.
    if (devPixels_ && w <= allocW_ && h <= allocH_) { texW_ = w; texH_ = h; return; }
    const int aw = (w > allocW_) ? w : allocW_;
    const int ah = (h > allocH_) ? h : allocH_;
    allocW_ = aw; allocH_ = ah;
    texW_ = w; texH_ = h;
    w = aw; h = ah;
    size_t need = (size_t)w * h * 4;
    if (hostPixels_) free(hostPixels_);
    hostPixels_ = (unsigned char*)malloc(need);
    // 할당이 실패하면 반드시 null 로 둔다 — 실패한 포인터를 그대로 두면 다음 프레임에
    // 그 주소로 커널을 띄워 CUDA 컨텍스트를 통째로 망가뜨린다(round-06 리뷰 P1 #12).
    if (devPixels_) cudaFree(devPixels_);
    if (cudaMalloc(&devPixels_, need) != cudaSuccess) devPixels_ = nullptr;
    if (devAccum_) cudaFree(devAccum_);
    if (cudaMalloc(&devAccum_, (size_t)w * h * sizeof(float3)) != cudaSuccess) devAccum_ = nullptr;
    devBytes_ = need;
}

void RenderField::draw(App& app, int viewW, int viewH) {
    if (viewW <= 0 || viewH <= 0) return;

    // 창 크기와 「그리는 크기」를 나눈다.
    //
    // 「버거우면 절반 해상도」를 켜면 픽셀 수가 4분의 1이 되고, 그 작은 그림이 화면 전체
    // 쿼드에 늘어 붙는다 — 화면은 그대로 차고 흐려지기만 한다. 멈춰 있을 때는 급할 것이
    // 없으므로 늘 선명하게 그린다.
    // 한 번 정한 것은 한동안 유지한다.
    //
    // 프레임 시간이 문턱 근처에 있으면 매 프레임 전체와 절반이 뒤집힌다. 그러면 화면이
    // 떨리는 것은 물론이고, 크기가 바뀔 때마다 버퍼를 다시 잡던 예전 코드에서는
    // 드라이버까지 무너졌다. 켜지는 선과 꺼지는 선을 벌려 두고, 바뀐 뒤 서른 프레임은
    // 그대로 둔다.
    const int outW = viewW, outH = viewH;
    if (app.ui.halfResWhenBusy && app.running) {
        if (halfHold_ > 0) --halfHold_;
        else {
            const bool want = half_ ? (app.frameMs > 14.0f) : (app.frameMs > 24.0f);
            if (want != half_) { half_ = want; halfHold_ = 30; }
        }
    } else if (half_) {
        half_ = false; halfHold_ = 0;
    }
    if (half_) {
        viewW = (viewW + 1) / 2;
        viewH = (viewH + 1) / 2;
    }
    // 잡는 것은 늘 창 크기 기준이다 — 절반으로 그려도 버퍼를 다시 잡지 않는다.
    ensureSize(outW, outH);
    texW_ = viewW; texH_ = viewH;

    const ViewSettings& view = app.view;
    ++drawTick_;                       // 펄서가 쓸 시계(위 멤버 선언 참조)
    const int npix = viewW * viewH;
    const int cmapKind = (view.cmap == ColorMap::Blackbody) ? 3
                       : (view.cmap == ColorMap::Thermal)   ? 2
                       : (view.cmap == ColorMap::Gray)      ? 1 : 0;

    // 다가갈수록 격자에서 알갱이로 **서서히** 넘어간다.
    //
    // 밀도 격자는 칸 단위다. 한 칸이 화면에서 여러 픽셀을 덮을 만큼 확대하면 그 칸 모양이
    // 그대로 얼룩으로 드러난다 — 네 칸을 섞어 매끄럽게 이어도 마찬가지다. 격자에 없는
    // 정보를 만들어 낼 수는 없기 때문이다. 알갱이는 격자보다 훨씬 촘촘하므로 그때부터는
    // 알갱이를 찍는 편이 실제로 더 선명하다.
    //
    // 어느 한 배율에서 딱 갈아타면 휠 한 칸에 화면이 통째로 바뀐 것처럼 보인다. 그래서
    // 겹치는 구간을 두고 섞는다 — 한 칸이 픽셀만 해지면 알갱이가 스미기 시작해, 네 픽셀을
    // 덮을 즈음 알갱이만 남는다. 그 사이는 10%·20%·30% 씩 갈마든다.
    //
    // 섞는 구간에서만 둘 다 그리므로 비용이 잠깐 는다. 그 구간은 배율로 네 배 폭이라 짧다.
    const float shortSide = (float)(viewW < viewH ? viewW : viewH);
    const int   gridG     = app.sim.gridSize();
    const float cellPx    = (gridG > 0) ? shortSide * app.zoom / (float)gridG : 0.0f;
    float pointMix = (cellPx - 1.0f) / 3.0f;
    pointMix = fminf(fmaxf(pointMix, 0.0f), 1.0f);
    // 양 끝에서 변화가 느려지게 눌러 준다. 선형이면 섞임이 시작·끝나는 순간이 눈에 걸린다.
    pointMix = pointMix * pointMix * (3.0f - 2.0f * pointMix);
    if (view.mode == RenderMode::Points) pointMix = 1.0f;   // 직접 고른 경우는 늘 알갱이

    const bool wantField  = (pointMix < 0.999f);
    const bool wantPoints = (pointMix > 0.001f) && devAccum_;
    const float meanRho = (gridG > 0) ? (float)app.sim.particleCount() / (float)(gridG * gridG)
                                      : 1.0f;

    if (!devPixels_) {
        if (hostPixels_) memset(hostPixels_, 0, devBytes_);
    } else {
        bool drew = false;

        if (wantField) {
            // 밀도 필드 — 색 기준에 맞는 격자를 받아 화면으로 샘플링한다.
            const Sim::Field f = (view.colorBy == ColorBy::Dispersion) ? Sim::Field::Dispersion
                               : (view.colorBy == ColorBy::Speed)       ? Sim::Field::Speed
                               : (view.colorBy == ColorBy::Light)       ? Sim::Field::Light
                               : (view.colorBy == ColorBy::Ash)         ? Sim::Field::Ash
                                                                        : Sim::Field::Density;
            const float* grid = app.sim.fieldDevicePtr(f);
            // 빛 모드에서만 온도 격자가 있다. 다른 모드는 nullptr 이라 `kShade` 가
            // 기존 경로(밝기로 색을 정함)를 그대로 탄다.
            const float* tempGrid = (f == Sim::Field::Light)
                                  ? app.sim.lightTempDevicePtr() : nullptr;

            // 앞 프레임과 섞어 떨림을 누른다. 새 그림을 35% 만 받아들이면 서너 프레임에
            // 걸쳐 따라가므로, 빠르게 도는 것도 뭉개지지 않으면서 깜빡임은 사라진다.
            // 멈춰 있을 때는 섞을 것도 없고(두 프레임이 같다) 새 장면으로 갈아탄 직후에는
            // 앞 그림이 방해가 되므로, 도는 동안에만 섞는다.
            if (grid && app.running && gridG > 0) {
                const int cells = gridG * gridG;
                if (cells > smoothCells_) {          // 커질 때만 다시 잡는다
                    if (devSmooth_)  cudaFree(devSmooth_);
                    if (devSmoothT_) cudaFree(devSmoothT_);
                    devSmooth_ = nullptr; devSmoothT_ = nullptr;
                    if (cudaMalloc(&devSmooth_, sizeof(float) * (size_t)cells) != cudaSuccess)
                        devSmooth_ = nullptr;
                    if (cudaMalloc(&devSmoothT_, sizeof(float) * (size_t)cells) != cudaSuccess)
                        devSmoothT_ = nullptr;
                    smoothCells_ = devSmooth_ ? cells : 0;
                    smoothPrimed_ = false;
                }
                if (devSmooth_) {
                    const float a = smoothPrimed_ ? 0.35f : 1.0f;
                    kBlendGrid<<<(cells + 255) / 256, 256>>>((float*)devSmooth_, grid, cells, a);
                    // 온도 합도 같은 비율로 섞어야 색이 안 튄다(위 멤버 선언 참조).
                    if (tempGrid && devSmoothT_) {
                        kBlendGrid<<<(cells + 255) / 256, 256>>>((float*)devSmoothT_, tempGrid,
                                                                 cells, a);
                        tempGrid = (const float*)devSmoothT_;
                    }
                    smoothPrimed_ = true;
                    grid = (const float*)devSmooth_;
                }
            } else {
                smoothPrimed_ = false;               // 멈춘 동안 쌓인 것은 버린다
            }

            // 밀도는 파티클 수에 그대로 비례한다 — 같은 배치라도 3000만 개는 100만 개의 30배다.
            // 원시값을 그대로 넣으면 개수를 올리는 순간 판 전체가 순백으로 타 버린다
            // (실측 2026-08-14: 3000만에서 평균 밀도만 28.6, 포화선은 13.5).
            // 평균 밀도로 나눠 「평균의 몇 배인가」로 그리면 개수를 바꿔도 같은 그림이 나온다.
            //
            // 나누는 기준은 살아 있는 수가 아니라 **설정된 최대 개수**다. 살아 있는 수로 나누면
            // 천체가 가스를 먹어 줄어들 때 남은 가스가 오히려 밝아진다 — 줄면 어두워지는 것이 맞다.
            //
            // 온도·속도는 밀도로 가중평균한 값이라 개수와 무관하다. 대신 값의 범위가 0~1 로 좁아
            // 로그 압축이 과하므로 그 자리에서 배율을 올린다.
            // **밝기 기준을 실제로 차 있는 칸에서 낸다.**
            //
            // meanRho(= 알갱이 수 ÷ 칸 수)는 고르게 퍼졌을 때만 맞는 값이라, 뭉치고 나면
            // 화면이 통째로 검어진다. 값이 있는 칸의 평균으로 나누면 퍼져 있든 뭉쳐 있든
            // 「그 자리가 이웃보다 얼마나 진한가」로 그려져 구조가 늘 보인다.
            // 급변하면 화면이 출렁이므로 열 프레임에 걸쳐 따라가게 한다.
            float norm = meanRho;
            // 빛도 밀도와 같은 정규화를 쓴다. `L = M^3.5` 라 값 범위가 극단적이라
            // 고정 배수로는 화면이 새까맣거나 새하얘진다.
            const bool wantNorm = (f == Sim::Field::Density || f == Sim::Field::Light);
            if (wantNorm && grid && gridG > 0) {
                // **열다섯 프레임에 한 번만 잰다.**
                //
                // 재려면 결과를 호스트로 가져와야 하는데, 그 복사가 GPU 파이프라인을 세운다.
                // 매 프레임 하도록 두었더니 알갱이 399만에서 스텝이 8.7 → 13.8 ms 로 뛰어
                // 예산(16.7) 코앞까지 갔다(2026-08-14 실측). 밝기 기준은 장면이 서서히
                // 바뀌는 것을 따라가면 되는 값이라 0.25초에 한 번으로 충분하다.
                if ((statTick_++ % 15) == 0) {
                    const int cells = gridG * gridG;
                    // **평균이 아니라 상위 백분위수를 기준으로 잡는다(2026-08-16).**
                    //
                    // 평균은 초신성 하나(은하 전체보다 밝다)에 통째로 끌려가고, 성운을
                    // 더해도 그만큼 깎아 낸다 — 실측에서 `nebulaK` 를 올릴수록 흐린 픽셀이
                    // **줄었다**(15.3% → 10.9%). 상위 5% 지점은 그런 극단값 위에 있어
                    // 기준이 안 흔들린다. 실제 천문 사진이 HDR 로 푸는 것과 같은 문제다.
                    constexpr int kBins = 64;
                    if (!devStat_) cudaMalloc(&devStat_, sizeof(int) * kBins);
                    if (devStat_) {
                        // **빛 모드에서는 후광을 입히기 전 격자로 기준을 잡는다.**
                        //
                        // 그리는 것은 후광이 붙은 `grid` 지만, 그것으로 기준을 잡으면
                        // 빛이 퍼진 만큼 중간 밝기 픽셀이 늘어 상위 5% 지점이 올라가고,
                        // 후광으로 더한 만큼 도로 깎인다 — 2026-08-16 실측에서
                        // `starGlowK` 를 0 → 1.5 로 올리자 켜진 픽셀이 2.78% → 0.4% 로
                        // **줄었다**(에너지를 보존하게 고친 뒤에도 그대로였다).
                        const float* statGrid = grid;
                        if (f == Sim::Field::Light) {
                            const float* raw = app.sim.lightBeforeGlowDevicePtr();
                            if (raw) statGrid = raw;
                        }
                        cudaMemset(devStat_, 0, sizeof(int) * kBins);
                        kHistLog<<<(cells + 255) / 256, 256>>>(statGrid, cells, (int*)devStat_, kBins);
                        int h[kBins] = {};
                        if (cudaMemcpy(h, devStat_, sizeof(int) * kBins, cudaMemcpyDeviceToHost)
                            == cudaSuccess) {
                            int total = 0;
                            for (int b = 0; b < kBins; ++b) total += h[b];
                            if (total > 0) {
                                // 위에서부터 5% 를 세어 그 지점의 값을 기준으로 삼는다.
                                const int want = (int)(total * 0.05f) + 1;
                                int acc = 0, hit = kBins - 1;
                                for (int b = kBins - 1; b >= 0; --b) {
                                    acc += h[b];
                                    if (acc >= want) { hit = b; break; }
                                }
                                // **구간 안을 보간한다 — 안 하면 화면이 계단으로 뛴다.**
                                //
                                // 구간이 64개인데 로그 범위가 1e-4~1e8 이라 **한 구간이
                                // 1.54배**다. 구간 가운데(+0.5)를 그대로 쓰면 기준값이
                                // 한 칸 움직일 때마다 화면 전체 밝기가 1.54배 뛰고,
                                // 아래 이력 0.3 을 곱해도 0.25초마다 15% 씩 계단이 된다 —
                                // 2026-08-17 사용자가 「번쩍번쩍, 까매졌다 다시 색이
                                // 나온다」고 알린 것이 이 계단이다.
                                //
                                // hit 구간 위쪽에 이미 `below` 개가 있고 그 구간에서
                                // `want - below` 개를 더 세면 5% 지점이다. 그 비율이
                                // 구간 위쪽에서부터의 위치이므로 1 에서 빼서 되돌린다.
                                const int   below = acc - h[hit];
                                const float need  = (float)(want - below);
                                const float frac  = (h[hit] > 0)
                                                  ? fminf(fmaxf(need / (float)h[hit], 0.f), 1.f)
                                                  : 0.5f;
                                const float t = ((float)hit + 1.0f - frac) / (float)kBins;
                                const float m = expf(t * (18.42f + 9.21f) - 9.21f);
                                // **이력을 0.3 에서 0.08 로 더 누른다.** 보간으로 계단은
                                // 없앴지만 별이 태어나고 터지는 동안 5% 지점 자체가
                                // 오르내린다. 밝기 기준은 장면을 서서히 따라가면 되는
                                // 값이라 느린 쪽이 맞다 — 0.25초마다 8% 면 눈에 안 걸린다.
                                liveMean_ = (liveMean_ > 0.f)
                                          ? (liveMean_ + (m - liveMean_) * 0.08f) : m;
                            }
                        }
                    }
                }
                if (liveMean_ > 1e-6f) norm = liveMean_;
            }
            const float bright = wantNorm
                               ? view.brightness / fmaxf(norm, 1e-6f)
                               : view.brightness * 60.0f;
            if (grid) {
                dim3 b(16, 16), g((viewW + 15) / 16, (viewH + 15) / 16);
                kShade<<<g, b>>>(grid, tempGrid, gridG, (uchar4*)devPixels_, viewW, viewH,
                                 bright, 1.0f / view.gamma, cmapKind,
                                 app.zoom, app.panX, app.panY);
                drew = true;
            }
        }

        if (wantPoints) {
            // 파티클 점 — 겹칠수록 밝아지도록 누적한 뒤 한 번에 색으로 바꾼다.
            const int n = app.sim.activeCount();
            kClearAccum<<<(npix + 255) / 256, 256>>>((float3*)devAccum_, npix);
            // 블랙홀 자리를 모아 커널에 값으로 넘긴다(강착원반). 빛 모드에서만 쓰이지만
            // 여덟 개 읽기라 모드를 가려 건너뛸 만큼의 비용이 아니다.
            BHDisk bhDisk;
            {
                const int bhN = app.sim.blackHoleCount();
                for (int k = 0; k < bhN && bhDisk.n < 8; ++k) {
                    const BlackHoleState s = app.sim.blackHoleAt(k);
                    if (!s.active) continue;
                    bhDisk.p[bhDisk.n++] = make_float4(s.x, s.y, s.z, s.rs);
                }
            }
            // **반사성운을 점 렌더에서도 그리려면 「퍼진 별빛」 격자가 있어야 한다.**
            // 그 격자는 `fieldDevicePtr(Field::Light)` 안에서 만들어지는데, 배율이 크면
            // `wantField` 가 거짓이라 아예 안 불린다 — 그래서 지금까지 성운이 격자 렌더
            // 구간에서만 뜻이 있었고 실사용 배율에서는 통째로 안 보였다(round-35).
            // 빛 모드에서 점을 그릴 때는 여기서 한 번 불러 격자를 확보한다.
            // 재 보기는 격자에 있는 값이라 알갱이가 **읽을** 격자를 확보해야 한다.
            // 배율이 크면 `wantField` 가 거짓이라 안 만들어지므로 여기서 한 번 부른다
            // (성운이 같은 이유로 같은 일을 한다 — round-40).
            const float* ashProj = nullptr;
            if (view.colorBy == ColorBy::Ash) {
                ashProj = app.sim.fieldDevicePtr(Sim::Field::Ash);
            }
            const bool pointsLight = (view.colorBy == ColorBy::Light);
            const float* nebSpread = nullptr;
            const float* nebSpreadT = nullptr;
            const float* gasCol = nullptr;
            float nebK = 0.f, dustTau = 0.f;
            if (pointsLight && app.sim.config().nebulaK > 0.f) {
                if (!wantField) (void)app.sim.fieldDevicePtr(Sim::Field::Light);
                nebSpread  = app.sim.lightSpreadDevicePtr();
                nebSpreadT = app.sim.lightSpreadTempDevicePtr();
                nebK       = app.sim.config().nebulaK;

                // **이 격자들도 앞 프레임과 섞는다.** 밝기 격자만 섞고 여기를 안 섞으면,
                // 알갱이가 칸 경계를 넘나들 때마다 그 칸의 성운 밝기와 먼지 두께가 통째로
                // 뛰어 **네모난 자리가 번쩍인다** — 2026-08-17 에 사용자가 발견했다.
                // 도는 동안에만 섞는 것은 밝기 쪽과 같은 규칙이다(멈추면 섞을 것이 없다).
                if (app.running && gridG > 0) {
                    const int cells3 = gridG * gridG;
                    const size_t bytes3 = sizeof(float) * (size_t)cells3;
                    if (!devSmoothNeb_)  cudaMalloc(&devSmoothNeb_,  bytes3);
                    if (!devSmoothNebT_) cudaMalloc(&devSmoothNebT_, bytes3);
                    if (!devSmoothGas_)  cudaMalloc(&devSmoothGas_,  bytes3);
                    const float a3 = smoothPrimed_ ? 0.35f : 1.0f;
                    const int b3 = (cells3 + 255) / 256;
                    if (devSmoothNeb_ && nebSpread) {
                        kBlendGrid<<<b3, 256>>>((float*)devSmoothNeb_, nebSpread, cells3, a3);
                        nebSpread = (const float*)devSmoothNeb_;
                    }
                    if (devSmoothNebT_ && nebSpreadT) {
                        kBlendGrid<<<b3, 256>>>((float*)devSmoothNebT_, nebSpreadT, cells3, a3);
                        nebSpreadT = (const float*)devSmoothNebT_;
                    }
                }
                // 암흑성운 — 같은 가스가 뒤쪽 빛을 가린다. 가스 기둥은 격자 값이라
                // 크기가 알갱이 수에 붙으므로 **평균으로 나눠** 「평균의 몇 배인가」로
                // 바꾼 뒤 소광 계수를 곱한다(성운이 쓰는 정규화와 같은 것).
                gasCol = app.sim.gasColumnDevicePtr();
                const int cells2 = gridG * gridG;
                const int nAll = app.sim.particleCount();
                const float invMeanGas = (nAll > 0) ? ((float)cells2 / (float)nAll) : 1.0f;
                dustTau = app.sim.config().dustExtinctionK * invMeanGas;
                // 먼지 격자도 같이 섞는다 — 밝기를 깎는 쪽이라 튀면 가장 눈에 띈다.
                if (app.running && devSmoothGas_ && gasCol) {
                    const float a4 = smoothPrimed_ ? 0.35f : 1.0f;
                    kBlendGrid<<<(cells2 + 255) / 256, 256>>>((float*)devSmoothGas_, gasCol,
                                                              cells2, a4);
                    gasCol = (const float*)devSmoothGas_;
                }
            }
            if (n > 0) {
                kSplatPoints<<<(n + 255) / 256, 256>>>(
                    (const float4*)app.sim.particlePosDevicePtr(),
                    (const float4*)app.sim.particleVelDevicePtr(),
                    app.sim.particleTempDevicePtr(), n,
                    (float3*)devAccum_, viewW, viewH, (int)view.colorBy, cmapKind,
                    app.zoom, app.panX, app.panY, app.ui.pointSizePx,
                    fmaxf(app.sim.config().starSunMass, 1.0f),
                    // 펄서 위상. 90 프레임이 한 바퀴라 60fps 에서 약 1.5초 주기다.
                    (float)(drawTick_ % 90u) * (6.2831853f / 90.0f), bhDisk,
                    nebSpread, nebSpreadT, gridG, nebK, gasCol, dustTau, ashProj);
            }
            // 섞이는 동안 밝기와 색이 이어지게 맞춘다.
            //
            // 격자 쪽은 평균 밀도로 나눠 「평균의 몇 배인가」로 그리고 색 배열을 거친다.
            // 저절로 넘어온 알갱이 쪽에도 같은 배수와 같은 색 배열을 써야 섞이는 구간에서
            // 두 그림이 같은 색조로 겹친다. 사용자가 직접 점 모드를 고른 경우는 건드리지 않는다.
            const bool autoPoints = (view.mode != RenderMode::Points);
            // **별빛 모드는 컬러맵을 다시 씌우지 않는다.** 알갱이가 이미 자기 온도의 색을
            // 쌓아 두었는데 그 위에 밝기 기준 컬러맵을 덮으면 색이 통째로 지워진다 —
            // 그래서 지금까지 화면이 온도와 무관한 남색이었다(2026-08-17 실측: 어두운
            // 픽셀 평균 rgb 12.5/13.4/43.6 은 흑체가 못 내는 색이고 `cmapAstro` 의 값이다).
            const bool lightMode = (view.colorBy == ColorBy::Light);
            const float pointBright = (autoPoints && !lightMode)
                                    ? view.brightness / fmaxf(meanRho, 1e-6f)
                                    : view.brightness;
            // wantField 가 그리지 못했으면 섞을 바탕이 없다 — 그때는 알갱이로 덮어쓴다.
            const float blend = (wantField && drew) ? pointMix : 1.0f;
            kAccumToRGBA<<<(npix + 255) / 256, 256>>>((const float3*)devAccum_,
                                                      (uchar4*)devPixels_, npix,
                                                      pointBright, 1.0f / view.gamma,
                                                      (autoPoints && !lightMode) ? 1 : 0,
                                                      cmapKind, blend, lightMode ? 1 : 0);
            drew = true;
        }

        // 복사가 실패하면 hostPixels_ 는 이전 프레임 그대로다 — 그걸 새 화면인 양 올리면
        // 사용자는 시뮬레이션이 도는 줄 안다. 실패하면 검은 화면으로 두어 이상을 드러낸다
        // (round-08 리뷰 A11).
        if (!drew) {
            if (hostPixels_) memset(hostPixels_, 0, devBytes_);
        } else if (cudaMemcpy(hostPixels_, devPixels_, devBytes_,
                              cudaMemcpyDeviceToHost) != cudaSuccess) {
            if (hostPixels_) memset(hostPixels_, 0, devBytes_);
        }
    }

    glViewport(0, 0, outW, outH);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_LIGHTING);
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, texId_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    // 텍스처 저장소는 **창 크기가 바뀔 때만** 다시 만들고, 평소에는 내용만 덮어쓴다.
    //
    // glTexImage2D 는 부를 때마다 텍스처 메모리를 새로 잡는 함수다. 이걸 매 프레임 부르면
    // 1600×900 기준 한 장에 5.76 MB 씩, 초당 400 장이면 **초당 2.3 GB 를 잡았다 버리는** 셈이 된다.
    // 그 상태로 몇십 분을 돌리면 그래픽 드라이버의 메모리 관리가 무너진다.
    // 2026-08-13 실측: 시스템이 두 번 재부팅됐고 둘 다 BugCheck 0xD1 / nvlddmkm.sys 였다.
    // 참조 주소가 두 번 모두 정확히 0x80(널 포인터 + 오프셋)으로 같았다 — 같은 자리에서 죽었다는 뜻이고,
    // 두 번째는 앱이 아무 조작 없이 돌기만 하는 동안 죽어서 이 경로가 남았다.
    //
    // glTexSubImage2D 는 이미 잡아 둔 저장소에 픽셀만 써 넣으므로 할당이 일어나지 않는다.
    //
    // 저장소는 **잡아 둔 크기(allocW_×allocH_)** 로 만들고, 이번에 그린 만큼만 써 넣는다.
    // 그리는 크기로 저장소를 만들면 절반 해상도가 켜졌을 때 매 프레임 다시 만들게 된다 —
    // 2026-08-14 에 그것으로 다시 한 번 드라이버가 무너졌다(같은 0xD1 / 0x80).
    if (hostPixels_ && allocW_ > 0 && allocH_ > 0) {
        if (texAllocW_ != allocW_ || texAllocH_ != allocH_) {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, allocW_, allocH_, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
            texAllocW_ = allocW_; texAllocH_ = allocH_;
        }
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, viewW, viewH,
                        GL_RGBA, GL_UNSIGNED_BYTE, hostPixels_);
    }

    // 저장소가 그린 것보다 클 수 있으므로 쓴 만큼만 화면에 편다.
    const float su = (allocW_ > 0) ? (float)viewW / (float)allocW_ : 1.0f;
    const float sv = (allocH_ > 0) ? (float)viewH / (float)allocH_ : 1.0f;

    glMatrixMode(GL_PROJECTION); glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);  glLoadIdentity();
    glColor4f(1.f, 1.f, 1.f, 1.f);
    glBegin(GL_QUADS);
        glTexCoord2f(0.f, 0.f); glVertex2f(-1.f, -1.f);
        glTexCoord2f(su,  0.f); glVertex2f( 1.f, -1.f);
        glTexCoord2f(su,  sv);  glVertex2f( 1.f,  1.f);
        glTexCoord2f(0.f, sv);  glVertex2f(-1.f,  1.f);
    glEnd();
    glDisable(GL_TEXTURE_2D);

    // 계산 격자를 겹쳐 그린다.
    //
    // 힘을 어느 칸 단위로 재는지 눈으로 보게 하는 그림이다. 칸이 2048² 이면 선이 화면보다
    // 촘촘해 회색 판이 되므로, 화면에서 24 px 보다 성기게 나오도록 몇 칸씩 건너뛴다.
    if (app.ui.showGridOverlay) {
        const int G = app.sim.gridSize();
        const float shortSide = (float)(outW < outH ? outW : outH);
        const float cellPx = shortSide * app.zoom / (float)G;
        int stride = 1;
        while (cellPx * stride < 24.0f && stride < G) stride *= 2;

        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glColor4f(1.f, 1.f, 1.f, 0.12f);
        glBegin(GL_LINES);
        const float aspect = (float)outW / (float)outH;
        for (int i = 0; i <= G; i += stride) {
            // 시뮬 좌표 [0,1] → 화면 [-1,1]. kShade 와 같은 변환이라야 선이 칸 위에 얹힌다.
            const float s = (float)i / (float)G;
            float a = (s - 0.5f + app.panX) * app.zoom + 0.5f;
            float bx = a, by = a;
            if (aspect > 1.f) bx = (a - 0.5f) / aspect + 0.5f;
            else              by = (a - 0.5f) * aspect + 0.5f;
            const float gx = bx * 2.f - 1.f;
            // 세로줄은 x 가 pan 을 타고, 가로줄은 y 가 탄다 — 둘을 따로 계산해야 맞는다.
            float ay = ((float)i / (float)G - 0.5f + app.panY) * app.zoom + 0.5f;
            if (aspect > 1.f) { /* y 는 그대로 */ }
            else              ay = (ay - 0.5f) * aspect + 0.5f;
            const float gy = 1.f - ay * 2.f;
            if (gx >= -1.f && gx <= 1.f) { glVertex2f(gx, -1.f); glVertex2f(gx, 1.f); }
            if (gy >= -1.f && gy <= 1.f) { glVertex2f(-1.f, gy); glVertex2f(1.f, gy); }
            (void)by;
        }
        glEnd();
        glDisable(GL_BLEND);
        glColor4f(1.f, 1.f, 1.f, 1.f);
    }
}
