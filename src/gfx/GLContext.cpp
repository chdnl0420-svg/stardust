#include "gfx/GLContext.h"

#include <GL/gl.h>

#pragma comment(lib, "opengl32.lib")

bool GLContext::create(HWND wnd) {
    hwnd = wnd;
    hdc = GetDC(hwnd);
    if (!hdc) return false;

    // 픽셀 포맷 = 이 창에 어떤 종류의 그림 버퍼를 붙일지 고르는 절차.
    // 더블 버퍼(그리는 면과 보이는 면을 따로 두어 깜빡임을 막는다)를 요구한다.
    PIXELFORMATDESCRIPTOR pfd{};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;

    int fmt = ChoosePixelFormat(hdc, &pfd);
    if (!fmt || !SetPixelFormat(hdc, fmt, &pfd)) {
        ReleaseDC(hwnd, hdc); hdc = nullptr;
        return false;
    }
    hrc = wglCreateContext(hdc);
    if (!hrc) { ReleaseDC(hwnd, hdc); hdc = nullptr; return false; }
    if (!wglMakeCurrent(hdc, hrc)) { destroy(); return false; }

    // 화면 갱신 주기에 맞춰 그린다(수직 동기).
    //
    // 켜지 않으면 초당 400장씩 그리는데, 모니터는 60장만 보여주므로 나머지는 버려진다.
    // 그 헛일이 그래픽카드와 드라이버에 그대로 부하로 쌓이고, 화면 한 장마다 도는
    // 메모리 작업도 그만큼 늘어난다. 60장으로 묶으면 같은 그림을 보면서 부하가 7분의 1 이 된다.
    // (2026-08-13 두 번의 드라이버 크래시 이후 넣었다.)
    typedef BOOL (WINAPI *SwapIntervalFn)(int);
    SwapIntervalFn setSwapInterval =
        (SwapIntervalFn)wglGetProcAddress("wglSwapIntervalEXT");
    if (setSwapInterval) setSwapInterval(1);

    return true;
}

void GLContext::destroy() {
    if (hrc) { wglMakeCurrent(nullptr, nullptr); wglDeleteContext(hrc); hrc = nullptr; }
    if (hdc) { ReleaseDC(hwnd, hdc); hdc = nullptr; }
}

void GLContext::present() const {
    if (hdc) SwapBuffers(hdc);
}
