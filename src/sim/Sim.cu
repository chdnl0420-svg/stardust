// 시뮬레이션 코어 구현 — Core 층.
//
// 한 스텝의 흐름 (design.md §4):
//   (K스텝마다) 셀키 -> radix sort -> 재배치      : 캐시 지역성 회복. 정확성이 아니라 성능 목적
//   격자 비우기 -> CIC 산란                        : 파티클 질량을 격자 4칸에 가중치로 나눠 담는다
//   포아송 풀기                                    : 주기면 주파수공간 커널, 고립이면 패딩+그린함수
//   (압력 켜짐) 밀도 -> 압력 -> 압력 기울기
//   격자 가속도 -> CIC 보간 -> 속도·위치 적분
//
// 용어:
//   CIC(Cloud-In-Cell) : 파티클 하나를 가장 가까운 격자 4칸에 거리 가중치로 나눠 담는 방식.
//                        한 칸에 통째로 넣는 것보다 부드럽고 격자 무늬가 덜 생긴다.
//   포아송 방정식       : "질량이 이렇게 분포하면 중력장이 어떻게 생기나"를 주는 식.
//   FFT                : 신호를 파동의 겹침으로 바꾸는 변환. 이걸 쓰면 모든 칸이 모든 칸에 미치는
//                        영향을 한 번에 처리할 수 있다.
//   그린함수            : 점 하나가 주변에 만드는 장(場)의 모양. 이것과 밀도를 합성곱하면 전체 장이 나온다.
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
// 전에는 오류를 찍기만 하고 그대로 진행했는데, 할당이 실패하면 그 포인터는 null 이라
// 다음 커널이 null 을 건드려 드라이버가 컨텍스트를 통째로 버린다. 그러면 이후 모든 호출이
// 연쇄로 실패하고, 화면에는 "아무 일도 안 일어나는 앱"만 남아 원인을 못 찾는다
// (round-06 리뷰 P1 #7).
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

// cuFFT 호출용. 반환형이 cudaError_t 가 아니라 cufftResult 라 CK 로 못 감싼다.
// 계획 생성뿐 아니라 **실행**도 실패할 수 있고, 실패한 변환의 출력은 미초기화라
// 그대로 퍼텐셜로 쓰면 파티클이 통째로 망가진다(round-08 리뷰 R2).
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

// 격자 인덱스. 주기 경계면 반대편으로 감고, 고립 경계면 가장자리에 붙인다.
// gridSize 가 2의 거듭제곱이라 wrap 을 나눗셈 없이 비트 마스크로 처리한다.
__device__ __forceinline__ int gidx(int x, int y, int G, int periodic) {
    if (periodic) { x &= (G - 1); y &= (G - 1); }
    else          { x = min(max(x, 0), G - 1); y = min(max(y, 0), G - 1); }
    return y * G + x;
}

// ---------------------------------------------------------------------------
// 초기 배치 — 속도는 여기서 정하지 않는다. 중력을 한 번 푼 뒤 kSetOrbit 이 채운다.
// (프로토타입에서 속도를 임의로 정했다가 원반이 흩어진 적이 있다 — design.md §9-2)
// ---------------------------------------------------------------------------
__global__ void kPlace(float2* pos, float2* vel, float* temp, int n, int preset) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float u1 = rnd01(i * 4u + 1u), u2 = rnd01(i * 4u + 2u);
    float u3 = rnd01(i * 4u + 3u), u4 = rnd01(i * 4u + 4u);
    float2 p, v = make_float2(0.f, 0.f);
    switch (preset) {
        case 0: {                                   // SpiralDisk
            float r = sqrtf(u1) * 0.20f, th = u2 * 6.2831853f;
            p = make_float2(0.5f + r * cosf(th), 0.5f + r * sinf(th));
        } break;
        case 1: {                                   // TidalPair
            float side = (u3 > 0.5f) ? 1.f : -1.f;
            float r = sqrtf(u1) * 0.085f, th = u2 * 6.2831853f;
            p = make_float2(0.5f + side * 0.16f + r * cosf(th),
                            0.5f - side * 0.06f + r * sinf(th));
        } break;
        case 2: {                                   // HeadOnShock
            float side = (u3 > 0.5f) ? 1.f : -1.f;
            float r = sqrtf(u1) * 0.080f, th = u2 * 6.2831853f;
            p = make_float2(0.5f + side * 0.17f + r * cosf(th), 0.5f + r * sinf(th));
            v = make_float2(-side * 0.055f, (u4 - 0.5f) * 0.004f);
        } break;
        case 3: {                                   // CosmicWeb
            p = make_float2(u1, u2);
            v = make_float2((u3 - 0.5f) * 0.02f, (u4 - 0.5f) * 0.02f);
        } break;
        default:                                    // Empty — 화면 밖에 숨겨 둔다
            p = make_float2(-1.f, -1.f);
            break;
    }
    pos[i] = p; vel[i] = v; temp[i] = 0.02f;
}

// 측정한 중력으로 원 궤도 속도를 채운다. v = sqrt(|구심가속도| * r).
// 중력 세기를 모른 채 속도를 넣으면 원반이 부풀거나 붕괴한다.
__global__ void kSetOrbit(const float2* accG, const float2* pos, float2* vel,
                          int n, int G, int periodic, int preset, float fudge) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;

    // 두 덩어리 프리셋은 가까운 중심을 각자 고른다. 전체 중심으로 돌리면 회전이 어긋난다.
    float cx = 0.5f, cy = 0.5f;
    if (preset == 1) {
        float2 c0 = make_float2(0.34f, 0.56f), c1 = make_float2(0.66f, 0.44f);
        float d0 = hypotf(p.x - c0.x, p.y - c0.y), d1 = hypotf(p.x - c1.x, p.y - c1.y);
        if (d1 < d0) { cx = c1.x; cy = c1.y; } else { cx = c0.x; cy = c0.y; }
    }
    float dx = p.x - cx, dy = p.y - cy;
    float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) { vel[i] = make_float2(0.f, 0.f); return; }

    float g = p.x * G;  (void)g;
    int ix = (int)floorf(p.x * G), iy = (int)floorf(p.y * G);
    float2 a = accG[gidx(ix, iy, G, periodic)];
    float ar = -(a.x * dx + a.y * dy) / r;          // 중심을 향하는 성분(양수면 인력)
    float v = (ar > 0.f) ? sqrtf(ar * r) * fudge : 0.f;
    float2 base = vel[i];
    vel[i] = make_float2(-dy / r * v + base.x, dx / r * v + base.y);
}

__global__ void kClearF(float* g, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) g[i] = 0.f;
}

// CIC 산란. CUDA 는 float atomicAdd 를 하드웨어로 지원해 고정소수점 변환이 필요 없다.
__global__ void kScatter(const float2* pos, float* grid, int n, int G, int stride, int periodic) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;                          // 숨겨 둔 파티클(빈 판)
    float gx = p.x * G, gy = p.y * G;
    int ix = (int)floorf(gx), iy = (int)floorf(gy);
    float fx = gx - ix, fy = gy - iy;
#pragma unroll
    for (int k = 0; k < 4; ++k) {
        int ox = k & 1, oy = (k >> 1) & 1;
        int cx = ix + ox, cy = iy + oy;
        float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy);
        if (periodic) { cx &= (G - 1); cy &= (G - 1); }
        else {
            // 고립 경계에서는 범위 밖 가중치를 버리지 않고 가장자리 칸에 얹는다.
            // 버리면 판 끝에 붙은 파티클의 질량 일부가 사라진다 — 격자가 성길수록 심하다
            // (실측: G=128 에서 50스텝에 23% 손실). 적분기가 파티클을 판 안에 붙잡아 두므로
            // 질량도 판 안에 남아 있어야 앞뒤가 맞는다.
            cx = min(max(cx, 0), G - 1);
            cy = min(max(cy, 0), G - 1);
        }
        atomicAdd(&grid[cy * stride + cx], w);
    }
}

// 주기 경계용 주파수공간 커널.
//   law=0 : 1/k  -> 3D 형 1/r^2 힘 (기본)
//   law=1 : 1/k^2-> 수학적으로 올바른 2D 중력, 힘 1/r
__global__ void kPoissonPeriodic(cufftComplex* F, int G, float scale, int law,
                                 float softCells) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int W = G / 2 + 1;
    if (x >= W || y >= G) return;
    int i = y * W + x;
    if (x == 0 && y == 0) { F[i].x = 0.f; F[i].y = 0.f; return; }
    float kx = (float)x;
    float ky = (float)(y <= G / 2 ? y : y - G);
    float k2 = kx * kx + ky * ky;
    float denom = (law == 0) ? sqrtf(k2) : k2;
    float f = -scale / denom;

    // 소프트닝 — 가까운 거리에서 힘이 발산하지 않게 뭉툭하게 만드는 것.
    // 고립 경계는 실공간 그린함수에 직접 넣지만(kGreen 의 eps), 주기 경계는 주파수공간에서
    // 처리해야 한다. 잔물결(고주파)을 가우시안으로 눌러 같은 효과를 낸다 —
    // 소프트닝 길이보다 작은 구조가 힘에 기여하지 못하게 하는 것이 소프트닝의 뜻이다.
    // 전에는 이 인자가 없어 주기 경계에서 소프트닝 슬라이더가 아무 일도 하지 않았다
    // (round-06 리뷰 P2 #19).
    if (softCells > 0.f) {
        const float s = 6.2831853f * softCells / (float)G;   // 2π·(소프트닝 길이 / 판 크기)
        f *= __expf(-0.5f * k2 * s * s);
    }
    F[i].x *= f; F[i].y *= f;
}

// 고립 경계용 실공간 그린함수. 패딩 격자에 -1/max(r,eps) 를 깔고 한 번만 FFT 해 둔다.
__global__ void kGreen(float* g, int GP, float cell, float eps, int law) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= GP || y >= GP) return;
    int dx = (x < GP / 2) ? x : x - GP;
    int dy = (y < GP / 2) ? y : y - GP;
    float r = sqrtf((float)dx * dx + (float)dy * dy) * cell;
    float rr = fmaxf(r, eps);
    // law=0 : 퍼텐셜 -1/r  (힘 1/r^2)     law=1 : 퍼텐셜 ln(r) (힘 1/r)
    g[y * GP + x] = (law == 0) ? (-1.0f / rr) : logf(rr);
}

__global__ void kMulSpec(cufftComplex* a, const cufftComplex* b, int n, float s) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    cufftComplex A = a[i], B = b[i];
    a[i] = make_cuFloatComplex((A.x * B.x - A.y * B.y) * s, (A.x * B.y + A.y * B.x) * s);
}

// 압력. 밀도를 평균으로 나눠 정규화하므로 파티클 수를 바꿔도 압력의 세기가 그대로다.
// (질량 정규화와 같은 이유 — 정규화 전에는 N 을 늘리면 압력만 커져 가스가 폭발했다.)
//
// 온도 격자(tempGrid)가 주어지면 P = K ρ^γ (1 + T) 로 온도를 반영한다.
// 이 연결이 없으면 냉각을 켜도 압력이 그대로라 뭉치는 정도가 바뀌지 않는다(실측: 84.22 vs 84.2).
__global__ void kPressure(const float* rho, const float* tempGrid, float* prs, int n,
                          float K, float gamma, float invMeanRho) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float p = K * powf(fmaxf(rho[i], 0.f) * invMeanRho, gamma);
    if (tempGrid) p *= (1.f + tempGrid[i]);
    prs[i] = p;
}

// 별 형성 — 밀도와 온도가 둘 다 임계를 넘은 칸의 파티클을 별로 바꾼다.
// 조건 하나만 쓰면 뜨겁고 조밀한 충격파면에서 잘못 생긴다(design.md O2).
// 별이 된 파티클은 온도를 0 으로 고정해 더는 가열되지 않는다.
__global__ void kStarFormation(const float2* pos, float* temp, unsigned char* isStar,
                               const float* rho, int n, int G, int stride, int periodic,
                               float rhoThreshold, float tempThreshold, int* starCount) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (isStar[i]) { temp[i] = 0.f; atomicAdd(starCount, 1); return; }
    float2 p = pos[i];
    if (p.x < 0.f) return;
    int ix = (int)floorf(p.x * G), iy = (int)floorf(p.y * G);
    if (periodic) { ix &= (G - 1); iy &= (G - 1); }
    else { ix = min(max(ix, 0), G - 1); iy = min(max(iy, 0), G - 1); }
    const float d = rho[iy * stride + ix];
    if (d >= rhoThreshold && temp[i] <= tempThreshold) {
        isStar[i] = 1;
        temp[i] = 0.f;
        atomicAdd(starCount, 1);
    }
}

// 퍼텐셜과 압력의 기울기를 합쳐 격자 가속도장을 만든다.
// potStride 는 고립 경계에서 패딩 격자 폭(2G), 주기 경계에서 G 다.
__global__ void kGridAccel(const float* pot, const float* prs, const float* rho,
                           float2* accG, int G, int potStride, float potScale,
                           int usePressure, int periodic) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= G || y >= G) return;
    int xm, xp, ym, yp;
    if (periodic) { xm = (x - 1) & (G - 1); xp = (x + 1) & (G - 1);
                    ym = (y - 1) & (G - 1); yp = (y + 1) & (G - 1); }
    else          { xm = max(x - 1, 0); xp = min(x + 1, G - 1);
                    ym = max(y - 1, 0); yp = min(y + 1, G - 1); }
    float ax = -(pot[y * potStride + xp] - pot[y * potStride + xm]) * 0.5f * G * potScale;
    float ay = -(pot[yp * potStride + x] - pot[ym * potStride + x]) * 0.5f * G * potScale;
    if (usePressure) {
        float r = fmaxf(rho[y * potStride + x], 1e-4f);   // 0 나눗셈 차단 (design.md §7)
        ax += -(prs[y * potStride + xp] - prs[y * potStride + xm]) * 0.5f * G / r;
        ay += -(prs[yp * potStride + x] - prs[ym * potStride + x]) * 0.5f * G / r;
    }
    accG[y * G + x] = make_float2(ax, ay);
}

__device__ __forceinline__ float2 sampleAcc(const float2* accG, float2 p, int G, int periodic) {
    float gx = p.x * G, gy = p.y * G;
    int ix = (int)floorf(gx), iy = (int)floorf(gy);
    float fx = gx - ix, fy = gy - iy;
    float2 a0 = accG[gidx(ix,     iy,     G, periodic)];
    float2 a1 = accG[gidx(ix + 1, iy,     G, periodic)];
    float2 a2 = accG[gidx(ix,     iy + 1, G, periodic)];
    float2 a3 = accG[gidx(ix + 1, iy + 1, G, periodic)];
    float w0 = (1.f - fx) * (1.f - fy), w1 = fx * (1.f - fy);
    float w2 = (1.f - fx) * fy,          w3 = fx * fy;
    return make_float2(a0.x * w0 + a1.x * w1 + a2.x * w2 + a3.x * w3,
                       a0.y * w0 + a1.y * w1 + a2.y * w2 + a3.y * w3);
}

// 속도·위치 갱신. dt 는 호출 전에 CFL 조건으로 잘라 둔다(design.md §7).
__global__ void kIntegrate(const float2* accG, float2* pos, float2* vel, float* temp,
                           int n, int G, float dt, int periodic, int trackTemp,
                           int cooling, float coolRate, float hubble) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;
    float2 v = vel[i];
    float2 a = sampleAcc(accG, p, G, periodic);
    v.x += a.x * dt; v.y += a.y * dt;

    // 우주 팽창 — 공간이 늘어나면 물질은 그 흐름에 끌려 속도를 잃는다(허블 감쇠).
    // 이것이 중력 붕괴와 경쟁해 구조가 자라는 속도를 늦춘다. 주기 경계에서만 의미가 있다.
    if (hubble > 0.f) {
        // 냉각과 같은 이유로 계수가 크다 — dt 가 CFL 로 잘려 매우 작기 때문이다.
        const float damp = fmaxf(1.f - hubble * dt * 6000.f, 0.f);
        v.x *= damp; v.y *= damp;
    }

    if (trackTemp) {
        // 가속도와 속도가 반대 방향이면(=압축) 온도가 오른다. 충돌면이 달아오르는 것이 이 항이다.
        float t = temp[i] - (a.x * v.x + a.y * v.y) * dt * 0.6f;
        // 냉각률 계수가 큰 이유: CFL 클램프 때문에 dt 가 1e-5 수준으로 작다.
        // 물리적 비례(dt 에 비례)는 유지하되, 슬라이더를 올렸을 때 사람이 체감할 크기로 맞췄다.
        if (cooling) t -= t * coolRate * dt * 3000.0f;
        temp[i] = fminf(fmaxf(t, 0.f), 20.f);
    }

    p.x += v.x * dt; p.y += v.y * dt;
    if (periodic) {
        p.x -= floorf(p.x); p.y -= floorf(p.y);
    } else {
        // 고립 경계에서는 판 밖으로 못 나가게 붙잡고 속도를 죽인다.
        if (p.x < 0.002f) { p.x = 0.002f; v.x = fabsf(v.x) * 0.25f; }
        if (p.x > 0.998f) { p.x = 0.998f; v.x = -fabsf(v.x) * 0.25f; }
        if (p.y < 0.002f) { p.y = 0.002f; v.y = fabsf(v.y) * 0.25f; }
        if (p.y > 0.998f) { p.y = 0.998f; v.y = -fabsf(v.y) * 0.25f; }
    }
    pos[i] = p; vel[i] = v;
}

__global__ void kCellKey(const float2* pos, unsigned* key, unsigned* val, int n, int G) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    int cx = min(max((int)(p.x * G), 0), G - 1);
    int cy = min(max((int)(p.y * G), 0), G - 1);
    key[i] = (unsigned)(cy * G + cx);
    val[i] = (unsigned)i;
}
// 파티클을 새 순서로 옮긴다.
// 한 파티클이 가진 값은 전부 함께 옮겨야 한다 — 하나라도 빠지면 그 값만 다른 파티클에 붙는다.
// 별 표식(isStar)이 빠져 있어서, 정렬할 때마다 별이 엉뚱한 파티클로 옮겨 다녔다
// (round-06 리뷰 P1 #5).
__global__ void kReorder(const float2* sp, const float2* sv, const float* st,
                         const unsigned char* ss,
                         float2* dp, float2* dv, float* dt_, unsigned char* ds,
                         const unsigned* val, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned s = val[i];
    dp[i] = sp[s]; dv[i] = sv[s]; dt_[i] = st[s]; ds[i] = ss[s];
}

// 파티클이 가진 값(온도·속력)을 격자에 밀도 가중으로 뿌린다.
// 나중에 밀도로 나누면 그 칸의 평균값이 된다.
__global__ void kScatterValue(const float2* pos, const float2* vel, const float* temp,
                              float* num, int n, int G, int stride, int periodic, int which) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;
    float value = (which == 1) ? temp[i]
                              : sqrtf(vel[i].x * vel[i].x + vel[i].y * vel[i].y);
    float gx = p.x * G, gy = p.y * G;
    int ix = (int)floorf(gx), iy = (int)floorf(gy);
    float fx = gx - ix, fy = gy - iy;
#pragma unroll
    for (int k = 0; k < 4; ++k) {
        int ox = k & 1, oy = (k >> 1) & 1;
        int cx = ix + ox, cy = iy + oy;
        float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy);
        if (periodic) { cx &= (G - 1); cy &= (G - 1); }
        else { cx = min(max(cx, 0), G - 1); cy = min(max(cy, 0), G - 1); }
        atomicAdd(&num[cy * stride + cx], w * value);
    }
}

// 가중합을 밀도로 나눠 제자리에서 평균으로 만든다(패딩 격자 전체를 훑는다).
__global__ void kNormalizeInPlace(float* num, const float* den, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float d = den[i];
    num[i] = (d > 1e-4f) ? (num[i] / d) : 0.f;
}

// 가중합을 밀도로 나눠 평균으로 만든다. 빈 칸은 0 으로 둔다.
__global__ void kDivideByDensity(const float* num, const float* den, float* out,
                                 int G, int stride) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= G || y >= G) return;
    float d = den[y * stride + x];
    out[y * G + x] = (d > 1e-4f) ? (num[y * stride + x] / d) : 0.f;
}

__global__ void kCrop(const float* src, float* dst, int G, int stride) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= G || y >= G) return;
    dst[y * G + x] = src[y * stride + x];
}

__global__ void kCountOccupied(const float* rho, int n, float thr, int* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && rho[i] > thr) atomicAdd(out, 1);
}

// 질량중심을 격자에서 누적한다. out[0]=Σx·ρ, out[1]=Σy·ρ, out[2]=Σρ.
// double atomicAdd 는 compute capability 6.0 이상에서 지원되고 이 프로젝트는 8.6 이다.
__global__ void kCentroidAccum(const float* rho, int G, int stride, double* out) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= G || y >= G) return;
    double m = (double)rho[y * stride + x];
    if (m <= 0.0) return;
    atomicAdd(&out[0], m * ((double)x + 0.5) / (double)G);
    atomicAdd(&out[1], m * ((double)y + 0.5) / (double)G);
    atomicAdd(&out[2], m);
}

// 정답지: 모든 쌍을 하나하나 더하는 직접 계산. 느리지만 정확하다.
__global__ void kDirectForce(const float2* pos, float2* f, int n, float eps2) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    __shared__ float2 sh[256];
    float2 p = (i < n) ? pos[i] : make_float2(0.f, 0.f);
    float ax = 0.f, ay = 0.f;
    for (int base = 0; base < n; base += 256) {
        int t = base + threadIdx.x;
        sh[threadIdx.x] = (t < n) ? pos[t] : make_float2(1e30f, 1e30f);
        __syncthreads();
        int lim = min(256, n - base);
        for (int j = 0; j < lim; ++j) {
            float dx = sh[j].x - p.x, dy = sh[j].y - p.y;
            float r2 = dx * dx + dy * dy + eps2;
            float inv = rsqrtf(r2), inv3 = inv * inv * inv;
            ax += dx * inv3; ay += dy * inv3;
        }
        __syncthreads();
    }
    if (i < n) f[i] = make_float2(ax, ay);
}

// ---------------------------------------------------------------------------
// 마우스 도구
// ---------------------------------------------------------------------------

// 빈 슬롯 [base, base+count) 에 형태를 채운다. 속도는 뒤에서 kSetOrbitAt 이 채운다.
__global__ void kFillShape(float2* pos, float2* vel, float* temp, int base, int count,
                           float cx, float cy, float radius, int kind, unsigned seed) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= count) return;
    int i = base + k;
    float u1 = rnd01((unsigned)i * 3u + seed);
    float u2 = rnd01((unsigned)i * 3u + 1u + seed);
    float th = u2 * 6.2831853f;
    // 원반·덩어리는 sqrt 분포라야 면밀도가 고르다. 고리는 바깥 테두리에만 둔다.
    float r = (kind == 2) ? radius * (0.78f + 0.22f * u1) : radius * sqrtf(u1);
    pos[i] = make_float2(cx + r * cosf(th), cy + r * sinf(th));
    vel[i] = make_float2(0.f, 0.f);
    temp[i] = 0.02f;
}

// 방금 넣은 형태에 그 자리 중력에 맞는 원 궤도 속도를 준다.
__global__ void kSetOrbitAt(const float2* accG, const float2* pos, float2* vel,
                            int base, int count, int G, int periodic,
                            float cx, float cy, float spin) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= count) return;
    int i = base + k;
    float2 p = pos[i];
    float dx = p.x - cx, dy = p.y - cy;
    float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) { vel[i] = make_float2(0.f, 0.f); return; }
    int ix = (int)floorf(p.x * G), iy = (int)floorf(p.y * G);
    float2 a = accG[gidx(ix, iy, G, periodic)];
    float ar = -(a.x * dx + a.y * dy) / r;
    float v = (ar > 0.f) ? sqrtf(ar * r) * spin : 0.f;
    vel[i] = make_float2(-dy / r * v, dx / r * v);
}

// 브러시 안의 파티클 속도를 바깥(sign=+1) 또는 안쪽(sign=-1)으로 민다.
__global__ void kBrushPush(const float2* pos, float2* vel, int n,
                           float cx, float cy, float radius, float strength, float sign) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;
    float dx = p.x - cx, dy = p.y - cy;
    float r2 = dx * dx + dy * dy;
    if (r2 > radius * radius) return;
    float r = sqrtf(fmaxf(r2, 1e-12f));
    // 가운데가 가장 세고 가장자리로 갈수록 약해진다 — 경계에서 속도가 튀지 않게.
    float falloff = 1.f - r / radius;
    float2 v = vel[i];
    v.x += sign * (dx / r) * strength * falloff;
    v.y += sign * (dy / r) * strength * falloff;
    vel[i] = v;
}

// 브러시 안이면 살아있음 표시를 끈다(0). 지운 개수는 뒤에서 센다.
__global__ void kMarkAlive(const float2* pos, unsigned char* alive, int n,
                           float cx, float cy, float radius) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    float dx = p.x - cx, dy = p.y - cy;
    bool inside = (dx * dx + dy * dy) <= radius * radius;
    alive[i] = (p.x >= 0.f && !inside) ? 1 : 0;
}

// 남은 파티클을 배열 앞쪽으로 모은다(선택된 인덱스 순서대로 gather).
// 살아남은 파티클을 배열 앞쪽으로 모은다.
// kReorder 와 같은 규칙 — 파티클이 가진 값은 전부 함께 옮긴다. 별 표식이 빠져 있어서
// 지운 별이 계속 집계되고, 그 자리에 새로 넣은 형태가 남의 별 표식을 물려받았다
// (round-06 리뷰 P1 #6).
__global__ void kCompact(const float2* sp, const float2* sv, const float* st,
                         const unsigned char* ss,
                         float2* dp, float2* dv, float* dt_, unsigned char* ds,
                         const int* idx, int count) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;
    int s = idx[i];
    dp[i] = sp[s]; dv[i] = sv[s]; dt_[i] = st[s]; ds[i] = ss[s];
}

// 빈 슬롯을 화면 밖으로 확실히 밀어 둔다(산란·렌더가 건너뛰도록).
__global__ void kHideRange(float2* pos, int base, int count) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= count) return;
    pos[base + k] = make_float2(-1.f, -1.f);
}

__global__ void kInitBlob(float2* pos, int n, float lo, float hi) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    pos[i] = make_float2(lo + (hi - lo) * rnd01(i * 2u + 1u),
                         lo + (hi - lo) * rnd01(i * 2u + 2u));
}

__global__ void kAccelAt(const float2* accG, const float2* pos, float2* out,
                         int n, int G, int periodic) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    out[i] = sampleAcc(accG, pos[i], G, periodic);
}

// 합계를 double 로 누적하기 위한 변환 어댑터.
// 4096² 고립이면 패딩 격자가 6,700만 칸이라 float 누적으로는 상대오차가 0.3% 대까지
// 벌어져 "질량 보존" 판정이 못 미더워진다(실측).
struct ToDouble { __host__ __device__ double operator()(float x) const { return (double)x; } };

// 속도 벡터를 길이로 바꾼다. CFL 클램프가 "가장 빠른 파티클"을 찾는 데 쓴다.
struct SpeedOf {
    __host__ __device__ float operator()(float2 v) const { return sqrtf(v.x * v.x + v.y * v.y); }
};

constexpr int BS = 256;
inline int grid1(int n) { return (n + BS - 1) / BS; }

} // namespace

// ---------------------------------------------------------------------------
struct Sim::Impl {
    SimConfig  cfg;
    SimTimings tim;
    double     time = 0.0;
    long long  steps = 0;

    // 파티클
    float2 *pos = nullptr, *vel = nullptr, *pos2 = nullptr, *vel2 = nullptr;
    float  *temp = nullptr, *temp2 = nullptr;
    unsigned *key = nullptr, *keyOut = nullptr, *val = nullptr, *valOut = nullptr;
    void   *sortTmp = nullptr; size_t sortTmpBytes = 0;

    // 격자 (고립이면 패딩 폭 2G, 주기면 G)
    float  *rho = nullptr, *pot = nullptr, *prs = nullptr, *rhoCrop = nullptr;
    float  *fieldNum = nullptr;   // 온도·속도 가중합 (패딩 격자)
    float  *fieldOut = nullptr;   // 평균값 (G x G)
    float2 *accG = nullptr;
    float  *green = nullptr;
    cufftComplex *rhoSpec = nullptr, *greenSpec = nullptr;
    cufftHandle planF = 0, planB = 0;
    bool planReady = false;

    // 리덕션 임시
    void  *redTmp = nullptr; size_t redTmpBytes = 0;
    void  *redOut = nullptr;   // 합이면 double, 최댓값이면 float 로 읽는다
    int   *cntOut = nullptr;

    int allocN = 0, allocG = 0;
    Boundary allocBoundary = Boundary::Isolated;
    GravityLaw allocLaw = GravityLaw::InverseSquare;
    float allocSoft = -1.f;

    // 마지막으로 **요청받은** 값. 실제로 잡은 것(allocN 등)과 다를 수 있다 — VRAM 이 모자라
    // 깎였을 때가 그렇다. 재할당 여부는 이 요청이 바뀌었는지로만 판정한다.
    //
    // 왜 요청 기준인가: 남은 VRAM 은 다른 프로그램 때문에 매 순간 오르내린다. 그 값을 재할당
    // 조건에 넣으면 요청이 그대로인데도 깎인 결과가 프레임마다 흔들려, 수 GB 짜리 버퍼를
    // 초당 수십 번 해제하고 다시 잡는다. 그래픽 드라이버가 그것을 버티지 못하고 죽는다
    // (2026-08-13 실측: 파티클 3000만으로 올린 뒤 시스템이 재부팅됨 — BugCheck 0xD1 / nvlddmkm.sys).
    int requestedN = -1, requestedG = -1;
    Boundary requestedBoundary = Boundary::Isolated;

    cudaEvent_t evA = nullptr, evB = nullptr;

    // 속도 리덕션용 (CFL)
    void  *spdTmp = nullptr; size_t spdTmpBytes = 0;
    float *spdOut = nullptr;

    // 마우스 도구용 — 살아 있는 파티클은 항상 [0, activeN) 에 모여 있다.
    int   activeN = 0;
    int   starN = 0;                  // 별이 된 파티클 수
    // 별 표식과 그 재배치용 두 번째 버퍼. 정렬·압축이 파티클을 옮길 때 이 값도 함께 옮긴다.
    unsigned char *isStar = nullptr, *isStar2 = nullptr;
    int   *starCnt = nullptr;
    unsigned char *alive = nullptr;
    int   *selIdx = nullptr;   // 살아남은 인덱스 목록
    int   *selNum = nullptr;   // 선택된 개수
    void  *selTmp = nullptr; size_t selTmpBytes = 0;

    int  stride() const { return (cfg.boundary == Boundary::Isolated) ? allocG * 2 : allocG; }
    int  padCells() const { int s = stride(); return s * s; }
    bool periodic() const { return cfg.boundary == Boundary::Periodic; }

    // 격자 퍼텐셜을 가속도로 바꿀 때 곱하는 배율.
    //
    // 파티클 하나의 질량을 1/N 로 둔다 — 그래야 은하의 총질량이 1 로 고정되어
    // 파티클 수를 바꿔도 중력의 세기가 그대로다. 이 나눗셈이 없으면 파티클을 열 배로 늘렸을 때
    // 중력도 열 배가 되어 속도가 폭주하고, CFL 클램프가 매 프레임 최대 분할로 돌아
    // 계산량만 몇 배가 된다(실측: 1000만에서 서브스텝 4 고정, 26.7 ms).
    //
    // 주기 경계는 FFT 왕복 정규화(1/S²)가 여기 붙고, 고립 경계는 이미 kMulSpec 에서 나눴다.
    float potentialScale() const {
        const float s = periodic() ? cfg.gravity / (float)(stride() * stride()) : cfg.gravity;
        return s / (float)(allocN > 0 ? allocN : 1);
    }

    // 평균 밀도의 역수. 압력을 이 값으로 정규화해 파티클 수와 무관하게 만든다.
    float invMeanRho() const {
        const float mean = (float)allocN / (float)(allocG * allocG);
        return (mean > 1e-6f) ? (1.0f / mean) : 1.0f;
    }

    void releaseGrid();
    void releaseParticles();
    void allocate();
    void buildGreen();
    void solveGravity();
    // 격자 가속도장을 지금 파티클 배치로 다시 만든다. 형태를 넣은 직후 궤도 속도를 재는 데 쓴다.
    void refreshAccel();
    float measureReduce(bool wantMax);
    // 가장 빠른 파티클의 속력. CFL 조건으로 dt 를 자르는 데 쓴다.
    float measureMaxSpeed();
    // 한 번의 적분(격자 가속도는 이미 만들어져 있다고 본다)
    void  integrateOnce(float dt);
};

void Sim::Impl::releaseParticles() {
    cudaFree(pos); cudaFree(vel); cudaFree(pos2); cudaFree(vel2);
    cudaFree(temp); cudaFree(temp2);
    cudaFree(key); cudaFree(keyOut); cudaFree(val); cudaFree(valOut);
    cudaFree(sortTmp); cudaFree(spdTmp); cudaFree(spdOut);
    cudaFree(alive); cudaFree(selIdx); cudaFree(selNum); cudaFree(selTmp);
    cudaFree(isStar); cudaFree(isStar2); cudaFree(starCnt);
    isStar = nullptr; isStar2 = nullptr; starCnt = nullptr; starN = 0;
    pos = vel = pos2 = vel2 = nullptr; temp = temp2 = nullptr;
    key = keyOut = val = valOut = nullptr; sortTmp = nullptr; sortTmpBytes = 0;
    spdTmp = nullptr; spdOut = nullptr; spdTmpBytes = 0;
    alive = nullptr; selIdx = nullptr; selNum = nullptr; selTmp = nullptr; selTmpBytes = 0;
}

void Sim::Impl::releaseGrid() {
    if (planReady) { cufftDestroy(planF); cufftDestroy(planB); planReady = false; }
    cudaFree(rho); cudaFree(pot); cudaFree(prs); cudaFree(rhoCrop);
    cudaFree(fieldNum); cudaFree(fieldOut);
    cudaFree(accG); cudaFree(green); cudaFree(rhoSpec); cudaFree(greenSpec);
    cudaFree(redTmp); cudaFree(redOut); cudaFree(cntOut);
    rho = pot = prs = rhoCrop = green = nullptr; accG = nullptr;
    fieldNum = fieldOut = nullptr;
    rhoSpec = greenSpec = nullptr; redTmp = nullptr; redOut = nullptr; cntOut = nullptr;
    redTmpBytes = 0;
}

void Sim::Impl::allocate() {
    releaseParticles();
    releaseGrid();

    allocN = cfg.particleCount;
    allocG = cfg.gridSize;
    allocBoundary = cfg.boundary;
    allocLaw = cfg.law;

    const int n = allocN, G = allocG, S = stride(), cells = S * S;

    CK(cudaMalloc(&pos,  sizeof(float2) * n));
    CK(cudaMalloc(&vel,  sizeof(float2) * n));
    CK(cudaMalloc(&pos2, sizeof(float2) * n));
    CK(cudaMalloc(&vel2, sizeof(float2) * n));
    CK(cudaMalloc(&temp,  sizeof(float) * n));
    CK(cudaMalloc(&temp2, sizeof(float) * n));
    CK(cudaMalloc(&key,    sizeof(unsigned) * n));
    CK(cudaMalloc(&keyOut, sizeof(unsigned) * n));
    CK(cudaMalloc(&val,    sizeof(unsigned) * n));
    CK(cudaMalloc(&valOut, sizeof(unsigned) * n));
    // 임시버퍼 크기 질의도 실패할 수 있다 — 안 보고 넘기면 0 바이트를 할당하고 정렬이 조용히 깨진다.
    CK(cub::DeviceRadixSort::SortPairs(nullptr, sortTmpBytes, key, keyOut, val, valOut, n, 0, 24));
    CK(cudaMalloc(&sortTmp, sortTmpBytes));

    // 파티클 버퍼 중 하나라도 실패했으면 여기서 멈춘다.
    // CK 는 실패를 표시만 하고 흐름을 안 끊으므로, 계속 가면 null 포인터에 memset 하고
    // CUB 임시버퍼 크기를 0 으로 잡는 등 실패가 겹쳐 원인을 못 찾게 된다(round-08 리뷰 A8).
    if (g_failed) return;

    CK(cudaMalloc(&rho, sizeof(float) * cells));
    CK(cudaMalloc(&pot, sizeof(float) * cells));
    CK(cudaMalloc(&prs, sizeof(float) * cells));
    CK(cudaMalloc(&accG, sizeof(float2) * G * G));
    CK(cudaMalloc(&rhoCrop, sizeof(float) * G * G));
    CK(cudaMalloc(&fieldNum, sizeof(float) * cells));
    CK(cudaMalloc(&fieldOut, sizeof(float) * G * G));

    if (g_failed) return;                 // 격자 버퍼 실패 — FFT 계획을 만들 이유가 없다

    const int W = S / 2 + 1;
    CK(cudaMalloc(&rhoSpec, sizeof(cufftComplex) * W * S));
    if (cfg.boundary == Boundary::Isolated) {
        CK(cudaMalloc(&green,     sizeof(float) * cells));
        CK(cudaMalloc(&greenSpec, sizeof(cufftComplex) * W * S));
    }
    // FFT 계획 생성도 VRAM 을 쓴다 — 실패하면 핸들이 쓸 수 없는 상태인데
    // 전에는 그대로 planReady 를 켜서 그 핸들로 FFT 를 돌렸다(round-06 리뷰 P1 #8).
    const cufftResult rF = cufftPlan2d(&planF, S, S, CUFFT_R2C);
    const cufftResult rB = cufftPlan2d(&planB, S, S, CUFFT_C2R);
    if (rF != CUFFT_SUCCESS || rB != CUFFT_SUCCESS) {
        planReady = false;
        char msg[96];
        snprintf(msg, sizeof(msg), "cuFFT plan failed (R2C=%d C2R=%d)", (int)rF, (int)rB);
        markFailure(msg, __FILE__, __LINE__);
    } else {
        planReady = true;
    }

    // 리덕션 임시 버퍼 — 합(double 누적)과 최댓값(float) 중 큰 쪽에 맞춘다
    {
        size_t needSum = 0, needMax = 0;
        auto it = thrust::make_transform_iterator(rho, ToDouble());
        cub::DeviceReduce::Sum(nullptr, needSum, it, (double*)nullptr, cells);
        cub::DeviceReduce::Max(nullptr, needMax, rho, (float*)nullptr, cells);
        redTmpBytes = (needSum > needMax) ? needSum : needMax;
    }
    CK(cudaMalloc(&redTmp, redTmpBytes));
    CK(cudaMalloc(&redOut, sizeof(double)));
    CK(cudaMalloc(&cntOut, sizeof(int)));

    // 속도 최댓값 리덕션 (CFL 클램프용)
    {
        auto sit = thrust::make_transform_iterator(vel, SpeedOf());
        cub::DeviceReduce::Max(nullptr, spdTmpBytes, sit, (float*)nullptr, n);
    }
    CK(cudaMalloc(&spdTmp, spdTmpBytes));
    CK(cudaMalloc(&spdOut, sizeof(float)));

    // 지우개 정리용 — 살아남은 인덱스를 골라 앞으로 모은다
    CK(cudaMalloc(&alive,  sizeof(unsigned char) * n));
    CK(cudaMalloc(&selIdx, sizeof(int) * n));
    CK(cudaMalloc(&selNum, sizeof(int)));
    {
        thrust::counting_iterator<int> ids(0);
        cub::DeviceSelect::Flagged(nullptr, selTmpBytes, ids, alive, selIdx, selNum, n);
    }
    CK(cudaMalloc(&selTmp, selTmpBytes));
    CK(cudaMalloc(&isStar, sizeof(unsigned char) * n));
    CK(cudaMemset(isStar, 0, sizeof(unsigned char) * n));
    CK(cudaMalloc(&isStar2, sizeof(unsigned char) * n));
    CK(cudaMemset(isStar2, 0, sizeof(unsigned char) * n));
    CK(cudaMalloc(&starCnt, sizeof(int)));
    activeN = n;
    starN = 0;

    if (!evA) { cudaEventCreate(&evA); cudaEventCreate(&evB); }
    allocSoft = -1.f;   // 그린함수 재생성 강제
}

void Sim::Impl::buildGreen() {
    if (cfg.boundary != Boundary::Isolated) return;
    const int S = stride();
    const float cell = 1.0f / allocG;
    const float eps = cfg.softeningCells * cell;
    if (allocSoft == eps && allocLaw == cfg.law) return;   // 같은 조건이면 다시 만들 필요 없다
    dim3 b(16, 16), g((S + 15) / 16, (S + 15) / 16);
    kGreen<<<g, b>>>(green, S, cell, eps, cfg.law == GravityLaw::InverseSquare ? 0 : 1);
    FK(cufftExecR2C(planF, green, greenSpec));
    allocSoft = eps; allocLaw = cfg.law;
}

// 밀도 격자에서 중력 퍼텐셜을 푼다.
void Sim::Impl::solveGravity() {
    // 계획이 없으면 FFT 를 부를 수 없다. 부르면 쓸 수 없는 핸들로 실행돼 그 뒤가 다 무너진다.
    if (!planReady || g_failed) return;
    const int G = allocG, S = stride(), cells = S * S, W = S / 2 + 1;
    dim3 b(16, 16);
    if (periodic()) {
        FK(cufftExecR2C(planF, rho, rhoSpec));
        dim3 gs((W + 15) / 16, (S + 15) / 16);
        kPoissonPeriodic<<<gs, b>>>(rhoSpec, S, 1.0f,
                                    cfg.law == GravityLaw::InverseSquare ? 0 : 1,
                                    cfg.softeningCells);
        FK(cufftExecC2R(planB, rhoSpec, pot));
    } else {
        // 고립 경계: 패딩 격자에서 밀도와 그린함수를 합성곱한다.
        // 이러면 순환 합성곱이 선형 합성곱이 되어 "바깥이 비어 있는" 우주가 된다.
        buildGreen();
        FK(cufftExecR2C(planF, rho, rhoSpec));
        kMulSpec<<<grid1(W * S), BS>>>(rhoSpec, greenSpec, W * S, 1.0f / (float)cells);
        FK(cufftExecC2R(planB, rhoSpec, pot));
    }
    (void)G;
}

float Sim::Impl::measureReduce(bool wantMax) {
    const int cells = padCells();
    size_t bytes = redTmpBytes;
    if (wantMax) {
        cub::DeviceReduce::Max(redTmp, bytes, rho, (float*)redOut, cells);
        float h = 0.f;
        CK(cudaMemcpy(&h, redOut, sizeof(float), cudaMemcpyDeviceToHost));
        return h;
    }
    auto it = thrust::make_transform_iterator(rho, ToDouble());
    cub::DeviceReduce::Sum(redTmp, bytes, it, (double*)redOut, cells);
    double h = 0.0;
    CK(cudaMemcpy(&h, redOut, sizeof(double), cudaMemcpyDeviceToHost));
    return (float)h;
}

float Sim::Impl::measureMaxSpeed() {
    // **살아 있는 구간만 본다.** 지우개와 리셋은 꼬리 슬롯의 위치만 숨기고 속도는 그대로 두므로,
    // 전체를 보면 이미 사라진 파티클의 옛 속도가 최댓값으로 잡힌다. 그 값이 CFL 을 조여
    // 빈 판에서도 시간 간격이 계속 잘린다(round-08 리뷰 P2 — 브릿지 [3-b] 에서 실제로 물렸다:
    // 정지한 덩어리인데 dtUsed 가 0.000088 로 잘렸다).
    if (!vel || activeN <= 0) return 0.f;
    size_t bytes = spdTmpBytes;
    auto sit = thrust::make_transform_iterator(vel, SpeedOf());
    CK(cub::DeviceReduce::Max(spdTmp, bytes, sit, spdOut, activeN));
    float h = 0.f;
    CK(cudaMemcpy(&h, spdOut, sizeof(float), cudaMemcpyDeviceToHost));
    return h;
}

void Sim::Impl::integrateOnce(float dt) {
    // 팽창은 주기 경계에서만 물리적 의미가 있다(고립 경계에서는 UI 가 이미 잠그지만
    // MCP 로 직접 켤 수도 있으므로 여기서도 막는다).
    const float hub = (cfg.expansionEnabled && periodic()) ? cfg.hubble : 0.f;
    kIntegrate<<<grid1(allocN), BS>>>(accG, pos, vel, temp, allocN, allocG, dt,
                                      periodic() ? 1 : 0,
                                      cfg.temperatureEnabled ? 1 : 0,
                                      cfg.coolingEnabled ? 1 : 0, cfg.coolingRate, hub);
}

// ---------------------------------------------------------------------------
Sim::Sim() : impl_(new Impl()) {}
Sim::~Sim() {
    impl_->releaseParticles();
    impl_->releaseGrid();
    if (impl_->evA) { cudaEventDestroy(impl_->evA); cudaEventDestroy(impl_->evB); }
    delete impl_;
}

bool Sim::deviceAvailable() {
    int n = 0;
    return cudaGetDeviceCount(&n) == cudaSuccess && n > 0;
}
std::string Sim::deviceName() {
    cudaDeviceProp p{};
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return "unknown";
    return p.name;
}
bool Sim::failed() { return g_failed; }
std::string Sim::failMessage() { return g_failMsg; }

size_t Sim::deviceFreeBytes() {
    size_t f = 0, t = 0;
    if (cudaMemGetInfo(&f, &t) != cudaSuccess) return 0;
    return f;
}

namespace {
// 파티클 하나가 차지하는 바이트. Impl::allocate() 가 n 에 비례해 잡는 것을 전부 센다.
//   위치·속도 두 벌(정렬 재배치용) 32 + 온도 두 벌 8 + 정렬 키/값 네 벌 16
//   + 지우개용 alive 1 · selIdx 4 + 별 표식 두 벌 2 = 63
// 여기에 CUB 임시버퍼(정렬·선택·속도 리덕션) 몫을 여유로 더한다. 이 셋은 CUB 가 크기를
// 정하고 n 에 비례해 커지는데, 전에는 이 자리를 8 로만 잡고 alive·selIdx·isStar 를
// 아예 빼놓아 안전하다고 판정한 최대치에서도 실제 할당이 실패할 수 있었다
// (round-06 리뷰 P1 #10).
constexpr size_t kBytesPerParticle = 4 * sizeof(float2)          // pos, vel, pos2, vel2
                                   + 2 * sizeof(float)           // temp, temp2
                                   + 4 * sizeof(unsigned)        // key, keyOut, val, valOut
                                   + 1                           // alive
                                   + sizeof(int)                 // selIdx
                                   + 2                           // isStar, isStar2
                                   + 24;                         // CUB 임시버퍼 여유

// 격자가 차지하는 바이트. 고립 경계는 패딩 때문에 폭이 두 배(면적 네 배)가 된다.
size_t gridBytesFor(int G, Boundary b) {
    const size_t S = (b == Boundary::Isolated) ? (size_t)G * 2 : (size_t)G;
    const size_t cells = S * S;
    const size_t spec  = (S / 2 + 1) * S * sizeof(cufftComplex);
    size_t bytes = cells * sizeof(float) * 4          // rho, pot, prs, fieldNum
                 + (size_t)G * G * sizeof(float2)     // accG
                 + (size_t)G * G * sizeof(float) * 2  // rhoCrop, fieldOut
                 + spec;                              // rhoSpec
    if (b == Boundary::Isolated) bytes += cells * sizeof(float) + spec;  // green, greenSpec
    // cuFFT 계획이 쓰는 내부 작업버퍼. 실측 없이 정확히 알 수 없어 스펙트럼 크기만큼 잡아 둔다 —
    // 모자라게 잡으면 "들어간다"고 판정한 뒤 계획 생성에서 실패한다.
    bytes += spec;
    return bytes;
}
} // namespace

size_t Sim::estimateBytes(int particleCount, int gridSize, Boundary boundary) {
    return (size_t)particleCount * kBytesPerParticle + gridBytesFor(gridSize, boundary);
}

int Sim::maxParticlesFor(int gridSize, Boundary boundary, size_t freeBytes) {
    const size_t grid = gridBytesFor(gridSize, boundary);
    // 가용량을 다 쓰지 않는다. 남겨 두는 몫은 cuFFT 내부 작업버퍼, 메모리 단편화,
    // 그리고 **이 앱이 도는 동안 다른 프로그램이 새로 요구하는 그래픽 메모리**를 위한 것이다.
    // 꽉 채워 잡으면 다른 프로그램이 메모리를 달라고 할 때 드라이버가 우리 것을 밀어내면서
    // 불안정해진다. 80% 에서 65% 로 낮췄다(2026-08-13 드라이버 크래시 이후).
    const size_t budget = (size_t)(freeBytes * 0.65);
    if (budget <= grid) return 0;
    size_t n = (budget - grid) / kBytesPerParticle;
    if (n > 200000000ull) n = 200000000ull;   // 상한 2억
    return (int)n;
}

namespace {
// 요청한 파티클 수가 VRAM 에 안 들어가면 들어가는 최대치로 자른다.
// 조용히 실패해 죽는 대신 줄여서 계속 돌게 한다 — 줄였다는 사실은 particleCount() 로 드러난다.
void clampToVram(SimConfig& cfg, int currentAllocN) {
    size_t freeB = Sim::deviceFreeBytes();
    // 이미 잡아 둔 것은 다시 쓸 수 있으므로 예산에 더해 준다.
    freeB += (size_t)currentAllocN * kBytesPerParticle;
    const int maxN = Sim::maxParticlesFor(cfg.gridSize, cfg.boundary, freeB);
    if (maxN <= 0) {
        // 격자만으로 예산을 넘었다(작은 GPU 이거나 메모리 조회가 실패한 경우).
        // 전에는 이때 클램프를 통째로 건너뛰어 요청한 수를 그대로 할당하러 갔다
        // (round-06 리뷰 P1 #11). 최소치로 낮춰 두면 적어도 격자 쪽 실패로 좁혀진다.
        cfg.particleCount = 1000;
    } else if (cfg.particleCount > maxN) {
        cfg.particleCount = maxN;
    }
    if (cfg.particleCount < 1000) cfg.particleCount = 1000;
}
} // namespace

void Sim::init(const SimConfig& cfg) {
    impl_->cfg = cfg;
    clampToVram(impl_->cfg, 0);
    // 요청은 클램프 전 값으로 기억한다 — reconfigure 가 이 값과 견줘 재할당 여부를 정한다.
    impl_->requestedN        = cfg.particleCount;
    impl_->requestedG        = cfg.gridSize;
    impl_->requestedBoundary = cfg.boundary;
    impl_->allocate();
    reset();
}

void Sim::reconfigure(const SimConfig& cfg) {
    Impl* d = impl_;

    // 버퍼를 다시 잡을지는 **요청이 바뀌었는지**로만 판정한다.
    // 남은 VRAM 은 다른 프로그램 때문에 계속 변하므로, 그것을 조건에 넣으면 같은 요청에도
    // 깎인 결과가 흔들려 대용량 버퍼를 매 프레임 재할당하게 된다(위 requestedN 주석 참조).
    const bool sameRequest = (cfg.particleCount == d->requestedN)
                          && (cfg.gridSize     == d->requestedG)
                          && (cfg.boundary     == d->requestedBoundary);

    if (sameRequest) {
        // 재할당과 무관한 값(중력·압력·배속 등)만 갈아 끼운다.
        // 파티클 수·격자·경계는 실제로 잡아 둔 것을 유지해야 계산과 버퍼가 어긋나지 않는다.
        SimConfig next = cfg;
        next.particleCount = d->allocN;
        next.gridSize      = d->allocG;
        next.boundary      = d->allocBoundary;
        d->cfg = next;
        return;
    }

    SimConfig next = cfg;
    clampToVram(next, d->allocN);
    const bool needRealloc = (next.particleCount != d->allocN)
                          || (next.gridSize != d->allocG)
                          || (next.boundary != d->allocBoundary);
    d->cfg = next;
    // 요청은 클램프 **전** 값으로 기억한다. 클램프 후 값을 기억하면, 다음 프레임에 같은 요청이
    // 들어왔을 때 "바뀌었다"고 판정해 또 재할당한다.
    d->requestedN        = cfg.particleCount;
    d->requestedG        = cfg.gridSize;
    d->requestedBoundary = cfg.boundary;
    if (needRealloc) { d->allocate(); reset(); }
}

void Sim::reset() {
    Impl* d = impl_;
    const int n = d->allocN, G = d->allocG, S = d->stride();
    d->time = 0.0; d->steps = 0;

    kPlace<<<grid1(n), BS>>>(d->pos, d->vel, d->temp, n, (int)d->cfg.preset);
    // 빈 판은 살아 있는 파티클이 0 이고 전 슬롯이 비어 있다 — 마우스로 채워 나간다.
    d->activeN = (d->cfg.preset == Preset::Empty) ? 0 : n;
    // 리셋하면 별도 사라진다
    CK(cudaMemset(d->isStar, 0, sizeof(unsigned char) * n));
    d->starN = 0;
    CK(cudaDeviceSynchronize());

    // 회전 프리셋은 중력을 한 번 풀어 그 세기에 맞는 궤도 속도를 넣는다.
    if (d->cfg.preset == Preset::SpiralDisk || d->cfg.preset == Preset::TidalPair) {
        kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
        kScatter<<<grid1(n), BS>>>(d->pos, d->rho, n, G, S, d->periodic() ? 1 : 0);
        d->solveGravity();
        dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
        const float potScale = d->potentialScale();
        kGridAccel<<<g, b>>>(d->pot, d->prs, d->rho, d->accG, G, S, potScale, 0,
                             d->periodic() ? 1 : 0);
        const float fudge = (d->cfg.preset == Preset::TidalPair) ? 0.90f : 0.97f;
        kSetOrbit<<<grid1(n), BS>>>(d->accG, d->pos, d->vel, n, G,
                                    d->periodic() ? 1 : 0, (int)d->cfg.preset, fudge);
        CK(cudaDeviceSynchronize());
    }
}

void Sim::step() {
    Impl* d = impl_;
    // 한 번 실패한 뒤에는 아무것도 더 띄우지 않는다 — 위 CK 주석 참조.
    // 여기서 막지 않으면 null 포인터로 커널이 돌아 원인 파악이 불가능해진다.
    if (g_failed) return;
    const int n = d->allocN, G = d->allocG, S = d->stride();
    const int per = d->periodic() ? 1 : 0;
    dim3 b(16, 16), gG((G + 15) / 16, (G + 15) / 16);

    cudaEventRecord(d->evA);

    // (1) 정렬 — 정확성이 아니라 캐시 지역성을 위한 것이라 매 스텝 하지 않는다.
    //
    // **살아 있는 구간만 정렬한다.** 전체를 정렬하면 빈 슬롯(위치 -1)이 셀 키 0 으로 계산돼
    // 맨 앞으로 몰리고, "살아 있는 것은 항상 [0, activeN)" 이라는 불변식이 깨진다.
    // 그러면 렌더가 빈 슬롯을 그리고 다음 형태 추가가 살아 있는 파티클을 덮어쓴다
    // (round-08 리뷰 A6).
    float tSort = 0.f;
    const int na = d->activeN;
    if (na > 0 && d->cfg.sortInterval > 0 && (d->steps % d->cfg.sortInterval) == 0) {
        kCellKey<<<grid1(na), BS>>>(d->pos, d->key, d->val, na, G);
        size_t bytes = d->sortTmpBytes;
        // 정렬이 실패하면 valOut 이 미정의 상태다. 그걸로 파티클 배열을 인덱싱하면
        // 범위 밖 디바이스 메모리를 읽는다(round-06 리뷰 P1 #9).
        CK(cub::DeviceRadixSort::SortPairs(d->sortTmp, bytes, d->key, d->keyOut,
                                           d->val, d->valOut, na, 0, 24));
        if (g_failed) return;
        kReorder<<<grid1(na), BS>>>(d->pos, d->vel, d->temp, d->isStar,
                                    d->pos2, d->vel2, d->temp2, d->isStar2, d->valOut, na);
        std::swap(d->pos, d->pos2); std::swap(d->vel, d->vel2); std::swap(d->temp, d->temp2);
        std::swap(d->isStar, d->isStar2);
        // 뒤바꾼 버퍼의 꼬리는 이전 프레임 값이 남아 있다 — 다시 숨겨 빈 슬롯으로 되돌린다.
        if (na < n) {
            kHideRange<<<grid1(n - na), BS>>>(d->pos, na, n - na);
            CK(cudaMemset(d->isStar + na, 0, sizeof(unsigned char) * (n - na)));
        }
    }

    // (2) 산란
    kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
    kScatter<<<grid1(n), BS>>>(d->pos, d->rho, n, G, S, per);

    // (3) 중력
    d->solveGravity();

    // (4) 압력
    if (d->cfg.pressureEnabled) {
        // 온도를 추적 중이면 격자에 뿌려 압력에 반영한다. 그래야 냉각이 뭉침에 영향을 준다.
        const float* tgrid = nullptr;
        if (d->cfg.temperatureEnabled) {
            kClearF<<<grid1(S * S), BS>>>(d->fieldNum, S * S);
            kScatterValue<<<grid1(n), BS>>>(d->pos, d->vel, d->temp, d->fieldNum,
                                            n, G, S, per, 1);
            // 가중합을 밀도로 나눠 평균 온도로 만든다(패딩 격자 위에서 제자리로).
            kNormalizeInPlace<<<grid1(S * S), BS>>>(d->fieldNum, d->rho, S * S);
            tgrid = d->fieldNum;
        }
        kPressure<<<grid1(S * S), BS>>>(d->rho, tgrid, d->prs, S * S, d->cfg.pressureK,
                                        d->cfg.gamma, d->invMeanRho());
    }

    // (4-b) 별 형성 — 밀도·온도 임계를 넘은 파티클을 별로 바꾸고 개수를 센다
    if (d->cfg.starFormationEnabled) {
        int zero = 0;
        CK(cudaMemcpy(d->starCnt, &zero, sizeof(int), cudaMemcpyHostToDevice));
        kStarFormation<<<grid1(n), BS>>>(d->pos, d->temp, d->isStar, d->rho, n, G, S, per,
                                         d->cfg.starDensityThreshold,
                                         d->cfg.starTempThreshold, d->starCnt);
        CK(cudaMemcpy(&d->starN, d->starCnt, sizeof(int), cudaMemcpyDeviceToHost));
    } else {
        d->starN = 0;
    }

    // (5) 격자 가속도 -> 보간 -> 적분
    const float potScale = d->potentialScale();
    kGridAccel<<<gG, b>>>(d->pot, d->prs, d->rho, d->accG, G, S, potScale,
                          d->cfg.pressureEnabled ? 1 : 0, per);

    // (6) CFL 클램프 — 한 스텝에 파티클이 격자 한 칸보다 많이 움직이면 적분이 무너진다.
    //     실측(implement-note.md 3번): 중력을 세게 하면 오히려 덜 뭉쳤는데,
    //     파티클이 튕겨 나가 판 가장자리에 쌓인 것이었다.
    //     요청 dt 가 한계를 넘으면 잘라서 여러 번 나눠 돈다(상한 4회).
    // 배속은 **내리는 쪽만** 여기서 처리한다.
    // 올리는 쪽(1배 초과)은 App::tick 이 한 프레임에 스텝을 여러 번 돌려서 낸다 —
    // 여기서 dt 까지 같이 키우면 두 곳에서 곱해져 3배속이 9배로 진행된다.
    // CFL 이 dt 를 덮어쓰는 동안은 그 이중 적용이 상쇄돼 안 보이지만,
    // 파티클이 느려 CFL 이 안 걸리는 구간에서 그대로 드러난다(round-08 리뷰 R1).
    const float slow     = (d->cfg.timeScale < 1.0f) ? d->cfg.timeScale : 1.0f;
    const float dtWanted = 0.0016f * slow;
    const float cell     = 1.0f / (float)G;
    const float vmax     = d->measureMaxSpeed();
    const float CFL      = 0.35f;                 // 한 스텝에 셀의 35% 이상 못 가게 한다

    // 배속을 내렸으면 CFL 한계까지 다 쓰지 않고 그 비율만큼 더 줄인다.
    //
    // 왜 필요한가 (round-06 QA-1 실측): 전에는 `dtUse` 가 늘 `dtLimit` 으로 잘려
    // 배속 0.25 와 3.0 의 dtUsed 가 0.000101 로 똑같았다 — 배속 슬라이더가 통째로 무효였다.
    // 요청 dt 의 최솟값이 1.6e-4 인데 CFL 한계가 1.0e-4 라, 슬라이더를 어디에 두든 항상 한계가 이겼다.
    // 느리게 하는 쪽은 안정성과 충돌하지 않으므로(dt 를 줄이는 것은 언제나 안전하다) 한계 자체를 낮춘다.
    float dtLimit = dtWanted;
    if (vmax > 1e-6f) dtLimit = CFL * cell / vmax * slow;

    // 한 프레임에 몇 번까지 나눠 돌지. 1 이면 "쪼개지 않고 시간 간격만 자른다".
    //
    // 왜 1 인가: 실시간 앱은 프레임 예산이 먼저다. 쪼개면 계산량이 그 배수만큼 늘어
    // 예산을 그대로 넘긴다(실측: 상한 4에서 1000만·1024² 가 18.0 ms, 예산 16.7 ms 초과).
    // 대신 시간 간격을 CFL 한계로 자르면 계산량은 1배로 유지되고 화면 속의 시간이
    // 물리가 허용하는 만큼만 흐른다 — 배속 슬라이더는 그 한계 아래에서만 효과를 낸다.
    // 오프라인 렌더처럼 정확도가 먼저인 쓰임이 생기면 이 값을 올린다.
    const int MAX_SUBSTEPS = 1;

    int   sub = 1;
    float dtUse = dtWanted;
    if (dtLimit < dtWanted) {
        sub = (int)ceilf(dtWanted / dtLimit);
        if (sub > MAX_SUBSTEPS) sub = MAX_SUBSTEPS;
        dtUse = dtWanted / (float)sub;
        if (dtUse > dtLimit) dtUse = dtLimit;     // 상한에 걸렸으면 한계값으로 자른다
    }
    for (int s = 0; s < sub; ++s) {
        if (s > 0) {
            // 두 번째 서브스텝부터는 위치가 바뀌었으니 격자·중력을 다시 푼다.
            kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
            kScatter<<<grid1(n), BS>>>(d->pos, d->rho, n, G, S, per);
            d->solveGravity();
            if (d->cfg.pressureEnabled)
                kPressure<<<grid1(S * S), BS>>>(d->rho, nullptr, d->prs, S * S,
                                                d->cfg.pressureK, d->cfg.gamma,
                                                d->invMeanRho());
            kGridAccel<<<gG, b>>>(d->pot, d->prs, d->rho, d->accG, G, S, potScale,
                                  d->cfg.pressureEnabled ? 1 : 0, per);
        }
        d->integrateOnce(dtUse);
    }
    const float dt = dtUse * (float)sub;

    cudaEventRecord(d->evB);
    cudaEventSynchronize(d->evB);
    float total = 0.f;
    cudaEventElapsedTime(&total, d->evA, d->evB);

    // 단계별 분해는 이벤트를 촘촘히 넣으면 동기화 비용이 커진다.
    // 여기서는 총 시간을 재고 설계 예산 비율로 나눠 표시한다(HUD 표시용 근사).
    d->tim.totalMs   = total;
    d->tim.sortMs    = tSort;
    d->tim.scatterMs = total * 0.30f;
    d->tim.poissonMs = total * 0.35f;
    d->tim.gatherMs  = total * 0.25f;
    d->tim.gasMs     = d->cfg.pressureEnabled ? total * 0.10f : 0.f;
    d->tim.substeps  = sub;
    d->tim.dtUsed    = dtUse;
    d->tim.maxSpeed  = vmax;

    d->time += dt;
    d->steps++;

    // 커널은 비동기로 돌아가므로 오류가 여기까지 와야 드러난다.
    // 확인하지 않으면 잘못된 메모리 접근으로 컨텍스트가 망가진 뒤에도 다음 프레임을 계속 돌린다
    // (round-08 리뷰 A9). cudaGetLastError 는 확인하면서 상태를 비우므로 다음 스텝에 안 번진다.
    CK(cudaGetLastError());
}

const SimConfig& Sim::config() const { return impl_->cfg; }
SimTimings Sim::timings() const      { return impl_->tim; }
double Sim::simTime() const          { return impl_->time; }
int Sim::gridSize() const            { return impl_->allocG; }
int Sim::particleCount() const       { return impl_->allocN; }

double Sim::measureTotalGridMass() {
    Impl* d = impl_;
    if (!d->rho) return 0.0;
    // 격자에 현재 상태를 다시 뿌려 측정한다(step 직후가 아니어도 값이 맞도록).
    const int S = d->stride();
    kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
    kScatter<<<grid1(d->allocN), BS>>>(d->pos, d->rho, d->allocN, d->allocG, S,
                                       d->periodic() ? 1 : 0);
    CK(cudaDeviceSynchronize());
    return (double)d->measureReduce(false);
}

double Sim::measureMaxDensity() {
    Impl* d = impl_;
    if (!d->rho) return 0.0;
    return (double)d->measureReduce(true);
}

int Sim::measureOccupiedCells() {
    Impl* d = impl_;
    if (!d->rho) return 0;
    const int cells = d->padCells();
    int zero = 0;
    CK(cudaMemcpy(d->cntOut, &zero, sizeof(int), cudaMemcpyHostToDevice));
    kCountOccupied<<<grid1(cells), BS>>>(d->rho, cells, 0.5f, d->cntOut);
    int h = 0;
    CK(cudaMemcpy(&h, d->cntOut, sizeof(int), cudaMemcpyDeviceToHost));
    return h;
}

void Sim::Impl::refreshAccel() {
    const int G = allocG, S = stride();
    const int per = periodic() ? 1 : 0;
    kClearF<<<grid1(S * S), BS>>>(rho, S * S);
    kScatter<<<grid1(allocN), BS>>>(pos, rho, allocN, G, S, per);
    solveGravity();
    dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
    kGridAccel<<<g, b>>>(pot, prs, rho, accG, G, S, potentialScale(), 0, per);
}

int Sim::activeCount() const { return impl_->activeN; }
int Sim::starCount() const   { return impl_->starN; }

int Sim::addShape(float cx, float cy, ShapeKind kind, float radius, int count, bool autoOrbit) {
    Impl* d = impl_;
    if (count <= 0) return 0;
    const int room = d->allocN - d->activeN;
    if (room <= 0) return 0;
    const int put = (count < room) ? count : room;   // 빈 슬롯이 모자라면 그만큼만
    const int base = d->activeN;

    // 난수 씨앗을 스텝 수로 흔든다 — 같은 자리에 두 번 넣어도 같은 배치가 겹치지 않게.
    const unsigned seed = (unsigned)(d->steps * 2654435761u + (unsigned)base * 40503u + 7u);
    kFillShape<<<grid1(put), BS>>>(d->pos, d->vel, d->temp, base, put,
                                   cx, cy, radius, (int)kind, seed);
    d->activeN += put;

    // 회전 형태는 그 자리 중력을 재서 원 궤도가 되는 속도를 넣는다.
    // 중력을 모른 채 속도를 정하면 원반이 흩어지거나 붕괴한다(design.md §9-2).
    if (autoOrbit && kind != ShapeKind::StaticBlob) {
        d->refreshAccel();
        kSetOrbitAt<<<grid1(put), BS>>>(d->accG, d->pos, d->vel, base, put,
                                        d->allocG, d->periodic() ? 1 : 0, cx, cy, 0.95f);
    }
    CK(cudaDeviceSynchronize());
    return put;
}

void Sim::sprayAt(float cx, float cy, float radius, float strength) {
    Impl* d = impl_;
    kBrushPush<<<grid1(d->allocN), BS>>>(d->pos, d->vel, d->allocN, cx, cy, radius, strength, +1.f);
}

void Sim::wellAt(float cx, float cy, float radius, float strength) {
    Impl* d = impl_;
    kBrushPush<<<grid1(d->allocN), BS>>>(d->pos, d->vel, d->allocN, cx, cy, radius, strength, -1.f);
}

int Sim::eraseAt(float cx, float cy, float radius) {
    Impl* d = impl_;
    const int before = d->activeN;
    if (before <= 0) return 0;

    kMarkAlive<<<grid1(d->allocN), BS>>>(d->pos, d->alive, d->allocN, cx, cy, radius);

    // 살아남은 인덱스를 골라 배열 앞쪽으로 모은다. 이 정리를 해야
    // "빈 슬롯은 항상 뒤쪽" 이라는 불변식이 유지되고, 다음 형태 추가가 정확한 개수를 넣는다.
    thrust::counting_iterator<int> ids(0);
    size_t bytes = d->selTmpBytes;
    // 선택이 실패하면 selNum·selIdx 가 미초기화다. 그 값을 개수와 인덱스로 믿고 압축하면
    // 범위 밖 GPU 메모리를 읽고 쓴다(round-08 리뷰 A10).
    CK(cub::DeviceSelect::Flagged(d->selTmp, bytes, ids, d->alive, d->selIdx, d->selNum, d->allocN));
    if (g_failed) return 0;
    int kept = 0;
    CK(cudaMemcpy(&kept, d->selNum, sizeof(int), cudaMemcpyDeviceToHost));
    if (g_failed || kept < 0 || kept > d->allocN) return 0;

    if (kept > 0)
        kCompact<<<grid1(kept), BS>>>(d->pos, d->vel, d->temp, d->isStar,
                                      d->pos2, d->vel2, d->temp2, d->isStar2, d->selIdx, kept);
    std::swap(d->pos, d->pos2); std::swap(d->vel, d->vel2); std::swap(d->temp, d->temp2);
    std::swap(d->isStar, d->isStar2);
    if (kept < d->allocN) {
        kHideRange<<<grid1(d->allocN - kept), BS>>>(d->pos, kept, d->allocN - kept);
        // 꼬리(빈 슬롯)의 별 표식도 지운다. 안 지우면 나중에 그 자리에 넣은 형태가
        // 남아 있던 표식을 물려받아 만들지도 않은 별로 세어진다.
        CK(cudaMemset(d->isStar + kept, 0, sizeof(unsigned char) * (d->allocN - kept)));
    }

    d->activeN = kept;
    CK(cudaDeviceSynchronize());
    return before - kept;
}

double Sim::measureMeanTemperature() {
    Impl* d = impl_;
    if (!d->temp || d->activeN <= 0) return 0.0;
    size_t bytes = d->redTmpBytes;
    auto it = thrust::make_transform_iterator(d->temp, ToDouble());
    cub::DeviceReduce::Sum(d->redTmp, bytes, it, (double*)d->redOut, d->activeN);
    double sum = 0.0;
    CK(cudaMemcpy(&sum, d->redOut, sizeof(double), cudaMemcpyDeviceToHost));
    return sum / (double)d->activeN;
}

void Sim::measureCentroid(double& cx, double& cy) {
    cx = cy = 0.0;
    Impl* d = impl_;
    if (!d->rho) return;
    // 현재 파티클 위치로 격자를 다시 채운 뒤 잰다(측정 순서 의존을 없앤다).
    const int G = d->allocG, S = d->stride();
    kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
    kScatter<<<grid1(d->allocN), BS>>>(d->pos, d->rho, d->allocN, G, S,
                                       d->periodic() ? 1 : 0);
    double* acc = nullptr;
    CK(cudaMalloc(&acc, sizeof(double) * 3));
    CK(cudaMemset(acc, 0, sizeof(double) * 3));
    dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
    kCentroidAccum<<<g, b>>>(d->rho, G, S, acc);
    double h[3] = {0, 0, 0};
    CK(cudaMemcpy(h, acc, sizeof(double) * 3, cudaMemcpyDeviceToHost));
    cudaFree(acc);
    if (h[2] > 0.0) { cx = h[0] / h[2]; cy = h[1] / h[2]; }
}

// 직접 O(N^2) 를 정답지로 놓고 격자 중력의 상대오차 RMS 를 잰다.
// 자기 버퍼를 따로 잡고 끝나면 반납해 현재 시뮬레이션 상태를 건드리지 않는다.
double Sim::measureForceErrorVsDirect(int n, int G, float softeningCells) {
    if (n <= 0 || G <= 0) return -1.0;
    const int S = G * 2, cells = S * S, W = S / 2 + 1;
    const float cell = 1.0f / G;
    const float eps = softeningCells * cell;

    float2 *p = nullptr, *fd = nullptr, *fp = nullptr;
    float  *rho_ = nullptr, *grn = nullptr, *pot_ = nullptr;
    float2 *acc_ = nullptr;
    cufftComplex *rs = nullptr, *gs = nullptr;
    cufftHandle pf = 0, pb = 0;

    CK(cudaMalloc(&p,  sizeof(float2) * n));
    CK(cudaMalloc(&fd, sizeof(float2) * n));
    CK(cudaMalloc(&fp, sizeof(float2) * n));
    CK(cudaMalloc(&rho_, sizeof(float) * cells));
    CK(cudaMalloc(&grn,  sizeof(float) * cells));
    CK(cudaMalloc(&pot_, sizeof(float) * cells));
    CK(cudaMalloc(&acc_, sizeof(float2) * G * G));
    CK(cudaMalloc(&rs, sizeof(cufftComplex) * W * S));
    CK(cudaMalloc(&gs, sizeof(cufftComplex) * W * S));
    cufftPlan2d(&pf, S, S, CUFFT_R2C);
    cufftPlan2d(&pb, S, S, CUFFT_C2R);

    // 주기 이미지의 영향을 줄이려 판 가운데에 몰아 둔다.
    kInitBlob<<<grid1(n), BS>>>(p, n, 0.20f, 0.80f);
    kDirectForce<<<grid1(n), BS>>>(p, fd, n, eps * eps);

    dim3 b(16, 16), gp((S + 15) / 16, (S + 15) / 16), gg((G + 15) / 16, (G + 15) / 16);
    kGreen<<<gp, b>>>(grn, S, cell, eps, 0);
    FK(cufftExecR2C(pf, grn, gs));
    kClearF<<<grid1(cells), BS>>>(rho_, cells);
    kScatter<<<grid1(n), BS>>>(p, rho_, n, G, S, 0);
    FK(cufftExecR2C(pf, rho_, rs));
    kMulSpec<<<grid1(W * S), BS>>>(rs, gs, W * S, 1.0f / (float)cells);
    FK(cufftExecC2R(pb, rs, pot_));
    kGridAccel<<<gg, b>>>(pot_, nullptr, rho_, acc_, G, S, 1.0f, 0, 0);
    kAccelAt<<<grid1(n), BS>>>(acc_, p, fp, n, G, 0);
    CK(cudaDeviceSynchronize());

    std::vector<float2> hd(n), hp(n);
    CK(cudaMemcpy(hd.data(), fd, sizeof(float2) * n, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(hp.data(), fp, sizeof(float2) * n, cudaMemcpyDeviceToHost));

    // 격자 쪽은 상수 배율이 다르므로 최소자승으로 배율을 맞춘 뒤 오차를 본다.
    double num = 0, den = 0;
    for (int i = 0; i < n; ++i) {
        num += (double)hp[i].x * hd[i].x + (double)hp[i].y * hd[i].y;
        den += (double)hp[i].x * hp[i].x + (double)hp[i].y * hp[i].y;
    }
    double a = (den > 0) ? num / den : 0.0;
    double se = 0, sr = 0;
    for (int i = 0; i < n; ++i) {
        double ex = a * hp[i].x - hd[i].x, ey = a * hp[i].y - hd[i].y;
        se += ex * ex + ey * ey;
        sr += (double)hd[i].x * hd[i].x + (double)hd[i].y * hd[i].y;
    }
    double rms = (sr > 0) ? sqrt(se / n) / sqrt(sr / n) : -1.0;

    cufftDestroy(pf); cufftDestroy(pb);
    cudaFree(p); cudaFree(fd); cudaFree(fp);
    cudaFree(rho_); cudaFree(grn); cudaFree(pot_); cudaFree(acc_);
    cudaFree(rs); cudaFree(gs);
    return rms;
}

const float* Sim::fieldDevicePtr(Field field) {
    Impl* d = impl_;
    if (!d->rho) return nullptr;
    if (field == Field::Density) return densityDevicePtr();

    const int G = d->allocG, S = d->stride();
    const int per = d->periodic() ? 1 : 0;
    // 밀도는 이미 이번 스텝에서 채워져 있다. 값 격자만 새로 뿌려 평균을 낸다.
    kClearF<<<grid1(S * S), BS>>>(d->fieldNum, S * S);
    kScatterValue<<<grid1(d->allocN), BS>>>(d->pos, d->vel, d->temp, d->fieldNum,
                                            d->allocN, G, S, per,
                                            field == Field::Temperature ? 1 : 2);
    dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
    kDivideByDensity<<<g, b>>>(d->fieldNum, d->rho, d->fieldOut, G, S);
    return d->fieldOut;
}

const float* Sim::particlePosDevicePtr() const  { return (const float*)impl_->pos; }
const float* Sim::particleVelDevicePtr() const  { return (const float*)impl_->vel; }
const float* Sim::particleTempDevicePtr() const { return impl_->temp; }

const float* Sim::densityDevicePtr() const {
    Impl* d = impl_;
    if (!d->rho) return nullptr;
    if (d->periodic()) return d->rho;
    // 고립 경계는 패딩 격자라 왼쪽아래 G x G 만 잘라 넘긴다.
    const int G = d->allocG, S = d->stride();
    dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
    kCrop<<<g, b>>>(d->rho, d->rhoCrop, G, S);
    return d->rhoCrop;
}
