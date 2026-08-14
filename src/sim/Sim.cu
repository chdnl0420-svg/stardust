// 시뮬레이션 코어 구현 — Core 층. **3D**.
//
// 알갱이는 3차원으로 움직이고 화면만 위에서 내려다본다. 2D 로 풀 때는 별이 위아래로
// 진동할 자유도가 없어 원반의 면밀도가 그대로 뭉쳤고, 나선팔이 자라기 전에 조각났다.
// 그 자유도를 주는 것이 3D 로 옮기는 이유다.
//
// 한 스텝의 흐름:
//   (K스텝마다) 셀키 -> radix sort -> 재배치      : 캐시 지역성 회복. 성능 목적
//   격자 비우기 -> CIC 산란                        : 알갱이 질량을 격자 **8칸**에 나눠 담는다
//   포아송 풀기                                    : 주기면 주파수공간 -1/k², 고립이면 패딩+그린함수
//   격자 가속도 -> CIC 보간 -> 속도·위치 적분
//   (접촉 켜짐) 이웃 27칸을 훑어 겹친 것을 밀어낸다
//
// 격자가 세제곱으로 자라므로 한 변의 상한이 2D 보다 훨씬 낮다.
//   고립 경계 : 한 변 256 (패딩 때문에 실제로 512³ 을 잡는다)
//   주기 경계 : 한 변 512
//
// **커널마다 한 프레임에 몇 번 도는지를 적어 둔다.** 이 계산을 빠뜨리면 카드가 죽는다 —
// 2026-08-14 에 그리기 커널 하나가 알갱이당 625 픽셀을 칠하다 드라이버를 무너뜨렸고
// 시스템이 통째로 재부팅됐다. N=알갱이 수, G=격자 한 변, S=패딩 포함 한 변이다.
//
// 용어:
//   CIC(Cloud-In-Cell) : 알갱이 하나를 가장 가까운 격자 8칸에 거리 가중치로 나눠 담는 방식.
//   포아송 방정식       : "질량이 이렇게 분포하면 중력장이 어떻게 생기나"를 주는 식.
//   FFT                : 신호를 파동의 겹침으로 바꾸는 변환. 모든 칸이 모든 칸에 미치는
//                        영향을 한 번에 처리할 수 있다.
//   그린함수            : 점 하나가 주변에 만드는 장(場)의 모양. 밀도와 합성곱하면 전체 장이 나온다.
#include "Sim.h"

#include <cuda_runtime.h>
#include <cufft.h>
#include <cub/cub.cuh>
// CUDA 13(CCCL 3.x)에서 cub::TransformInputIterator·CountingInputIterator 가 제거돼 thrust 쪽을 쓴다.
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/counting_iterator.h>

#include <cmath>
#include <cstdio>
#include <vector>

// ---------------------------------------------------------------------------
// 오류 처리 — 코어는 조용히 기본값을 돌려주지 않는다. 실패를 표시하고 상위가 알게 한다.
//
// 한 번이라도 실패하면 g_failed 를 세우고 그 뒤로는 커널을 더 띄우지 않는다.
// 할당이 실패하면 그 포인터는 null 이라 다음 커널이 null 을 건드려 드라이버가 컨텍스트를
// 통째로 버린다. 그러면 이후 모든 호출이 연쇄로 실패하고, 화면에는 "아무 일도 안 일어나는 앱"만
// 남아 원인을 못 찾는다(round-06 리뷰 P1 #7).
// ---------------------------------------------------------------------------
namespace {
bool g_failed = false;
char g_failMsg[256] = { 0 };

void markFailure(const char* what, const char* file, int line) {
    if (!g_failed) {                    // 첫 실패만 남긴다 — 뒤따르는 연쇄 실패는 원인이 아니다
        g_failed = true;
        snprintf(g_failMsg, sizeof(g_failMsg), "%s (%s:%d)", what, file, line);
    }
    printf("[sim] CUDA error %s:%d %s\n", file, line, what);
}
} // namespace

#define CK(x)  do { cudaError_t e_ = (x); if (e_ != cudaSuccess) {                      \
                    markFailure(cudaGetErrorString(e_), __FILE__, __LINE__); }          \
               } while (0)

#define FK(x)  do { cufftResult r_ = (x); if (r_ != CUFFT_SUCCESS) {                    \
                    char m_[64]; snprintf(m_, sizeof(m_), "cuFFT error %d", (int)r_);   \
                    markFailure(m_, __FILE__, __LINE__); }                              \
               } while (0)

namespace {

__device__ __forceinline__ unsigned pcgHash(unsigned v) {
    unsigned s = v * 747796405u + 2891336453u;
    unsigned w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
__device__ __forceinline__ float rnd01(unsigned s) {
    return pcgHash(s) * 2.3283064365386963e-10f;
}
// 평균 0, 표준편차 1 인 난수 한 쌍 중 하나. 두께·속도 분산에 쓴다.
__device__ __forceinline__ float rndNormal(unsigned s) {
    const float u1 = fmaxf(rnd01(s), 1e-7f);
    const float u2 = rnd01(s ^ 0x9E3779B9u);
    return sqrtf(-2.0f * __logf(u1)) * __cosf(6.2831853f * u2);
}

// 3D 격자 인덱스. 주기면 반대편으로 감고, 고립이면 가장자리에 붙인다.
// 한 변이 2의 거듭제곱이라 wrap 을 나눗셈 없이 비트 마스크로 처리한다.
__device__ __forceinline__ int gidx3(int x, int y, int z, int G, int S, int periodic) {
    if (periodic) { x &= (G - 1); y &= (G - 1); z &= (G - 1); }
    else          { x = min(max(x, 0), G - 1); y = min(max(y, 0), G - 1); z = min(max(z, 0), G - 1); }
    return (z * S + y) * S + x;
}

// ---------------------------------------------------------------------------
// 초기 배치
// ---------------------------------------------------------------------------

// 나선 은하의 한 점(원반 면 위). 로그 나선을 쓴다 — 실제 은하의 팔이 그 모양이다.
// 반지름이 커질수록 각이 로그로 밀리고, 팔 둘을 반 바퀴 어긋나게 둔다.
__device__ __forceinline__ float2 spiralPoint(float R, float u1, float u2, float u3) {
    const float t = 0.08f + 0.92f * sqrtf(u1);
    const float r = R * t;
    const float arm = (u3 < 0.5f) ? 0.f : 3.14159265f;
    const float th = arm + 3.2f * __logf(t + 0.12f);
    const float spread = 0.85f * (1.0f - t) + 0.16f;
    const float g = (u2 + rnd01((unsigned)(u1 * 65536.0f) * 7919u + 13u) - 1.0f);
    return make_float2(r * __cosf(th + g * spread), r * __sinf(th + g * spread));
}

// 팽대부의 한 점 — 가운데가 빽빽한 공. r = R·u² 로 중심에 몰아 넣는다.
__device__ __forceinline__ float3 bulgePoint(float R, unsigned seed) {
    const float u = rnd01(seed);
    const float r = R * u * u;
    // 구 위에 고르게 뿌리려면 z 를 균등하게 뽑고 그 위도의 원에서 각을 뽑는다.
    const float cz = rnd01(seed * 3u + 1u) * 2.0f - 1.0f;
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(seed * 7u + 5u) * 6.2831853f;
    return make_float3(r * sz * __cosf(ph), r * sz * __sinf(ph), r * cz);
}

// 알갱이를 처음 놓는다.
//
// 비용: N 스레드 × O(1). 한 프레임이 아니라 판을 새로 깔 때 한 번만 돈다.
__global__ void kPlace(float4* pos, float4* vel, float* temp, int n, int preset,
                       float bulgeFrac, float bulgeR, float thickness, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);
    float x = 0.5f, y = 0.5f, z = 0.5f;

    if (preset == 0 || preset == 3) {            // 나선 은하 · 블랙홀
        const float R = 0.30f;
        if (u3 < bulgeFrac) {
            const float3 b = bulgePoint(bulgeR, s ^ 0x51ED2701u);
            x = 0.5f + b.x; y = 0.5f + b.y; z = 0.5f + b.z;
        } else {
            const float2 p = spiralPoint(R, u1, u2, rnd01(s * 11u + 3u));
            x = 0.5f + p.x; y = 0.5f + p.y;
            // 원반은 얇다. 두께를 정규분포로 주면 가장자리가 흐릿하게 사그라든다.
            z = 0.5f + rndNormal(s ^ 0x2545F491u) * thickness;
        }
    } else if (preset == 1) {                    // 은하 충돌 — 나선 둘이 양옆에서
        const int side = (i & 1);
        const float cx = side ? 0.72f : 0.28f;
        const float R = 0.20f;
        if (u3 < bulgeFrac) {
            const float3 b = bulgePoint(bulgeR * 0.8f, s ^ 0x51ED2701u);
            x = cx + b.x; y = 0.5f + b.y; z = 0.5f + b.z;
        } else {
            const float2 p = spiralPoint(R, u1, u2, rnd01(s * 11u + 3u));
            x = cx + p.x; y = 0.5f + p.y;
            z = 0.5f + rndNormal(s ^ 0x2545F491u) * thickness;
        }
    } else if (preset == 2) {                    // 우주 거미줄 — 공간 전체에 고르게 + 잔물결
        x = u1; y = u2; z = u3;
        // 아주 작은 요동을 얹는다. 완전히 고르면 중력이 자랄 씨앗이 없다.
        const float k = 6.2831853f * 4.0f;
        x += 0.010f * __sinf(k * u2 + 1.3f);
        y += 0.010f * __sinf(k * u3 + 2.1f);
        z += 0.010f * __sinf(k * u1 + 0.7f);
    } else {                                     // 빈 판
        pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
        if (temp) temp[i] = 0.f;
        return;
    }

    pos[i] = make_float4(x, y, z, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
    if (temp) temp[i] = 0.02f;
}

// 격자 중력을 한 번 푼 뒤, 그 자리에서 원 궤도가 되는 속도를 넣는다.
//
// 속도를 임의로 정하면 원반이 흩어진다 — 그 자리 중력이 얼마인지 재서 정해야 한다.
// 회전은 xy 평면에서 일어난다(원반의 축이 z 다).
//
// 비용: N 스레드 × O(1). 판을 깔 때 한 번.
__global__ void kSetOrbit(const float4* accG_unused, float4* vel, const float4* pos,
                          const float* accMag, int n, float dispersion,
                          float bulgeR, float2 base, float thickness) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) { vel[i] = make_float4(base.x, base.y, 0.f, 0.f); return; }

    // a = v²/r 에서 v = √(a·r). accMag 는 그 자리에서 잰 중심 방향 가속도 크기다.
    const float v = sqrtf(fmaxf(accMag[i], 0.f) * r);

    // 팽대부에 가까울수록 회전보다 흩어짐이 지배한다 — 실제 은하의 중심부가 그렇다.
    const float bulgeMix = (bulgeR > 0.f) ? __expf(-(r * r) / (bulgeR * bulgeR)) : 0.f;
    const float disp = dispersion + 0.85f * bulgeMix;
    const float spin = 1.0f - 0.55f * bulgeMix;

    const unsigned s = (unsigned)i * 22695477u + 7u;
    const float g1 = rndNormal(s), g2 = rndNormal(s ^ 0xA341316Cu), g3 = rndNormal(s ^ 0x1B873593u);

    // 위아래 속도는 원반 두께에 맞춘다. 두께에 견줘 너무 빠르면 원반이 부풀어 사라진다.
    const float vz = g3 * v * fminf(thickness * 8.0f, 0.35f);
    vel[i] = make_float4(-dy / r * v * spin + g1 * v * disp + base.x,
                          dx / r * v * spin + g2 * v * disp + base.y,
                          vz, 0.f);
}

// ---------------------------------------------------------------------------
// 격자
// ---------------------------------------------------------------------------

__global__ void kClearF(float* a, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = 0.f;
}
__global__ void kFillInt(int* a, int n, int v) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = v;
}

// CIC 산란 — 알갱이 하나를 이웃 **8칸**에 거리 가중치로 나눠 담는다.
//
// 비용: N 스레드 × 8 atomicAdd = 8N. N=200만이면 1600만 회.
__global__ void kScatter(const float4* pos, int n, float* grid, int G, int S, int periodic) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float gx = p.x * G - 0.5f, gy = p.y * G - 0.5f, gz = p.z * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy), iz = (int)floorf(gz);
    const float fx = gx - ix, fy = gy - iy, fz = gz - iz;

    for (int k = 0; k < 8; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
        // 고립 경계에서는 범위 밖 가중치를 버리지 않고 가장자리 칸에 얹는다.
        // 버리면 판 끝에 붙은 알갱이의 질량 일부가 사라진다 — 적분기가 알갱이를 판 안에
        // 붙잡아 두므로 질량도 판 안에 남아 있어야 앞뒤가 맞는다.
        atomicAdd(&grid[gidx3(ix + ox, iy + oy, iz + oz, G, S, periodic)], w);
    }
}

// 주기 경계용 주파수공간 커널. 3D 에서 뉴턴 중력은 -1/k² 다.
//
// 2D 판에서는 1/k 를 곱해 3D 형 1/r² 힘을 흉내 냈지만, 진짜 3D 에서는 그럴 필요가 없다.
//
// 비용: (G/2+1)·G² 스레드 × O(1).
__global__ void kPoissonPeriodic(cufftComplex* F, int G, float scale) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    const int H = G / 2 + 1;
    if (x >= H || y >= G || z >= G) return;

    const int ky = (y <= G / 2) ? y : y - G;
    const int kz = (z <= G / 2) ? z : z - G;
    const float k2 = (float)(x * x + ky * ky + kz * kz);
    const int idx = (z * G + y) * H + x;
    if (k2 < 1e-6f) { F[idx].x = 0.f; F[idx].y = 0.f; return; }   // 평균값은 힘에 기여하지 않는다
    const float m = -scale / k2;
    F[idx].x *= m; F[idx].y *= m;
}

// 고립 경계용 그린함수를 실공간에 만든다. g(r) = -1/r, 아주 가까운 곳은 소프트닝으로 막는다.
// 패딩 격자의 네 귀퉁이(각 축의 양끝)에서 거리를 재야 합성곱이 순환하지 않는다.
//
// 비용: S³ 스레드 × O(1). S=2G. 판을 깔 때 한 번만 돈다.
__global__ void kGreen(float* g, int S, int G, float soft) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= S || y >= S || z >= S) return;
    const int dx = (x <= S / 2) ? x : S - x;
    const int dy = (y <= S / 2) ? y : S - y;
    const int dz = (z <= S / 2) ? z : S - z;
    const float r = sqrtf((float)(dx * dx + dy * dy + dz * dz)) + soft;
    g[(z * S + y) * S + x] = -1.0f / r;
}

// 두 주파수공간 배열을 곱한다(합성곱). 배율은 FFT 정규화까지 함께 실는다.
//
// 비용: (S/2+1)·S² 스레드 × O(1).
__global__ void kMulSpec(cufftComplex* a, const cufftComplex* b, int n, float scale) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const cufftComplex x = a[i], y = b[i];
    a[i].x = (x.x * y.x - x.y * y.y) * scale;
    a[i].y = (x.x * y.y + x.y * y.x) * scale;
}

// 퍼텐셜의 기울기를 격자 가속도로 만든다(중앙차분).
//
// 비용: G³ 스레드 × O(1). G=128 이면 200만 회.
__global__ void kGridAccel(const float* pot, float4* accG, int G, int S,
                           float potScale, int periodic) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;

    int xm, xp, ym, yp, zm, zp;
    if (periodic) {
        xm = (x - 1) & (G - 1); xp = (x + 1) & (G - 1);
        ym = (y - 1) & (G - 1); yp = (y + 1) & (G - 1);
        zm = (z - 1) & (G - 1); zp = (z + 1) & (G - 1);
    } else {
        xm = max(x - 1, 0); xp = min(x + 1, G - 1);
        ym = max(y - 1, 0); yp = min(y + 1, G - 1);
        zm = max(z - 1, 0); zp = min(z + 1, G - 1);
    }
    const float h = 0.5f * G * potScale;
    const float ax = -(pot[(z * S + y) * S + xp] - pot[(z * S + y) * S + xm]) * h;
    const float ay = -(pot[(z * S + yp) * S + x] - pot[(z * S + ym) * S + x]) * h;
    const float az = -(pot[(zp * S + y) * S + x] - pot[(zm * S + y) * S + x]) * h;
    accG[(z * G + y) * G + x] = make_float4(ax, ay, az, 0.f);
}

// 격자 가속도를 알갱이 자리로 되읽는다(CIC 8칸).
__device__ __forceinline__ float4 sampleAcc(const float4* accG, float4 p, int G, int periodic) {
    const float gx = p.x * G - 0.5f, gy = p.y * G - 0.5f, gz = p.z * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy), iz = (int)floorf(gz);
    const float fx = gx - ix, fy = gy - iy, fz = gz - iz;
    float4 a = make_float4(0.f, 0.f, 0.f, 0.f);
    for (int k = 0; k < 8; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
        int cx = ix + ox, cy = iy + oy, cz = iz + oz;
        if (periodic) { cx &= (G - 1); cy &= (G - 1); cz &= (G - 1); }
        else { cx = min(max(cx, 0), G - 1); cy = min(max(cy, 0), G - 1); cz = min(max(cz, 0), G - 1); }
        const float4 g = accG[(cz * G + cy) * G + cx];
        a.x += g.x * w; a.y += g.y * w; a.z += g.z * w;
    }
    return a;
}

// 가속도 크기만 필요할 때(궤도 속도 정하기).
//
// 비용: N 스레드 × 8칸 보간.
__global__ void kAccelMag(const float4* accG, const float4* pos, float* out,
                          int n, int G, int periodic) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) { out[i] = 0.f; return; }
    const float4 a = sampleAcc(accG, p, G, periodic);
    // 원반 회전에 쓰는 것은 중심을 향한 **수평** 성분이다. 위아래 성분은 회전과 무관하다.
    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    out[i] = (r > 1e-5f) ? fmaxf(-(a.x * dx + a.y * dy) / r, 0.f) : 0.f;
}

// 속도와 위치를 한 스텝 나아가게 한다.
//
// 비용: N 스레드 × 8칸 보간. N=200만이면 1600만 번의 격자 읽기.
__global__ void kIntegrate(const float4* accG, float4* pos, float4* vel,
                           int n, int G, float dt, int periodic,
                           int blackHole, float bhGM, float bhRs,
                           float bhX, float bhY, float bhZ, float c2, int* eaten,
                           float haloV2, float haloCore2,
                           const float4* accContact) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;
    float4 v = vel[i];

    float4 a = sampleAcc(accG, p, G, periodic);
    if (accContact) { const float4 c = accContact[i]; a.x += c.x; a.y += c.y; a.z += c.z; }

    // 보이지 않는 무게(암흑물질 헤일로) — 유사등온구. 바깥에서 회전 속도가 평평해진다.
    //   a(r) = -v₀²·r⃗ / (r² + rc²)
    if (haloV2 > 0.f) {
        const float hx = p.x - 0.5f, hy = p.y - 0.5f, hz = p.z - 0.5f;
        const float denom = hx * hx + hy * hy + hz * hz + haloCore2;
        a.x -= haloV2 * hx / denom;
        a.y -= haloV2 * hy / denom;
        a.z -= haloV2 * hz / denom;
    }

    // 블랙홀 — 휘어진 시공간의 최단경로. 슈바르츠실트 해의 운동을 그대로 적분한다.
    //   a = -GM/r³ · (1 + 3L²/(c²r²)) · r⃗
    // 뒤의 괄호가 상대론 보정이라, 이것 하나로 광자 구면과 최소 안정 궤도가 저절로 나온다.
    if (blackHole) {
        const float dx = p.x - bhX, dy = p.y - bhY, dz = p.z - bhZ;
        const float r2 = dx * dx + dy * dy + dz * dz;
        const float r = sqrtf(fmaxf(r2, 1e-12f));
        if (r <= bhRs) {                       // 지평선 안으로 들어왔다 — 삼킨다
            atomicAdd(eaten, 1);
            pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
            vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
            return;
        }
        // 각운동량 L = |r × v|
        const float lx = dy * v.z - dz * v.y;
        const float ly = dz * v.x - dx * v.z;
        const float lz = dx * v.y - dy * v.x;
        const float L2 = lx * lx + ly * ly + lz * lz;
        const float corr = 1.0f + 3.0f * L2 / fmaxf(c2 * r2, 1e-12f);
        const float m = -bhGM * corr / (r2 * r);
        a.x += m * dx; a.y += m * dy; a.z += m * dz;
    }

    v.x += a.x * dt; v.y += a.y * dt; v.z += a.z * dt;
    p.x += v.x * dt; p.y += v.y * dt; p.z += v.z * dt;

    // 숫자가 한 번 깨지면 그 알갱이는 영영 돌아오지 않고, 격자를 통해 이웃까지 오염시킨다.
    // 발견 즉시 빈 슬롯으로 돌린다.
    if (!isfinite(p.x) || !isfinite(p.y) || !isfinite(p.z) ||
        !isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) {
        pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
        return;
    }

    if (periodic) {
        p.x -= floorf(p.x); p.y -= floorf(p.y); p.z -= floorf(p.z);
    } else {
        // 고립 경계에서는 판 밖으로 못 나가게 붙잡고 속도를 죽인다.
        if (p.x < 0.002f) { p.x = 0.002f; v.x = fabsf(v.x) * 0.25f; }
        if (p.x > 0.998f) { p.x = 0.998f; v.x = -fabsf(v.x) * 0.25f; }
        if (p.y < 0.002f) { p.y = 0.002f; v.y = fabsf(v.y) * 0.25f; }
        if (p.y > 0.998f) { p.y = 0.998f; v.y = -fabsf(v.y) * 0.25f; }
        if (p.z < 0.002f) { p.z = 0.002f; v.z = fabsf(v.z) * 0.25f; }
        if (p.z > 0.998f) { p.z = 0.998f; v.z = -fabsf(v.z) * 0.25f; }
    }
    pos[i] = p; vel[i] = v;
}

// ---------------------------------------------------------------------------
// 알갱이끼리의 접촉 (강체)
//
// 격자로 계산하는 중력만으로는 알갱이가 서로 그냥 통과한다. 격자 한 칸보다 작은 것은
// 없는 것과 같아서, 같은 칸에 있는 둘은 서로에게 아무 힘도 주지 않기 때문이다.
// 겹치면 밀어내고 부딪히면 에너지를 잃게 하면, 모이다가 더 못 눌리는 지점에서 멈춘다.
// ---------------------------------------------------------------------------

// 셀 순서로 정렬된 키에서 각 칸의 [시작, 끝) 구간을 뽑는다.
__global__ void kBuildCellRange(const int* keys, int n, int* start, int* end) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const int k = keys[i];
    if (k < 0) return;
    if (i == 0 || keys[i - 1] != k) start[k] = i;
    if (i == n - 1 || keys[i + 1] != k) end[k] = i + 1;
}

// 이웃 27칸을 훑어 겹친 알갱이를 밀어낸다.
//
// 비용: N 스레드 × 27칸 × (칸당 알갱이 수). 2D 의 9칸에서 27칸으로 세 배가 됐다.
// 칸당 평균 알갱이가 1 을 크게 넘으면 이 커널이 프레임을 통째로 먹으므로,
// 접촉을 켤 수 있는 알갱이 수를 밖에서 제한한다(App::ContactFitsCount).
// 안전을 위해 한 칸에서 보는 상대 수에도 상한을 둔다 — 뭉친 자리에서 폭주하지 않게.
__global__ void kContact(const float4* pos, const float4* vel, int n, int G, int S,
                         int periodic, const int* cellStart, const int* cellEnd,
                         float radius, float stiffness, float damping, float4* accOut) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    float4 a = make_float4(0.f, 0.f, 0.f, 0.f);
    if (p.x < 0.f) { accOut[i] = a; return; }
    const float4 v = vel[i];

    const float d0 = radius * 2.0f;     // 이보다 가까우면 겹친 것이다
    const float d02 = d0 * d0;
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);

    // 한 알갱이가 이번 스텝에 상대할 수 있는 최대 수. 이 상한이 없으면 뭉친 칸 하나가
    // 스레드 하나를 수천 번 돌게 만들어 프레임이 통째로 멎는다.
    const int kMaxPeers = 96;
    int seen = 0;

    for (int dz = -1; dz <= 1 && seen < kMaxPeers; ++dz)
    for (int dy = -1; dy <= 1 && seen < kMaxPeers; ++dy)
    for (int dx = -1; dx <= 1 && seen < kMaxPeers; ++dx) {
        const int c = gidx3(cx + dx, cy + dy, cz + dz, G, G, periodic);
        const int s0 = cellStart[c], e0 = cellEnd[c];
        if (s0 < 0 || e0 <= s0) continue;
        for (int j = s0; j < e0 && seen < kMaxPeers; ++j) {
            if (j == i) continue;
            ++seen;
            const float4 q = pos[j];
            if (q.x < 0.f) continue;
            float ex = p.x - q.x, ey = p.y - q.y, ez = p.z - q.z;
            if (periodic) {   // 반대편으로 감아 가까운 쪽을 본다
                if (ex >  0.5f) ex -= 1.f; else if (ex < -0.5f) ex += 1.f;
                if (ey >  0.5f) ey -= 1.f; else if (ey < -0.5f) ey += 1.f;
                if (ez >  0.5f) ez -= 1.f; else if (ez < -0.5f) ez += 1.f;
            }
            const float dd = ex * ex + ey * ey + ez * ez;
            if (dd >= d02 || dd < 1e-16f) continue;
            const float d = sqrtf(dd);
            const float nx = ex / d, ny = ey / d, nz = ez / d;
            const float4 vj = vel[j];
            // 다가오는 속도 성분만 감쇠한다 — 멀어지는 것을 붙잡으면 끈끈이가 된다.
            const float vn = (v.x - vj.x) * nx + (v.y - vj.y) * ny + (v.z - vj.z) * nz;
            float f = stiffness * (d0 - d) - damping * vn;
            if (f < 0.f) f = 0.f;               // 밀기만 한다
            a.x += f * nx; a.y += f * ny; a.z += f * nz;
        }
    }
    accOut[i] = a;
}

// 셀 키(정렬용). 빈 슬롯은 -1 로 두어 뒤로 밀린다.
__global__ void kCellKey(const float4* pos, int n, int G, int* keys, int* idx) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    idx[i] = i;
    if (p.x < 0.f) { keys[i] = -1; return; }
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    keys[i] = (cz * G + cy) * G + cx;
}

__global__ void kReorder(const float4* srcP, const float4* srcV, const float* srcT,
                         const int* order, float4* dstP, float4* dstV, float* dstT, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const int j = order[i];
    dstP[i] = srcP[j]; dstV[i] = srcV[j];
    if (srcT && dstT) dstT[i] = srcT[j];
}

// ---------------------------------------------------------------------------
// 화면에 넘길 2D 투영
//
// 화면은 위에서 내려다본다. 3D 밀도를 z 방향으로 합치면 「위에서 본 밀도」가 된다 —
// 실제 은하 사진이 그렇게 찍힌다(시선 방향으로 다 겹쳐 보인다).
//
// 비용: G³ 스레드 × 1 atomicAdd. G=128 이면 200만 회.
// ---------------------------------------------------------------------------
__global__ void kProjectXY(const float* grid3, float* out2, int G, int S) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;
    atomicAdd(&out2[y * G + x], grid3[(z * S + y) * S + x]);
}

// ---------------------------------------------------------------------------
// 측정
// ---------------------------------------------------------------------------
__global__ void kCountOccupied(const float* g, int n, int* out, float eps) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && g[i] > eps) atomicAdd(out, 1);
}

// 질량중심. 화면이 xy 만 보므로 x, y 만 모은다.
__global__ void kCentroidAccum(const float4* pos, int n, double* sx, double* sy, int* cnt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    atomicAdd(sx, (double)p.x);
    atomicAdd(sy, (double)p.y);
    atomicAdd(cnt, 1);
}

// 가장 빽빽한 칸을 찾는다. 밀도를 위쪽 32비트에 실어 64비트 최댓값 하나로 겨룬다 —
// 밀도와 칸 번호를 한 번에 비교할 수 있어 두 번 훑지 않아도 된다.
__global__ void kFindDensestCell(const float* g, int G, int S, unsigned long long* out) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;
    const float d = g[(z * S + y) * S + x];
    if (d <= 0.f) return;
    const unsigned long long key = ((unsigned long long)(unsigned)(d * 256.0f) << 32)
                                 | (unsigned long long)(unsigned)((z * G + y) * G + x);
    atomicMax(out, key);
}

// 살아 있는 알갱이를 앞으로 모은다(지우개가 만든 구멍 메우기).
__global__ void kMarkAlive(const float4* pos, int n, int* flag) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) flag[i] = (pos[i].x >= 0.f) ? 1 : 0;
}
__global__ void kCompact(const float4* sp, const float4* sv, const float* st,
                         const int* flag, const int* scan, int n,
                         float4* dp, float4* dv, float* dt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || !flag[i]) return;
    const int j = scan[i];
    dp[j] = sp[i]; dv[j] = sv[i];
    if (st && dt) dt[j] = st[i];
}
__global__ void kHideRange(float4* pos, float4* vel, int from, int to) {
    const int i = from + blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= to) return;
    pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
}

// ---------------------------------------------------------------------------
// 마우스 도구
// ---------------------------------------------------------------------------

// 형태 하나를 빈 슬롯 구간에 채운다. 화면이 xy 를 보므로 두께는 얇게 준다.
__global__ void kFillShape(float4* pos, float4* vel, float* temp, int from, int count,
                           float cx, float cy, int kind, float R, float thickness,
                           unsigned seed) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= count) return;
    const int i = from + t;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);

    float x, y, z = 0.5f + rndNormal(s ^ 0x2545F491u) * thickness;
    float temp0 = 0.02f;

    if (kind == 0) {                       // 은하 — 도는 원반
        const float2 p = spiralPoint(R, u1, u2, u3);
        x = cx + p.x; y = cy + p.y;
    } else if (kind == 1) {                // 태양 — 가운데로 갈수록 빽빽하고 뜨겁다
        const float3 b = bulgePoint(R, s);
        x = cx + b.x; y = cy + b.y; z = 0.5f + b.z;
        temp0 = 0.6f;
    } else if (kind == 2) {                // 고리 — 가운데가 빈 도넛
        const float th = u1 * 6.2831853f;
        const float r = R * (0.72f + 0.22f * u2);
        x = cx + r * __cosf(th); y = cy + r * __sinf(th);
    } else if (kind == 3) {                // 구름 — 넓게 퍼진 차가운 성운
        const float3 b = bulgePoint(R * 1.4f, s);
        x = cx + b.x * 1.6f; y = cy + b.y * 1.6f; z = 0.5f + b.z * 1.6f;
    } else {                               // 덩어리 — 속도 0. 그대로 무너지는 것을 본다
        const float th = u1 * 6.2831853f;
        const float r = R * sqrtf(u2);
        x = cx + r * __cosf(th); y = cy + r * __sinf(th);
    }

    pos[i] = make_float4(x, y, z, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
    if (temp) temp[i] = temp0;
}

// 방금 넣은 구간에만 궤도 속도를 준다.
__global__ void kSetOrbitAt(float4* vel, const float4* pos, const float* accMag,
                            int from, int count, float cx, float cy) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= count) return;
    const int i = from + t;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - cx, dy = p.y - cy;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) return;
    const float v = sqrtf(fmaxf(accMag[i], 0.f) * r);
    vel[i] = make_float4(-dy / r * v, dx / r * v, 0.f, 0.f);
}

// 브러시 — 밀어내기(strength>0) 또는 끌어당기기(strength<0).
__global__ void kBrushPush(float4* pos, float4* vel, int n, float cx, float cy,
                           float radius, float strength) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    // 화면에서 고른 자리라 깊이(z)는 판 가운데를 기준으로 본다.
    const float dx = p.x - cx, dy = p.y - cy, dz = p.z - 0.5f;
    const float d2 = dx * dx + dy * dy + dz * dz;
    if (d2 > radius * radius) return;
    const float d = sqrtf(fmaxf(d2, 1e-12f));
    const float w = 1.0f - d / radius;
    float4 v = vel[i];
    v.x += strength * w * dx / d;
    v.y += strength * w * dy / d;
    v.z += strength * w * dz / d;
    vel[i] = v;
}

// 지우개 — 브러시 안의 알갱이를 지우고 개수를 센다.
__global__ void kEraseIn(float4* pos, float4* vel, int n, float cx, float cy,
                         float radius, int* count) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - cx, dy = p.y - cy;
    if (dx * dx + dy * dy > radius * radius) return;   // 화면에서 고르므로 깊이는 보지 않는다
    pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
    atomicAdd(count, 1);
}

// 가장 빠른 알갱이의 속력(CFL 조건에 쓴다).
__global__ void kMaxSpeed(const float4* vel, const float4* pos, int n, float* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (pos[i].x < 0.f) return;
    const float4 v = vel[i];
    const float s = sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);
    atomicMax((int*)out, __float_as_int(s));   // 속력은 음수가 아니라 정수 비교가 그대로 통한다
}

} // namespace

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------
struct Sim::Impl {
    SimConfig cfg;
    SimTimings tm;
    double simTime = 0.0;

    float4 *pos = nullptr, *vel = nullptr;
    float4 *posTmp = nullptr, *velTmp = nullptr;
    float  *temp = nullptr, *tempTmp = nullptr;
    float4 *accG = nullptr;          // 격자 가속도 G³
    float4 *accContact = nullptr;    // 접촉 가속도 N
    float  *rho = nullptr;           // 밀도(패딩 포함) S³
    float  *pot = nullptr;           // 퍼텐셜(패딩 포함) S³
    float  *proj = nullptr;          // 화면에 넘길 2D 투영 G²
    float  *accMag = nullptr;        // 궤도 속도용 N

    cufftComplex *specRho = nullptr, *specGreen = nullptr;
    cufftHandle planR2C = 0, planC2R = 0;
    bool planReady = false;

    int *keys = nullptr, *order = nullptr, *cellStart = nullptr, *cellEnd = nullptr;
    int *flag = nullptr, *scan = nullptr;
    void *sortTmp = nullptr; size_t sortTmpBytes = 0;
    void *redTmp = nullptr;  size_t redTmpBytes = 0;
    double *redD = nullptr;
    int    *redI = nullptr;
    unsigned long long *redU = nullptr;
    float  *redF = nullptr;

    int allocN = 0, allocG = 0;
    Boundary allocBoundary = Boundary::Isolated;
    int requestedN = -1, requestedG = -1;
    Boundary requestedBoundary = Boundary::Isolated;

    int active = 0;
    int stepCount = 0;
    BlackHoleState bh;
    int *eaten = nullptr;

    cudaEvent_t evA = nullptr, evB = nullptr;

    // 패딩 포함 한 변. 고립 경계는 합성곱이 반대편으로 감기지 않게 두 배로 잡는다.
    int  stride() const { return (cfg.boundary == Boundary::Isolated) ? allocG * 2 : allocG; }
    size_t padCells() const { const size_t s = (size_t)stride(); return s * s * s; }
    bool periodic() const { return cfg.boundary == Boundary::Periodic; }

    // 격자 퍼텐셜을 가속도로 바꿀 때 곱하는 배율.
    // 알갱이 하나의 질량을 1/N 로 둔다 — 그래야 총질량이 1 로 고정되어 개수를 바꿔도
    // 중력의 세기가 그대로다.
    float potScale() const {
        return cfg.gravity / (float)(allocN > 0 ? allocN : 1);
    }
    float horizonOf(float eatenCount) const {
        const float M = eatenCount / (float)(allocN > 0 ? allocN : 1);
        return 2.0f * cfg.gravity * M / fmaxf(cfg.lightSpeedSq, 1e-6f);
    }

    void freeAll();
    void allocate();
    void buildGreen();
    void solvePoisson();
    void scatterMass();
    void computeAccel();
    void placeInitial();
    void giveOrbits();
    void sortParticles();
    void doContact();
    void checkCollapse();
};

namespace {
// 3D 커널을 띄울 때 쓰는 블록 모양. 8×8×8 = 512 스레드.
inline dim3 blk3() { return dim3(8, 8, 8); }
inline dim3 grd3(int G) { return dim3((G + 7) / 8, (G + 7) / 8, (G + 7) / 8); }
} // namespace

void Sim::Impl::freeAll() {
    auto F = [](void*& p) { if (p) { cudaFree(p); p = nullptr; } };
    F((void*&)pos); F((void*&)vel); F((void*&)posTmp); F((void*&)velTmp);
    F((void*&)temp); F((void*&)tempTmp);
    F((void*&)accG); F((void*&)accContact); F((void*&)rho); F((void*&)pot);
    F((void*&)proj); F((void*&)accMag);
    F((void*&)specRho); F((void*&)specGreen);
    F((void*&)keys); F((void*&)order); F((void*&)cellStart); F((void*&)cellEnd);
    F((void*&)flag); F((void*&)scan);
    F(sortTmp); F(redTmp);
    F((void*&)redD); F((void*&)redI); F((void*&)redU); F((void*&)redF);
    F((void*&)eaten);
    sortTmpBytes = 0; redTmpBytes = 0;
    if (planReady) { cufftDestroy(planR2C); cufftDestroy(planC2R); planReady = false; }
}

void Sim::Impl::allocate() {
    freeAll();
    const int N = allocN, G = allocG, S = stride();
    const size_t cells = padCells();
    const size_t spec = (size_t)S * S * (S / 2 + 1);

    CK(cudaMalloc(&pos, sizeof(float4) * N));
    CK(cudaMalloc(&vel, sizeof(float4) * N));
    CK(cudaMalloc(&posTmp, sizeof(float4) * N));
    CK(cudaMalloc(&velTmp, sizeof(float4) * N));
    CK(cudaMalloc(&temp, sizeof(float) * N));
    CK(cudaMalloc(&tempTmp, sizeof(float) * N));
    CK(cudaMalloc(&accMag, sizeof(float) * N));
    CK(cudaMalloc(&accContact, sizeof(float4) * N));
    CK(cudaMalloc(&accG, sizeof(float4) * (size_t)G * G * G));
    CK(cudaMalloc(&rho, sizeof(float) * cells));
    CK(cudaMalloc(&pot, sizeof(float) * cells));
    CK(cudaMalloc(&proj, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&specRho, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&specGreen, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&keys, sizeof(int) * N));
    CK(cudaMalloc(&order, sizeof(int) * N));
    CK(cudaMalloc(&flag, sizeof(int) * N));
    CK(cudaMalloc(&scan, sizeof(int) * N));
    CK(cudaMalloc(&cellStart, sizeof(int) * (size_t)G * G * G));
    CK(cudaMalloc(&cellEnd, sizeof(int) * (size_t)G * G * G));
    CK(cudaMalloc(&redD, sizeof(double) * 2));
    CK(cudaMalloc(&redI, sizeof(int) * 2));
    CK(cudaMalloc(&redU, sizeof(unsigned long long)));
    CK(cudaMalloc(&redF, sizeof(float)));
    CK(cudaMalloc(&eaten, sizeof(int)));

    if (!g_failed) {
        FK(cufftPlan3d(&planR2C, S, S, S, CUFFT_R2C));
        FK(cufftPlan3d(&planC2R, S, S, S, CUFFT_C2R));
        planReady = !g_failed;
    }
    if (!evA) { CK(cudaEventCreate(&evA)); CK(cudaEventCreate(&evB)); }
}

// 고립 경계용 그린함수를 미리 변환해 둔다. 격자가 바뀔 때만 다시 만든다.
void Sim::Impl::buildGreen() {
    if (periodic() || g_failed || !planReady) return;
    const int S = stride();
    const float soft = fmaxf(cfg.softeningCells, 0.5f);
    kGreen<<<grd3(S), blk3()>>>(pot, S, allocG, soft);
    FK(cufftExecR2C(planR2C, pot, specGreen));
    CK(cudaGetLastError());
}

void Sim::Impl::scatterMass() {
    if (g_failed) return;
    const size_t cells = padCells();
    kClearF<<<(int)((cells + 255) / 256), 256>>>(rho, (int)cells);
    kScatter<<<(allocN + 255) / 256, 256>>>(pos, allocN, rho, allocG, stride(), periodic() ? 1 : 0);
    CK(cudaGetLastError());
}

void Sim::Impl::solvePoisson() {
    if (g_failed || !planReady) return;
    const int S = stride();
    const size_t spec = (size_t)S * S * (S / 2 + 1);
    const float norm = 1.0f / (float)((double)S * S * S);

    FK(cufftExecR2C(planR2C, rho, specRho));
    if (periodic()) {
        // 3D 뉴턴 중력은 주파수공간에서 -1/k² 다. 배율에 FFT 정규화를 함께 싣는다.
        const float scale = norm / (4.0f * 3.14159265f * 3.14159265f);
        dim3 b(8, 8, 8), g((S / 2 + 1 + 7) / 8, (S + 7) / 8, (S + 7) / 8);
        kPoissonPeriodic<<<g, b>>>(specRho, S, scale);
    } else {
        kMulSpec<<<(int)((spec + 255) / 256), 256>>>(specRho, specGreen, (int)spec, norm);
    }
    FK(cufftExecC2R(planC2R, specRho, pot));
    CK(cudaGetLastError());
}

void Sim::Impl::computeAccel() {
    if (g_failed) return;
    scatterMass();
    solvePoisson();
    kGridAccel<<<grd3(allocG), blk3()>>>(pot, accG, allocG, stride(), potScale(),
                                         periodic() ? 1 : 0);
    CK(cudaGetLastError());
}

void Sim::Impl::placeInitial() {
    if (g_failed) return;
    const int preset = (cfg.preset == Preset::SpiralDisk) ? 0
                     : (cfg.preset == Preset::TidalPair)  ? 1
                     : (cfg.preset == Preset::CosmicWeb)  ? 2
                     : (cfg.preset == Preset::BlackHole)  ? 3 : 4;
    kPlace<<<(allocN + 255) / 256, 256>>>(pos, vel, temp, allocN, preset,
                                          cfg.bulgeFraction, cfg.bulgeRadius,
                                          cfg.diskThickness, 12345u);
    CK(cudaGetLastError());
    active = (preset == 4) ? 0 : allocN;
}

void Sim::Impl::giveOrbits() {
    if (g_failed || cfg.preset == Preset::Empty || cfg.preset == Preset::CosmicWeb) return;
    computeAccel();
    kAccelMag<<<(allocN + 255) / 256, 256>>>(accG, pos, accMag, allocN, allocG,
                                             periodic() ? 1 : 0);
    // 은하 충돌은 둘을 서로에게 밀어 준다. 나머지는 제자리에서 돈다.
    const float2 base = make_float2(0.f, 0.f);
    kSetOrbit<<<(allocN + 255) / 256, 256>>>(accG, vel, pos, accMag, allocN,
                                             cfg.orbitDispersion, cfg.bulgeRadius, base,
                                             cfg.diskThickness);
    CK(cudaGetLastError());
}

void Sim::Impl::sortParticles() {
    if (g_failed || allocN <= 0) return;
    kCellKey<<<(allocN + 255) / 256, 256>>>(pos, allocN, allocG, keys, order);
    size_t need = 0;
    cub::DeviceRadixSort::SortPairs(nullptr, need, keys, keys, order, order, allocN);
    if (need > sortTmpBytes) {
        if (sortTmp) cudaFree(sortTmp);
        CK(cudaMalloc(&sortTmp, need));
        sortTmpBytes = need;
    }
    if (g_failed) return;
    cub::DeviceRadixSort::SortPairs(sortTmp, sortTmpBytes, keys, keys, order, order, allocN);
    kReorder<<<(allocN + 255) / 256, 256>>>(pos, vel, temp, order, posTmp, velTmp, tempTmp, allocN);
    std::swap(pos, posTmp); std::swap(vel, velTmp); std::swap(temp, tempTmp);
    CK(cudaGetLastError());
}

void Sim::Impl::doContact() {
    if (g_failed || !cfg.contactEnabled) return;
    const int G = allocG;
    const size_t cells = (size_t)G * G * G;
    // 정렬해 둬야 칸별 구간을 뽑을 수 있다.
    sortParticles();
    kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellStart, (int)cells, -1);
    kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellEnd, (int)cells, -1);
    kBuildCellRange<<<(allocN + 255) / 256, 256>>>(keys, allocN, cellStart, cellEnd);
    // 반지름은 격자 칸의 절반. 지름이 정확히 한 칸이라 이웃 27칸만 보면 충분하다.
    const float radius = 0.5f / (float)G;
    kContact<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, G, periodic() ? 1 : 0,
                                            cellStart, cellEnd, radius,
                                            cfg.contactStiffness, cfg.contactDamping,
                                            accContact);
    CK(cudaGetLastError());
}

// 한 칸에 중력이 접촉을 이길 만큼 쌓이면 그 자리가 무너져 블랙홀이 된다.
void Sim::Impl::checkCollapse() {
    if (g_failed || !cfg.collapseEnabled || bh.active) return;
    const int G = allocG, S = stride();
    CK(cudaMemset(redU, 0, sizeof(unsigned long long)));
    kFindDensestCell<<<grd3(G), blk3()>>>(rho, G, S, redU);
    unsigned long long key = 0;
    CK(cudaMemcpy(&key, redU, sizeof(key), cudaMemcpyDeviceToHost));
    const float dens = (float)(unsigned)(key >> 32) / 256.0f;
    const float mean = (float)allocN / (float)((double)G * G * G);
    if (dens < cfg.collapseDensity * fmaxf(mean, 1e-9f)) return;

    const unsigned cell = (unsigned)(key & 0xFFFFFFFFull);
    const int cx = cell % G, cy = (cell / G) % G, cz = cell / (G * G);
    bh.active = true; bh.born = true;
    bh.x = (cx + 0.5f) / G; bh.y = (cy + 0.5f) / G;
    // 무너진 칸에 **쌓여 있던 질량**이 그대로 블랙홀이 된다.
    //
    // 전에는 질량을 0 으로 두고 지평선만 알갱이 하나분으로 냈다. 그러면 지평선이
    // 2·G·(1/N)/c² 라 사실상 0 이고, 화면에는 「블랙홀이 되었습니다 · 삼킨 알갱이 0 ·
    // 지평선 0.0000」이라는 앞뒤 안 맞는 말이 뜬다 — 실체 없는 블랙홀이었다.
    bh.mass = dens;
    bh.rs = horizonOf(bh.mass);
    (void)cz;
}

// ---------------------------------------------------------------------------
// 공개 인터페이스
// ---------------------------------------------------------------------------
Sim::Sim() : impl_(new Impl) {}
Sim::~Sim() { impl_->freeAll(); delete impl_; }

bool Sim::deviceAvailable() {
    int n = 0;
    return cudaGetDeviceCount(&n) == cudaSuccess && n > 0;
}
std::string Sim::deviceName() {
    cudaDeviceProp p{};
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return "unknown";
    return p.name;
}
std::string Sim::deviceDriver() {
    // NVIDIA 드라이버 번호(555.99 같은 것)는 여기서 알 수 없다 — 그건 NVML 이 준다.
    // 대신 그 드라이버가 지원하는 CUDA 판을 적는다.
    int v = 0;
    if (cudaDriverGetVersion(&v) != cudaSuccess || v <= 0) return "";
    char buf[32];
    snprintf(buf, sizeof(buf), "CUDA %d.%d", v / 1000, (v % 1000) / 10);
    return buf;
}
size_t Sim::deviceFreeBytes() {
    size_t f = 0, t = 0;
    if (cudaMemGetInfo(&f, &t) != cudaSuccess) return 0;
    return f;
}
int Sim::deviceMultiProcessors() {
    cudaDeviceProp p{};
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return 0;
    return p.multiProcessorCount;
}

// 이 설정으로 잡아야 할 VRAM.
//
// 3D 라 격자 쪽이 세제곱으로 자란다 — 고립 경계는 한 변을 두 배로 잡으므로 8배가 더 붙는다.
size_t Sim::estimateBytes(int particleCount, int gridSize, Boundary boundary) {
    const size_t N = (size_t)(particleCount > 0 ? particleCount : 1);
    const size_t G = (size_t)(gridSize > 0 ? gridSize : 1);
    const size_t S = (boundary == Boundary::Isolated) ? G * 2 : G;
    const size_t cells = S * S * S;
    const size_t spec = S * S * (S / 2 + 1);

    size_t b = 0;
    b += sizeof(float4) * N * 4;      // pos, vel, posTmp, velTmp
    b += sizeof(float)  * N * 3;      // temp, tempTmp, accMag
    b += sizeof(float4) * N;          // accContact
    b += sizeof(int)    * N * 4;      // keys, order, flag, scan
    b += sizeof(float4) * G * G * G;  // accG
    b += sizeof(float)  * cells * 2;  // rho, pot
    b += sizeof(cufftComplex) * spec * 2;
    b += sizeof(int) * G * G * G * 2; // cellStart, cellEnd
    b += cells * 2;                   // cuFFT 작업 공간 어림
    return b;
}

int Sim::maxParticlesFor(int gridSize, Boundary boundary, size_t freeBytes) {
    // 격자가 먼저 자리를 차지한다. 남는 것으로 알갱이를 잡는다.
    const size_t gridPart = estimateBytes(1, gridSize, boundary);
    if (freeBytes <= gridPart) return 0;
    const size_t perParticle = sizeof(float4) * 5 + sizeof(float) * 3 + sizeof(int) * 4;
    // 8할만 쓴다 — 드라이버와 화면 버퍼가 쓸 몫을 남긴다.
    const size_t usable = (size_t)((freeBytes - gridPart) * 0.8);
    const size_t n = usable / perParticle;
    return (n > 100000000ull) ? 100000000 : (int)n;
}

void Sim::init(const SimConfig& c) {
    impl_->cfg = c;
    reconfigure(c);
}

void Sim::reconfigure(const SimConfig& c) {
    Impl& d = *impl_;
    // 밖에서 무엇을 요청하든 여기서 자른다.
    //
    // 3D 는 격자가 세제곱으로 자란다. 2D 시절의 값이 그대로 들어오면 4096³ = 687억 칸을
    // 잡으려 들고, 고립 경계는 패딩까지 붙어 8192³ = 5500억 칸이 된다. 2026-08-14 에
    // 회귀 테스트가 G=4096 을 요청했다가 시스템 메모리가 통째로 치솟았다 —
    // **한계를 아는 쪽이 코어이므로 코어가 막아야 한다.**
    const int gCap = maxGridSize(c.boundary);
    int g = (c.gridSize > 0) ? c.gridSize : 64;
    if (g > gCap) g = gCap;
    if (g < 16) g = 16;
    // 2의 거듭제곱으로 내린다 — 주기 wrap 을 비트 마스크로 처리하므로 그래야 맞는다.
    { int p = 16; while (p * 2 <= g) p *= 2; g = p; }

    const bool structural = (c.particleCount != d.requestedN) ||
                            (g != d.requestedG) ||
                            (c.boundary != d.requestedBoundary);
    d.cfg = c;
    d.cfg.gridSize = g;
    if (!structural) return;

    d.requestedN = c.particleCount;
    d.requestedG = g;
    d.requestedBoundary = c.boundary;

    // 가용 VRAM 안에 들어가게 깎는다. 3D 는 격자가 크므로 이 판정이 2D 보다 자주 걸린다.
    int n = c.particleCount;
    const size_t freeB = deviceFreeBytes();
    if (freeB > 0) {
        const int cap = maxParticlesFor(g, c.boundary, freeB);
        // 격자만으로 이미 가용량을 넘으면 알갱이를 하나도 못 잡는다. 그때는 판을 열지 않는다 —
        // 그대로 할당을 시도하면 드라이버가 수십 GB 를 잡으려다 시스템을 끌어내린다.
        if (cap <= 0) {
            markFailure("이 격자는 이 카드에 들어가지 않습니다", __FILE__, __LINE__);
            return;
        }
        if (n > cap) n = cap;
    }
    d.allocN = (n > 0) ? n : 1;
    d.allocG = g;
    d.allocBoundary = c.boundary;
    d.allocate();
    d.buildGreen();
    reset();
}

// 이 경계에서 격자 한 변이 가질 수 있는 최대값.
//
// 고립 경계는 합성곱이 감기지 않게 한 변을 두 배로 잡으므로 실제로는 512³ 을 쓴다.
// 그 하나가 537 MB 이고 퍼텐셜·주파수 배열까지 하면 1.6 GB 다.
int Sim::maxGridSize(Boundary b) { return (b == Boundary::Isolated) ? 256 : 512; }

void Sim::reset() {
    Impl& d = *impl_;
    if (g_failed) return;
    d.simTime = 0.0;
    d.stepCount = 0;
    d.bh = BlackHoleState{};

    // 블랙홀 장면은 알갱이를 놓기 **전에** 세운다. 나중에 세우면 초기 궤도 속도가
    // 블랙홀 없는 중력만 보고 정해져, 원반이 통째로 빨려 든다.
    if (d.cfg.preset == Preset::BlackHole || d.cfg.blackHoleEnabled) {
        d.bh.active = true;
        d.bh.x = 0.5f; d.bh.y = 0.5f;
        d.bh.rs = d.cfg.blackHoleRs;
        // rs = 2GM/c² 의 역 — 지평선 크기 하나가 질량까지 정한다.
        d.bh.mass = d.bh.rs * d.cfg.lightSpeedSq / (2.0f * fmaxf(d.cfg.gravity, 1e-6f))
                  * (float)d.allocN;
    }
    CK(cudaMemset(d.eaten, 0, sizeof(int)));
    d.placeInitial();
    d.giveOrbits();
    d.computeAccel();
}

void Sim::step() {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return;

    CK(cudaEventRecord(d.evA));

    // 성능을 위해 가끔 알갱이를 칸 순서로 재배치한다. 정확성과는 무관하다.
    if (d.cfg.sortInterval > 0 && (d.stepCount % d.cfg.sortInterval) == 0 && !d.cfg.contactEnabled)
        d.sortParticles();

    d.computeAccel();
    d.doContact();

    // CFL — 한 스텝에 한 칸을 넘게 가면 격자가 그 움직임을 못 따라가 알갱이가 튄다.
    CK(cudaMemset(d.redF, 0, sizeof(float)));
    kMaxSpeed<<<(d.allocN + 255) / 256, 256>>>(d.vel, d.pos, d.allocN, d.redF);
    float vmax = 0.f;
    CK(cudaMemcpy(&vmax, d.redF, sizeof(float), cudaMemcpyDeviceToHost));
    const float cell = 1.0f / (float)d.allocG;
    float dt = 0.0016f * d.cfg.timeScale;
    const float dtMax = (vmax > 1e-6f) ? (0.8f * cell / vmax) : dt;
    if (dt > dtMax) dt = dtMax;
    d.tm.dtUsed = dt; d.tm.maxSpeed = vmax; d.tm.substeps = 1;

    const float haloV2 = d.cfg.haloEnabled ? (d.cfg.haloSpeed * d.cfg.haloSpeed) : 0.f;
    const float haloCore2 = d.cfg.haloCore * d.cfg.haloCore;
    const float bhGM = d.bh.active
                     ? d.cfg.gravity * d.bh.mass / (float)(d.allocN > 0 ? d.allocN : 1) : 0.f;

    kIntegrate<<<(d.allocN + 255) / 256, 256>>>(
        d.accG, d.pos, d.vel, d.allocN, d.allocG, dt, d.periodic() ? 1 : 0,
        d.bh.active ? 1 : 0, bhGM, d.bh.rs, d.bh.x, d.bh.y, 0.5f,
        d.cfg.lightSpeedSq, d.eaten, haloV2, haloCore2,
        d.cfg.contactEnabled ? d.accContact : nullptr);
    CK(cudaGetLastError());

    // 삼킨 만큼 지평선이 자란다.
    if (d.bh.active) {
        int e = 0;
        CK(cudaMemcpy(&e, d.eaten, sizeof(int), cudaMemcpyDeviceToHost));
        if (e > 0) {
            d.bh.mass += (float)e;
            d.bh.rs = d.horizonOf(d.bh.mass);
            CK(cudaMemset(d.eaten, 0, sizeof(int)));
        }
    }
    d.checkCollapse();

    d.simTime += dt;
    ++d.stepCount;

    CK(cudaEventRecord(d.evB));
    CK(cudaEventSynchronize(d.evB));
    float ms = 0.f;
    CK(cudaEventElapsedTime(&ms, d.evA, d.evB));
    d.tm.totalMs = ms;
}

const SimConfig& Sim::config() const { return impl_->cfg; }
SimTimings Sim::timings() const { return impl_->tm; }
double Sim::simTime() const { return impl_->simTime; }
bool Sim::failed() { return g_failed; }
std::string Sim::failMessage() { return g_failMsg; }
int Sim::gridSize() const { return impl_->allocG; }
int Sim::particleCount() const { return impl_->allocN; }
int Sim::activeCount() const { return impl_->active; }
int Sim::starCount() const { return 0; }
BlackHoleState Sim::blackHole() const { return impl_->bh; }

double Sim::measureTotalGridMass() {
    Impl& d = *impl_;
    if (g_failed) return 0.0;
    const size_t cells = d.padCells();
    size_t need = 0;
    cub::DeviceReduce::Sum(nullptr, need, d.rho, (float*)d.redD, (int)cells);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return 0.0;
    cub::DeviceReduce::Sum(d.redTmp, d.redTmpBytes, d.rho, (float*)d.redD, (int)cells);
    float s = 0.f;
    CK(cudaMemcpy(&s, d.redD, sizeof(float), cudaMemcpyDeviceToHost));
    return (double)s;
}

double Sim::measureMaxDensity() {
    Impl& d = *impl_;
    if (g_failed) return 0.0;
    const size_t cells = d.padCells();
    size_t need = 0;
    cub::DeviceReduce::Max(nullptr, need, d.rho, (float*)d.redD, (int)cells);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return 0.0;
    cub::DeviceReduce::Max(d.redTmp, d.redTmpBytes, d.rho, (float*)d.redD, (int)cells);
    float s = 0.f;
    CK(cudaMemcpy(&s, d.redD, sizeof(float), cudaMemcpyDeviceToHost));
    return (double)s;
}

int Sim::measureOccupiedCells() {
    Impl& d = *impl_;
    if (g_failed) return 0;
    const size_t cells = d.padCells();
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kCountOccupied<<<(int)((cells + 255) / 256), 256>>>(d.rho, (int)cells, d.redI, 1e-6f);
    int c = 0;
    CK(cudaMemcpy(&c, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    return c;
}

void Sim::measureCentroid(double& cx, double& cy) {
    Impl& d = *impl_;
    cx = cy = 0.5;
    if (g_failed || d.allocN <= 0) return;
    CK(cudaMemset(d.redD, 0, sizeof(double) * 2));
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kCentroidAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN,
                                                    d.redD, d.redD + 1, d.redI);
    double s[2] = { 0, 0 };
    int cnt = 0;
    CK(cudaMemcpy(s, d.redD, sizeof(double) * 2, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&cnt, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    if (cnt > 0) { cx = s[0] / cnt; cy = s[1] / cnt; }
}

double Sim::measureMeanTemperature() { return 0.0; }

// 격자 중력의 정확도를 O(N²) 직접 계산과 견준다.
// 3D 전환에서는 이 진단을 쓰지 않는다 — 필요해지면 그때 되살린다.
double Sim::measureForceErrorVsDirect(int, int, float) { return 0.0; }

const float* Sim::densityDevicePtr() const { return impl_->rho; }

// 화면은 위에서 내려다본다. 3D 밀도를 z 로 합쳐 2D 로 투영해 넘긴다.
const float* Sim::fieldDevicePtr(Field) {
    Impl& d = *impl_;
    if (g_failed) return d.proj;
    const int G = d.allocG;
    kClearF<<<(G * G + 255) / 256, 256>>>(d.proj, G * G);
    kProjectXY<<<grd3(G), blk3()>>>(d.rho, d.proj, G, d.stride());
    CK(cudaGetLastError());
    return d.proj;
}

const float* Sim::particlePosDevicePtr() const { return (const float*)impl_->pos; }
const float* Sim::particleVelDevicePtr() const { return (const float*)impl_->vel; }
const float* Sim::particleTempDevicePtr() const { return impl_->temp; }

// ---------------------------------------------------------------------------
// 마우스 도구
// ---------------------------------------------------------------------------
int Sim::addShape(float cx, float cy, ShapeKind kind, float radius, int count, bool autoOrbit) {
    Impl& d = *impl_;
    if (g_failed || count <= 0) return 0;
    const int room = d.allocN - d.active;
    if (room <= 0) return 0;
    const int n = (count < room) ? count : room;
    const int from = d.active;

    kFillShape<<<(n + 255) / 256, 256>>>(d.pos, d.vel, d.temp, from, n, cx, cy,
                                         (int)kind, radius, d.cfg.diskThickness,
                                         (unsigned)(d.stepCount * 7919 + 17));
    d.active += n;

    if (autoOrbit && kind != ShapeKind::Blob) {
        d.computeAccel();
        kAccelMag<<<(d.allocN + 255) / 256, 256>>>(d.accG, d.pos, d.accMag, d.allocN,
                                                   d.allocG, d.periodic() ? 1 : 0);
        kSetOrbitAt<<<(n + 255) / 256, 256>>>(d.vel, d.pos, d.accMag, from, n, cx, cy);
    }
    CK(cudaGetLastError());
    return n;
}

void Sim::sprayAt(float cx, float cy, float radius, float strength) {
    Impl& d = *impl_;
    if (g_failed) return;
    kBrushPush<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, strength);
    CK(cudaGetLastError());
}

void Sim::wellAt(float cx, float cy, float radius, float strength) {
    Impl& d = *impl_;
    if (g_failed) return;
    kBrushPush<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, -strength);
    CK(cudaGetLastError());
}

int Sim::eraseAt(float cx, float cy, float radius) {
    Impl& d = *impl_;
    if (g_failed) return 0;
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kEraseIn<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, d.redI);
    int erased = 0;
    CK(cudaMemcpy(&erased, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    if (erased <= 0) return 0;

    // 지운 자리를 메워 살아 있는 것을 앞으로 모은다. 이 불변식이 깨지면 형태를 다시 넣을 때
    // 요청한 개수가 안 들어간다.
    kMarkAlive<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.flag);
    size_t need = 0;
    cub::DeviceScan::ExclusiveSum(nullptr, need, d.flag, d.scan, d.allocN);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return erased;
    cub::DeviceScan::ExclusiveSum(d.redTmp, d.redTmpBytes, d.flag, d.scan, d.allocN);
    kCompact<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.temp, d.flag, d.scan,
                                              d.allocN, d.posTmp, d.velTmp, d.tempTmp);
    std::swap(d.pos, d.posTmp); std::swap(d.vel, d.velTmp); std::swap(d.temp, d.tempTmp);
    d.active -= erased;
    if (d.active < 0) d.active = 0;
    if (d.active < d.allocN)
        kHideRange<<<((d.allocN - d.active) + 255) / 256, 256>>>(d.pos, d.vel, d.active, d.allocN);
    CK(cudaGetLastError());
    return erased;
}
