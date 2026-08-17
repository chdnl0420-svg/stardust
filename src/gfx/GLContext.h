// Win32 창에 OpenGL 컨텍스트를 붙인다 — Adapter 층.
// 계산하지 않는다. 창 핸들과 GL 컨텍스트의 수명만 관리한다.
#pragma once

#include <windows.h>

struct GLContext {
    HWND  hwnd = nullptr;
    HDC   hdc  = nullptr;
    HGLRC hrc  = nullptr;

    bool create(HWND wnd);
    void destroy();
    void present() const;   // 더블 버퍼 교체
};
