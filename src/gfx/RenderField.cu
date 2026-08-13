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
        int gx = min(max((int)(u * G), 0), G - 1);
        int gy = min(max((int)(v * G), 0), G - 1);
        float d = rho[gy * G + gx];
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
                             int colorBy, int cmapKind, float zoom, float panX, float panY) {
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

    float3* px = &accum[y * W + x];
    atomicAdd(&px->x, c.x);
    atomicAdd(&px->y, c.y);
    atomicAdd(&px->z, c.z);
}

__global__ void kClearAccum(float3* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = make_float3(0.f, 0.f, 0.f);
}

// 누적값을 화면 색으로 바꾼다. 겹친 수가 넓은 범위를 가지므로 로그로 눌러야 다 보인다.
__global__ void kAccumToRGBA(const float3* accum, uchar4* out, int n,
                             float bright, float invGamma) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float3 a = accum[i];
    float lum = (a.x + a.y + a.z) * 0.3333f;
    float s = (lum > 1e-6f) ? __powf(fminf(__logf(1.f + lum * bright) * 0.42f, 1.f), invGamma) / lum
                            : 0.f;
    float r = fminf(a.x * s, 1.f), g = fminf(a.y * s, 1.f), b = fminf(a.z * s, 1.f);
    out[i] = make_uchar4((unsigned char)(r * 255.f), (unsigned char)(g * 255.f),
                         (unsigned char)(b * 255.f), 255);
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
    ensureSize(viewW, viewH);

    const ViewSettings& view = app.view;
    const int npix = viewW * viewH;
    const int cmapKind = (view.cmap == ColorMap::Thermal) ? 2
                       : (view.cmap == ColorMap::Gray)    ? 1 : 0;

    // 점 렌더는 누적 버퍼가 따로 필요하다. 화면 버퍼만 있고 누적 버퍼가 없으면 밀도 필드로 내려간다.
    if (!devPixels_) { if (hostPixels_) memset(hostPixels_, 0, devBytes_); }
    else if (view.mode == RenderMode::Points && devAccum_) {
        // 파티클 점 — 겹칠수록 밝아지도록 누적한 뒤 한 번에 색으로 바꾼다.
        const int n = app.sim.activeCount();
        kClearAccum<<<(npix + 255) / 256, 256>>>((float3*)devAccum_, npix);
        if (n > 0) {
            kSplatPoints<<<(n + 255) / 256, 256>>>(
                (const float2*)app.sim.particlePosDevicePtr(),
                (const float2*)app.sim.particleVelDevicePtr(),
                app.sim.particleTempDevicePtr(), n,
                (float3*)devAccum_, viewW, viewH, (int)view.colorBy, cmapKind,
                app.zoom, app.panX, app.panY);
        }
        kAccumToRGBA<<<(npix + 255) / 256, 256>>>((const float3*)devAccum_,
                                                  (uchar4*)devPixels_, npix,
                                                  view.brightness, 1.0f / view.gamma);
        // 복사가 실패하면 hostPixels_ 는 이전 프레임 그대로다 — 그걸 새 화면인 양 올리면
        // 사용자는 시뮬레이션이 도는 줄 안다. 실패하면 검은 화면으로 두어 이상을 드러낸다
        // (round-08 리뷰 A11).
        if (cudaMemcpy(hostPixels_, devPixels_, devBytes_, cudaMemcpyDeviceToHost) != cudaSuccess) {
            if (hostPixels_) memset(hostPixels_, 0, devBytes_);
        }
    } else {
        // 밀도 필드 — 색 기준에 맞는 격자를 받아 화면으로 샘플링한다.
        const Sim::Field f = (view.colorBy == ColorBy::Temperature) ? Sim::Field::Temperature
                           : (view.colorBy == ColorBy::Speed)       ? Sim::Field::Speed
                                                                    : Sim::Field::Density;
        const float* grid = app.sim.fieldDevicePtr(f);
        // 온도·속도는 값 범위가 밀도와 달라 로그 압축이 과하다. 밝기를 그 자리에서 보정한다.
        const float bright = (f == Sim::Field::Density) ? view.brightness
                                                        : view.brightness * 60.0f;
        if (grid) {
            dim3 b(16, 16), g((viewW + 15) / 16, (viewH + 15) / 16);
            kShade<<<g, b>>>(grid, app.sim.gridSize(), (uchar4*)devPixels_, viewW, viewH,
                             bright, 1.0f / view.gamma, cmapKind,
                             app.zoom, app.panX, app.panY);
            if (cudaMemcpy(hostPixels_, devPixels_, devBytes_, cudaMemcpyDeviceToHost) != cudaSuccess) {
                if (hostPixels_) memset(hostPixels_, 0, devBytes_);
            }
        } else if (hostPixels_) {
            memset(hostPixels_, 0, devBytes_);
        }
    }

    glViewport(0, 0, viewW, viewH);
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
}
