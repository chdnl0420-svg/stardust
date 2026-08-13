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
// CUDA 13(CCCL 3.x)에서 cub::TransformInputIterator 가 제거돼 thrust 쪽을 쓴다.
#include <thrust/iterator/transform_iterator.h>

#include <cmath>
#include <cstdio>
#include <vector>

// ---------------------------------------------------------------------------
// 오류 처리 — 코어는 조용히 기본값을 돌려주지 않는다. 실패를 표시하고 상위가 알게 한다.
// ---------------------------------------------------------------------------
#define CK(x)  do { cudaError_t e_ = (x); if (e_ != cudaSuccess) {                      \
                    printf("[sim] CUDA error %s:%d %s\n", __FILE__, __LINE__,           \
                           cudaGetErrorString(e_)); }                                   \
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
__global__ void kPoissonPeriodic(cufftComplex* F, int G, float scale, int law) {
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

__global__ void kPressure(const float* rho, float* prs, int n, float K, float gamma) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) prs[i] = K * powf(fmaxf(rho[i], 0.f), gamma);
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
                           int cooling, float coolRate) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;
    float2 v = vel[i];
    float2 a = sampleAcc(accG, p, G, periodic);
    v.x += a.x * dt; v.y += a.y * dt;

    if (trackTemp) {
        // 가속도와 속도가 반대 방향이면(=압축) 온도가 오른다. 충돌면이 달아오르는 것이 이 항이다.
        float t = temp[i] - (a.x * v.x + a.y * v.y) * dt * 0.6f;
        if (cooling) t -= t * coolRate * dt * 3.0f;
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
__global__ void kReorder(const float2* sp, const float2* sv, const float* st,
                         float2* dp, float2* dv, float* dt_, const unsigned* val, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned s = val[i];
    dp[i] = sp[s]; dv[i] = sv[s]; dt_[i] = st[s];
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

    cudaEvent_t evA = nullptr, evB = nullptr;

    int  stride() const { return (cfg.boundary == Boundary::Isolated) ? allocG * 2 : allocG; }
    int  padCells() const { int s = stride(); return s * s; }
    bool periodic() const { return cfg.boundary == Boundary::Periodic; }

    void releaseGrid();
    void releaseParticles();
    void allocate();
    void buildGreen();
    void solveGravity();
    float measureReduce(bool wantMax);
};

void Sim::Impl::releaseParticles() {
    cudaFree(pos); cudaFree(vel); cudaFree(pos2); cudaFree(vel2);
    cudaFree(temp); cudaFree(temp2);
    cudaFree(key); cudaFree(keyOut); cudaFree(val); cudaFree(valOut);
    cudaFree(sortTmp);
    pos = vel = pos2 = vel2 = nullptr; temp = temp2 = nullptr;
    key = keyOut = val = valOut = nullptr; sortTmp = nullptr; sortTmpBytes = 0;
}

void Sim::Impl::releaseGrid() {
    if (planReady) { cufftDestroy(planF); cufftDestroy(planB); planReady = false; }
    cudaFree(rho); cudaFree(pot); cudaFree(prs); cudaFree(rhoCrop);
    cudaFree(accG); cudaFree(green); cudaFree(rhoSpec); cudaFree(greenSpec);
    cudaFree(redTmp); cudaFree(redOut); cudaFree(cntOut);
    rho = pot = prs = rhoCrop = green = nullptr; accG = nullptr;
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
    cub::DeviceRadixSort::SortPairs(nullptr, sortTmpBytes, key, keyOut, val, valOut, n, 0, 24);
    CK(cudaMalloc(&sortTmp, sortTmpBytes));

    CK(cudaMalloc(&rho, sizeof(float) * cells));
    CK(cudaMalloc(&pot, sizeof(float) * cells));
    CK(cudaMalloc(&prs, sizeof(float) * cells));
    CK(cudaMalloc(&accG, sizeof(float2) * G * G));
    CK(cudaMalloc(&rhoCrop, sizeof(float) * G * G));

    const int W = S / 2 + 1;
    CK(cudaMalloc(&rhoSpec, sizeof(cufftComplex) * W * S));
    if (cfg.boundary == Boundary::Isolated) {
        CK(cudaMalloc(&green,     sizeof(float) * cells));
        CK(cudaMalloc(&greenSpec, sizeof(cufftComplex) * W * S));
    }
    cufftPlan2d(&planF, S, S, CUFFT_R2C);
    cufftPlan2d(&planB, S, S, CUFFT_C2R);
    planReady = true;

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
    cufftExecR2C(planF, green, greenSpec);
    allocSoft = eps; allocLaw = cfg.law;
}

// 밀도 격자에서 중력 퍼텐셜을 푼다.
void Sim::Impl::solveGravity() {
    const int G = allocG, S = stride(), cells = S * S, W = S / 2 + 1;
    dim3 b(16, 16);
    if (periodic()) {
        cufftExecR2C(planF, rho, rhoSpec);
        dim3 gs((W + 15) / 16, (S + 15) / 16);
        kPoissonPeriodic<<<gs, b>>>(rhoSpec, S, 1.0f,
                                    cfg.law == GravityLaw::InverseSquare ? 0 : 1);
        cufftExecC2R(planB, rhoSpec, pot);
    } else {
        // 고립 경계: 패딩 격자에서 밀도와 그린함수를 합성곱한다.
        // 이러면 순환 합성곱이 선형 합성곱이 되어 "바깥이 비어 있는" 우주가 된다.
        buildGreen();
        cufftExecR2C(planF, rho, rhoSpec);
        kMulSpec<<<grid1(W * S), BS>>>(rhoSpec, greenSpec, W * S, 1.0f / (float)cells);
        cufftExecC2R(planB, rhoSpec, pot);
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
size_t Sim::deviceFreeBytes() {
    size_t f = 0, t = 0;
    if (cudaMemGetInfo(&f, &t) != cudaSuccess) return 0;
    return f;
}

void Sim::init(const SimConfig& cfg) {
    impl_->cfg = cfg;
    impl_->allocate();
    reset();
}

void Sim::reconfigure(const SimConfig& cfg) {
    Impl* d = impl_;
    const bool needRealloc = (cfg.particleCount != d->allocN)
                          || (cfg.gridSize != d->allocG)
                          || (cfg.boundary != d->allocBoundary);
    d->cfg = cfg;
    if (needRealloc) { d->allocate(); reset(); }
}

void Sim::reset() {
    Impl* d = impl_;
    const int n = d->allocN, G = d->allocG, S = d->stride();
    d->time = 0.0; d->steps = 0;

    kPlace<<<grid1(n), BS>>>(d->pos, d->vel, d->temp, n, (int)d->cfg.preset);
    CK(cudaDeviceSynchronize());

    // 회전 프리셋은 중력을 한 번 풀어 그 세기에 맞는 궤도 속도를 넣는다.
    if (d->cfg.preset == Preset::SpiralDisk || d->cfg.preset == Preset::TidalPair) {
        kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
        kScatter<<<grid1(n), BS>>>(d->pos, d->rho, n, G, S, d->periodic() ? 1 : 0);
        d->solveGravity();
        dim3 b(16, 16), g((G + 15) / 16, (G + 15) / 16);
        const float potScale = d->periodic() ? d->cfg.gravity / (float)(S * S) : d->cfg.gravity;
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
    const int n = d->allocN, G = d->allocG, S = d->stride();
    const int per = d->periodic() ? 1 : 0;
    dim3 b(16, 16), gG((G + 15) / 16, (G + 15) / 16);

    cudaEventRecord(d->evA);

    // (1) 정렬 — 정확성이 아니라 캐시 지역성을 위한 것이라 매 스텝 하지 않는다.
    float tSort = 0.f;
    if (d->cfg.sortInterval > 0 && (d->steps % d->cfg.sortInterval) == 0) {
        cudaEvent_t s0 = d->evA;  (void)s0;
        kCellKey<<<grid1(n), BS>>>(d->pos, d->key, d->val, n, G);
        size_t bytes = d->sortTmpBytes;
        cub::DeviceRadixSort::SortPairs(d->sortTmp, bytes, d->key, d->keyOut,
                                        d->val, d->valOut, n, 0, 24);
        kReorder<<<grid1(n), BS>>>(d->pos, d->vel, d->temp,
                                   d->pos2, d->vel2, d->temp2, d->valOut, n);
        std::swap(d->pos, d->pos2); std::swap(d->vel, d->vel2); std::swap(d->temp, d->temp2);
    }

    // (2) 산란
    kClearF<<<grid1(S * S), BS>>>(d->rho, S * S);
    kScatter<<<grid1(n), BS>>>(d->pos, d->rho, n, G, S, per);

    // (3) 중력
    d->solveGravity();

    // (4) 압력
    if (d->cfg.pressureEnabled)
        kPressure<<<grid1(S * S), BS>>>(d->rho, d->prs, S * S, d->cfg.pressureK, d->cfg.gamma);

    // (5) 격자 가속도 -> 보간 -> 적분
    const float potScale = per ? d->cfg.gravity / (float)(S * S) : d->cfg.gravity;
    kGridAccel<<<gG, b>>>(d->pot, d->prs, d->rho, d->accG, G, S, potScale,
                          d->cfg.pressureEnabled ? 1 : 0, per);

    const float dt = 0.0016f * d->cfg.timeScale;
    kIntegrate<<<grid1(n), BS>>>(d->accG, d->pos, d->vel, d->temp, n, G, dt, per,
                                 d->cfg.temperatureEnabled ? 1 : 0,
                                 d->cfg.coolingEnabled ? 1 : 0, d->cfg.coolingRate);

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

    d->time += dt;
    d->steps++;
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
    cufftExecR2C(pf, grn, gs);
    kClearF<<<grid1(cells), BS>>>(rho_, cells);
    kScatter<<<grid1(n), BS>>>(p, rho_, n, G, S, 0);
    cufftExecR2C(pf, rho_, rs);
    kMulSpec<<<grid1(W * S), BS>>>(rs, gs, W * S, 1.0f / (float)cells);
    cufftExecC2R(pb, rs, pot_);
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
