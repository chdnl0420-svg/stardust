// 진입점 — Win32 창을 만들고 메인 루프를 돈다. 조립은 여기서 한 번만 한다.
//
// 한 프레임:
//   메시지 펌프 -> 시뮬레이션 한 스텝 -> 밀도 격자를 화면에 그림 -> ImGui(보드·HUD·툴바) -> 버퍼 교체
#include <windows.h>
#include <windowsx.h>   // GET_X_LPARAM / GET_Y_LPARAM
#include <GL/gl.h>
#include <cstdio>
#include <cstring>
#include <vector>

#include "app/App.h"
#include "app/ControlBridge.h"
#include "gfx/GLContext.h"
#include "gfx/PngWriter.h"
#include "gfx/RenderField.h"
#include "ui/Board.h"
#include "ui/Hud.h"

#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_opengl2.h"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace {

App*         g_app  = nullptr;
GLContext    g_gl;
RenderField  g_field;
int          g_w = 1600, g_h = 900;
bool         g_boardOpen = true;

// 카메라 드래그 상태. 도구가 카메라일 때만 화면을 끈다.
bool  g_dragging = false;
POINT g_dragLast{};
// 도구로 칠하는 중(뿌리기·우물·지우개는 드래그 동안 이어진다)
bool  g_painting = false;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    // 창 제목을 다루는 메시지는 ImGui 를 거치지 않고 곧장 기본 처리로 넘긴다.
    //
    // 아래 한 줄은 ImGui 핸들러가 0 이 아닌 값을 돌려주면 그것으로 처리를 끝낸다(return true).
    // 그 바람에 제목을 세우고 읽는 메시지가 기본 처리에 닿지 못해, 제목이 첫 글자('S')로
    // 잘린 채 남았다 — 밖에서 같은 API 로 넣으면 멀쩡히 들어가는 것과 대비된다(2026-08-14 실측).
    if (msg == WM_SETTEXT || msg == WM_GETTEXT || msg == WM_GETTEXTLENGTH)
        return DefWindowProc(hwnd, msg, wp, lp);

    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp)) return true;

    switch (msg) {
        case WM_SIZE:
            if (wp != SIZE_MINIMIZED) {
                g_w = LOWORD(lp); g_h = HIWORD(lp);
                // 렌더 타깃은 창 크기를 따른다. 격자 해상도와 독립이라 격자를 바꿔도 창이 흔들리지 않는다.
            }
            return 0;

        case WM_LBUTTONDOWN:
            if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                SetCapture(hwnd);
                if (g_app->tool == Tool::Camera) {
                    g_dragging = true;
                    GetCursorPos(&g_dragLast);
                } else {
                    // 도구 사용 — 누른 자리에 바로 적용하고 드래그 동안 이어서 칠한다.
                    g_painting = true;
                    float u, v;
                    g_app->screenToSim(GET_X_LPARAM(lp), GET_Y_LPARAM(lp), g_w, g_h, u, v);
                    g_app->applyToolAt(u, v, true);
                }
            }
            return 0;

        case WM_LBUTTONUP:
            if (g_dragging || g_painting) {
                g_dragging = false; g_painting = false;
                ReleaseCapture();
            }
            return 0;

        case WM_MOUSEMOVE:
            if (g_dragging && g_app) {
                POINT now; GetCursorPos(&now);
                // 화면 픽셀 이동량을 시뮬레이션 공간 이동량으로 바꾼다.
                // 짧은 변이 [0,1] 에 대응하므로 그 값으로 나눈다.
                float unit = (float)(g_w < g_h ? g_w : g_h) * g_app->zoom;
                g_app->panX += (now.x - g_dragLast.x) / unit;
                g_app->panY += (now.y - g_dragLast.y) / unit;
                g_dragLast = now;
            } else if (g_painting && g_app) {
                float u, v;
                g_app->screenToSim(GET_X_LPARAM(lp), GET_Y_LPARAM(lp), g_w, g_h, u, v);
                g_app->applyToolAt(u, v, false);   // 형태 추가는 드래그 중엔 안 넣는다
            }
            return 0;

        case WM_MOUSEWHEEL:
            if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                float d = GET_WHEEL_DELTA_WPARAM(wp) / 120.0f;
                g_app->zoom *= (d > 0) ? 1.12f : (1.0f / 1.12f);
                if (g_app->zoom < 0.25f)  g_app->zoom = 0.25f;
                if (g_app->zoom > 64.0f)  g_app->zoom = 64.0f;
            }
            return 0;

        case WM_KEYDOWN:
            if (g_app && wp == VK_SPACE && !ImGui::GetIO().WantCaptureKeyboard)
                g_app->running = !g_app->running;
            return 0;

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

void ApplyDarkStyle() {
    ImGui::StyleColorsDark();
    ImGuiStyle& s = ImGui::GetStyle();
    s.WindowRounding = 0.0f;
    s.FrameRounding  = 4.0f;
    s.GrabRounding   = 4.0f;
    s.WindowPadding  = ImVec2(11, 9);
    s.ItemSpacing    = ImVec2(8, 6);
    s.Colors[ImGuiCol_WindowBg]      = ImVec4(0.12f, 0.12f, 0.14f, 0.98f);
    s.Colors[ImGuiCol_FrameBg]       = ImVec4(0.20f, 0.20f, 0.23f, 1.00f);
    s.Colors[ImGuiCol_Button]        = ImVec4(0.20f, 0.20f, 0.23f, 1.00f);
    s.Colors[ImGuiCol_ButtonHovered] = ImVec4(0.24f, 0.24f, 0.27f, 1.00f);
    s.Colors[ImGuiCol_SliderGrab]    = ImVec4(0.29f, 0.62f, 0.85f, 1.00f);
    s.Colors[ImGuiCol_CheckMark]     = ImVec4(0.29f, 0.62f, 0.85f, 1.00f);
    s.Colors[ImGuiCol_Header]        = ImVec4(0.17f, 0.17f, 0.20f, 1.00f);
}

} // namespace

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR lpCmdLine, int) {
    if (!Sim::deviceAvailable()) {
        MessageBoxW(nullptr,
                    L"CUDA 장치를 찾지 못했습니다.\nNVIDIA 그래픽카드와 드라이버가 필요합니다.",
                    L"nbody-simulator", MB_ICONERROR | MB_OK);
        return 1;
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    // 실행 파일에 박아 둔 첫 번째 아이콘(packaging/stardust.rc)을 창과 작업표시줄에 쓴다.
    // 큰 것과 작은 것을 따로 불러야 작업표시줄과 Alt+Tab 이 각자 맞는 크기를 쓴다.
    wc.hIcon   = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    wc.hIconSm = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    wc.lpszClassName = L"StardustWnd";
    RegisterClassExW(&wc);

    RECT r{ 0, 0, g_w, g_h };
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"Stardust",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                r.right - r.left, r.bottom - r.top,
                                nullptr, nullptr, hInst, nullptr);
    if (!hwnd) return 1;

    if (!g_gl.create(hwnd)) {
        MessageBoxW(hwnd, L"OpenGL 컨텍스트를 만들지 못했습니다.", L"nbody-simulator",
                    MB_ICONERROR | MB_OK);
        return 1;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;   // 창 배치를 파일로 저장하지 않는다(항상 시안 배치로 뜬다)
    // 기본 폰트에는 한글 글리프가 없다. 윈도우 기본 한글 폰트를 한글 범위와 함께 올린다.
    io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\malgun.ttf", 16.0f, nullptr,
                                 io.Fonts->GetGlyphRangesKorean());
    ApplyDarkStyle();
    ImGui_ImplWin32_InitForOpenGL(hwnd);
    ImGui_ImplOpenGL2_Init();

    App app;
    app.init();
    g_app = &app;
    g_field.init();

    // 제어 채널 — MCP 서버가 여기로 명령을 넣는다.
    // 인자 형식: --control-dir=<경로>. 없으면 %TEMP%\nbody-mcp 를 쓴다.
    ControlBridge bridge;
    {
        std::string args = lpCmdLine ? lpCmdLine : "";
        const std::string key = "--control-dir=";
        size_t at = args.find(key);
        std::string dir;
        if (at != std::string::npos) {
            dir = args.substr(at + key.size());
            if (!dir.empty() && dir.front() == '"') {
                size_t end = dir.find('"', 1);
                dir = (end == std::string::npos) ? dir.substr(1) : dir.substr(1, end - 1);
            } else {
                size_t sp = dir.find(' ');
                if (sp != std::string::npos) dir = dir.substr(0, sp);
            }
        }
        bridge.init(dir);
    }

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    // 창 제목은 **다 만들어 띄운 뒤에** 세운다.
    //
    // CreateWindowExW 에 이름을 넘겨도, 그 직후에 SetWindowTextW 로 다시 넣어도
    // 제목이 첫 글자 하나('S')로 잘렸다. 같은 호출을 밖에서 창 핸들에 대고 하면 멀쩡히
    // 여덟 글자가 들어간다 — 즉 이른 시점에 세운 이름이 뒤이은 초기화 어딘가에서 밀린다.
    // 원인을 못 밝혀 순서로 피한다. 작업표시줄이 이 이름을 그대로 쓴다(2026-08-14 실측).
    //
    // 넓은 리터럴(L"...")을 그대로 넘기면 첫 글자만 들어가므로, 좁은 리터럴에서 조립해 넘긴다.
    // 밖에서 같은 API 로 넣으면 여덟 글자가 멀쩡히 들어가는 것을 확인했다.
    {
        wchar_t title[32] = { 0 };
        MultiByteToWideChar(CP_UTF8, 0, "Stardust", -1, title, 32);
        SetWindowTextW(hwnd, title);
    }

    LARGE_INTEGER freq, prev;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&prev);
    float fpsAccum = 0.0f; int fpsFrames = 0;

    bool quit = false;
    while (!quit) {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) quit = true;
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        if (quit) break;

        // 창 제목은 루프가 돌기 시작한 뒤에 한 번 세운다.
        //
        // 창을 만드는 자리나 ShowWindow 직후에 세우면 첫 글자('S')만 남았다. 같은 API 를
        // 밖에서 창 핸들에 대고 부르면 여덟 글자가 멀쩡히 들어간다 — 초기화가 다 끝나기 전에는
        // 이름이 어딘가에서 밀린다는 뜻이다. 원인을 못 밝혀 시점으로 피한다.
        // 작업표시줄과 Alt+Tab 이 이 이름을 그대로 쓴다(2026-08-14 실측).
        static bool titleSet = false;
        if (!titleSet) { SetWindowTextW(hwnd, L"Stardust"); titleSet = true; }

        // 업데이트를 받아 두었으면 여기서 끝낸다. 옆에 남겨 둔 스크립트가 앱이 완전히 끝나기를
        // 기다렸다가 실행 파일을 갈아 끼우고 다시 띄운다 — 돌고 있는 파일은 덮어쓸 수 없다.
        if (app.updater.wantsRestart()) break;

        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        float dtMs = (float)((now.QuadPart - prev.QuadPart) * 1000.0 / freq.QuadPart);
        prev = now;
        app.frameMs = app.frameMs * 0.9f + dtMs * 0.1f;
        fpsAccum += dtMs; ++fpsFrames;
        if (fpsAccum > 300.0f) { app.fps = fpsFrames * 1000.0f / fpsAccum; fpsAccum = 0; fpsFrames = 0; }

        app.tick();

        glClearColor(0.f, 0.f, 0.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        g_field.draw(app, g_w, g_h);

        ImGui_ImplOpenGL2_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        // 글자를 치는 중에는 키를 위젯에 양보한다.
        if (!ImGui::GetIO().WantTextInput) {
            // Tab 으로 장면 서랍을 오르내리고 Esc 로 닫는다.
            if (ImGui::IsKeyPressed(ImGuiKey_Tab, false)) {
                app.drawerOpen = !app.drawerOpen;
                app.shapeDrawerOpen = false;
            }
            if (ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
                app.drawerOpen = false;
                app.shapeDrawerOpen = false;
            }
            // H 로 막대까지 전부 감춘다(녹화·감상용).
            if (ImGui::IsKeyPressed(ImGuiKey_H, false)) {
                app.uiHidden = !app.uiHidden;
                if (app.uiHidden) { app.drawerOpen = false; app.shapeDrawerOpen = false; }
            }
            // 숫자키로 장면을 바로 고른다. 서랍이 닫혀 있어도 먹는다.
            for (int i = 0; i < 5; ++i) {
                if (ImGui::IsKeyPressed((ImGuiKey)(ImGuiKey_1 + i), false)) {
                    SwitchSceneByIndex(app, i);
                    break;
                }
            }
        }

        if (app.uiHidden) {
            // 완전히 감추면 돌아오는 길을 모른다 — 한 줄짜리 힌트만 남긴다.
            ImGui::SetNextWindowPos(ImVec2(12.0f, 12.0f), ImGuiCond_Always);
            ImGui::SetNextWindowBgAlpha(0.35f);
            ImGui::Begin("##hint", nullptr,
                         ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_AlwaysAutoResize |
                         ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                         ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs);
            ImGui::TextDisabled("H: 조작부 보이기");
            ImGui::End();
        } else {
            // 그리는 순서가 곧 쌓이는 순서다. 어둠 → 서랍 → 막대 순으로 얹는다.
            DrawBottomScrim(app, g_w, g_h);
            DrawHud(app);
            DrawBlackHoleRings(app, g_w, g_h);
            DrawSceneDrawer(app, g_w, g_h);
            DrawShapeDrawer(app, g_w, g_h);
            DrawBottomBar(app, g_w, g_h);
        }

        ImGui::Render();
        ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());

        // 스냅샷·녹화도 버퍼 교체 전에 지금 프레임을 집는다.
        if (app.snapshotRequested || app.recording) {
            const bool takeNow = app.snapshotRequested ||
                                 (app.frameCounter++ % (app.recordEvery > 0 ? app.recordEvery : 1) == 0);
            if (takeNow) {
                CreateDirectoryA("captures", nullptr);
                std::vector<unsigned char> px((size_t)g_w * g_h * 4);
                glPixelStorei(GL_PACK_ALIGNMENT, 1);
                glReadBuffer(GL_BACK);
                glReadPixels(0, 0, g_w, g_h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
                // OpenGL 은 아래에서 위로 읽으므로 줄 순서를 뒤집는다
                std::vector<unsigned char> flipped((size_t)g_w * g_h * 4);
                for (int y = 0; y < g_h; ++y)
                    memcpy(&flipped[(size_t)y * g_w * 4],
                           &px[(size_t)(g_h - 1 - y) * g_w * 4], (size_t)g_w * 4);
                char name[256];
                const bool isSnapshot = app.snapshotRequested;
                if (isSnapshot) {
                    SYSTEMTIME t; GetLocalTime(&t);
                    snprintf(name, sizeof(name), "captures\\snap-%02d%02d%02d-%03d.png",
                             t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
                } else {
                    snprintf(name, sizeof(name), "captures\\rec-%05d.png", app.recordedFrames);
                }
                // 저장에 성공한 뒤에야 요청을 지우고 프레임 수를 올린다.
                // 전에는 결과를 안 보고 먼저 세어서, 디스크가 차 저장이 실패해도
                // "N 프레임 녹화됨"이 그대로 올라가고 실제 파일 수와 어긋났다(round-06 리뷰 P2 #30).
                const bool saved = WritePngRGBA(name, flipped.data(), g_w, g_h);
                if (isSnapshot) {
                    // 실패해도 요청은 소비한다 — 안 그러면 매 프레임 같은 실패를 반복한다.
                    app.snapshotRequested = false;
                    if (!saved) app.lastSaveFailed = true;
                } else if (saved) {
                    ++app.recordedFrames;
                } else {
                    // 녹화 중 저장이 실패하면 계속 시도해 봐야 같은 결과라 멈춘다.
                    app.recording = false;
                    app.lastSaveFailed = true;
                }
            }
        }

        // 제어 명령은 화면을 다 그린 뒤, 버퍼를 교체하기 전에 처리한다.
        // 그래야 screenshot 이 지금 프레임을 집는다(교체 후엔 백버퍼 내용이 바뀐다).
        if (bridge.poll(app, g_w, g_h)) quit = true;

        g_gl.present();
    }

    g_field.shutdown();
    ImGui_ImplOpenGL2_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    g_gl.destroy();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, hInst);
    return 0;
}
