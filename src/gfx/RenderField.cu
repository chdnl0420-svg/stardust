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

__device__ __forceinline__ float3 cmapThermal(float t) {
    t = fminf(fmaxf(t, 0.f), 1.f);
    // 열화상: 검정 -> 빨강 -> 노랑 -> 흰. 충격파면이 달아오르는 것을 보기 좋다.
    float r = fminf(t * 2.2f, 1.f);
    float g = fminf(fmaxf((t - 0.32f) * 1.9f, 0.f), 1.f);
    float b = fminf(fmaxf((t - 0.70f) * 3.2f, 0.f), 1.f);
    return make_float3(r, g, b);
}

// 격자를 화면 픽셀로 샘플링해 RGBA8 을 만든다.
// zoom/pan 은 화면 중앙을 기준으로 시뮬레이션 공간 [0,1]² 을 확대·이동한다.
__global__ void kShade(const float* rho, int G, uchar4* out, int W, int H,
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
        float t = __powf(fminf(fmaxf(__logf(1.f + d * bright) * 0.30f, 0.f), 1.f), invGamma);
        float3 c = (cmapKind == 2) ? cmapThermal(t)
                 : (cmapKind == 1) ? make_float3(t, t, t)
                                   : cmapAstro(t);
        px = make_uchar4((unsigned char)(c.x * 255.f),
                         (unsigned char)(c.y * 255.f),
                         (unsigned char)(c.z * 255.f), 255);
    }
    // GL 텍스처는 아래에서 위로 쌓이므로 y 를 뒤집어 담는다.
    out[(H - 1 - y) * W + x] = px;
}

// 파티클을 화면에 더한다. 겹칠수록 밝아지므로 밀집한 곳이 자연히 도드라진다.
// uchar4 에는 atomicAdd 가 없어 float3 누적 버퍼에 모았다가 뒤에서 색으로 바꾼다.
__global__ void kSplatPoints(const float2* pos, const float2* vel, const float* temp,
                             int n, float3* accum, int W, int H,
                             int colorBy, int cmapKind, float zoom, float panX, float panY,
                             float sizePx) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float2 p = pos[i];
    if (p.x < 0.f) return;                       // 빈 슬롯

    float u = (p.x - 0.5f + panX) * zoom + 0.5f;
    float v = (p.y - 0.5f + panY) * zoom + 0.5f;
    float aspect = (float)W / (float)H;
    if (aspect > 1.f) u = (u - 0.5f) / aspect + 0.5f;
    else              v = (v - 0.5f) * aspect + 0.5f;
    if (u < 0.f || u >= 1.f || v < 0.f || v >= 1.f) return;

    int x = (int)(u * W);
    int y = (int)((1.f - v) * H);                // GL 텍스처는 아래에서 위로 쌓인다
    if (x < 0 || x >= W || y < 0 || y >= H) return;

    // 색 기준: 0 밀도 / 1 온도 / 2 속력.
    // 어느 쪽이든 색은 사용자가 고른 컬러맵(cmapKind: 0 천체 · 1 흑백 · 2 열화상)에서 뽑는다.
    // 전에는 컬러맵을 아예 안 받아서, 보드에서 흑백으로 바꿔도 점 렌더는 그대로였다
    // (round-06 리뷰 P2 #26).
    float t = 0.5f;
    if (colorBy == 1)      t = fminf(temp[i] * 0.5f, 1.f);
    else if (colorBy == 2) t = fminf(sqrtf(vel[i].x * vel[i].x + vel[i].y * vel[i].y) * 0.25f, 1.f);

    float3 c;
    if (colorBy == 0) {
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
                             float blend) {
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
        const float s = (lum > 1e-6f)
                      ? __powf(fminf(__logf(1.f + lum * bright) * 0.42f, 1.f), invGamma) / lum
                      : 0.f;
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
}

void RenderField::ensureSize(int w, int h) {
    if (w == texW_ && h == texH_ && devPixels_) return;
    texW_ = w; texH_ = h;
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
    const int outW = viewW, outH = viewH;
    if (app.ui.halfResWhenBusy && app.running && app.frameMs > 20.0f) {
        viewW = (viewW + 1) / 2;
        viewH = (viewH + 1) / 2;
    }
    ensureSize(viewW, viewH);

    const ViewSettings& view = app.view;
    const int npix = viewW * viewH;
    const int cmapKind = (view.cmap == ColorMap::Thermal) ? 2
                       : (view.cmap == ColorMap::Gray)    ? 1 : 0;

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
            const Sim::Field f = (view.colorBy == ColorBy::Temperature) ? Sim::Field::Temperature
                               : (view.colorBy == ColorBy::Speed)       ? Sim::Field::Speed
                                                                        : Sim::Field::Density;
            const float* grid = app.sim.fieldDevicePtr(f);

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
            const float bright = (f == Sim::Field::Density)
                               ? view.brightness / fmaxf(meanRho, 1e-6f)
                               : view.brightness * 60.0f;
            if (grid) {
                dim3 b(16, 16), g((viewW + 15) / 16, (viewH + 15) / 16);
                kShade<<<g, b>>>(grid, gridG, (uchar4*)devPixels_, viewW, viewH,
                                 bright, 1.0f / view.gamma, cmapKind,
                                 app.zoom, app.panX, app.panY);
                drew = true;
            }
        }

        if (wantPoints) {
            // 파티클 점 — 겹칠수록 밝아지도록 누적한 뒤 한 번에 색으로 바꾼다.
            const int n = app.sim.activeCount();
            kClearAccum<<<(npix + 255) / 256, 256>>>((float3*)devAccum_, npix);
            if (n > 0) {
                kSplatPoints<<<(n + 255) / 256, 256>>>(
                    (const float2*)app.sim.particlePosDevicePtr(),
                    (const float2*)app.sim.particleVelDevicePtr(),
                    app.sim.particleTempDevicePtr(), n,
                    (float3*)devAccum_, viewW, viewH, (int)view.colorBy, cmapKind,
                    app.zoom, app.panX, app.panY, app.ui.pointSizePx);
            }
            // 섞이는 동안 밝기와 색이 이어지게 맞춘다.
            //
            // 격자 쪽은 평균 밀도로 나눠 「평균의 몇 배인가」로 그리고 색 배열을 거친다.
            // 저절로 넘어온 알갱이 쪽에도 같은 배수와 같은 색 배열을 써야 섞이는 구간에서
            // 두 그림이 같은 색조로 겹친다. 사용자가 직접 점 모드를 고른 경우는 건드리지 않는다.
            const bool autoPoints = (view.mode != RenderMode::Points);
            const float pointBright = autoPoints ? view.brightness / fmaxf(meanRho, 1e-6f)
                                                 : view.brightness;
            // wantField 가 그리지 못했으면 섞을 바탕이 없다 — 그때는 알갱이로 덮어쓴다.
            const float blend = (wantField && drew) ? pointMix : 1.0f;
            kAccumToRGBA<<<(npix + 255) / 256, 256>>>((const float3*)devAccum_,
                                                      (uchar4*)devPixels_, npix,
                                                      pointBright, 1.0f / view.gamma,
                                                      autoPoints ? 1 : 0, cmapKind, blend);
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
    if (hostPixels_) {
        if (texAllocW_ != viewW || texAllocH_ != viewH) {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, viewW, viewH, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, hostPixels_);
            texAllocW_ = viewW; texAllocH_ = viewH;
        } else {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, viewW, viewH,
                            GL_RGBA, GL_UNSIGNED_BYTE, hostPixels_);
        }
    }

    glMatrixMode(GL_PROJECTION); glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);  glLoadIdentity();
    glColor4f(1.f, 1.f, 1.f, 1.f);
    glBegin(GL_QUADS);
        glTexCoord2f(0.f, 0.f); glVertex2f(-1.f, -1.f);
        glTexCoord2f(1.f, 0.f); glVertex2f( 1.f, -1.f);
        glTexCoord2f(1.f, 1.f); glVertex2f( 1.f,  1.f);
        glTexCoord2f(0.f, 1.f); glVertex2f(-1.f,  1.f);
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
