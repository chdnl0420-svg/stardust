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
    if (hostPixels_) { free(hostPixels_); hostPixels_ = nullptr; }
    if (devPixels_)  { cudaFree(devPixels_); devPixels_ = nullptr; devBytes_ = 0; }
}

void RenderField::ensureSize(int w, int h) {
    if (w == texW_ && h == texH_ && devPixels_) return;
    texW_ = w; texH_ = h;
    size_t need = (size_t)w * h * 4;
    if (hostPixels_) free(hostPixels_);
    hostPixels_ = (unsigned char*)malloc(need);
    if (devPixels_) cudaFree(devPixels_);
    cudaMalloc(&devPixels_, need);
    devBytes_ = need;
}

void RenderField::draw(const float* densityDevice, int gridSize,
                       int viewW, int viewH, const ViewSettings& view,
                       float zoom, float panX, float panY) {
    if (viewW <= 0 || viewH <= 0) return;
    ensureSize(viewW, viewH);

    if (densityDevice && devPixels_) {
        dim3 b(16, 16), g((viewW + 15) / 16, (viewH + 15) / 16);
        int kind = (view.cmap == ColorMap::Thermal) ? 2
                 : (view.cmap == ColorMap::Gray)    ? 1 : 0;
        kShade<<<g, b>>>(densityDevice, gridSize, (uchar4*)devPixels_, viewW, viewH,
                         view.brightness, 1.0f / view.gamma, kind, zoom, panX, panY);
        cudaMemcpy(hostPixels_, devPixels_, devBytes_, cudaMemcpyDeviceToHost);
    } else if (hostPixels_) {
        memset(hostPixels_, 0, devBytes_);
    }

    glViewport(0, 0, viewW, viewH);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_LIGHTING);
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, texId_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, viewW, viewH, 0, GL_RGBA, GL_UNSIGNED_BYTE, hostPixels_);

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
