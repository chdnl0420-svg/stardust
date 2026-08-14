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
        return DefWindowProcW(hwnd, msg, wp, lp);

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
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// 시안이 정한 옷을 ImGui 전체에 입힌다.
//
// 하단 막대는 직접 그리므로 시안대로였지만, 거기서 열리는 팝업과 설정 보드는
// ImGui 기본값이라 파란 슬라이더에 회색 버튼으로 따로 놀았다. 팔레트를 한 벌로 맞춘다 —
// 값은 ui/Board.cpp 의 색 상수와 같은 것이다(흑연 바탕 + 주황 하나).
void ApplyDarkStyle() {
    ImGui::StyleColorsDark();
    ImGuiStyle& s = ImGui::GetStyle();

    // 모서리는 알약(높이의 절반)만큼은 아니지만 확실히 둥글게 —
    // 각진 창이 하나라도 섞이면 막대만 따로 만든 티가 난다.
    s.WindowRounding    = 14.0f;
    s.PopupRounding     = 14.0f;
    s.ChildRounding     = 10.0f;
    s.FrameRounding     = 8.0f;
    s.GrabRounding      = 8.0f;
    s.ScrollbarRounding = 8.0f;
    s.TabRounding       = 8.0f;

    s.WindowBorderSize = 1.0f;
    s.FrameBorderSize  = 0.0f;
    s.PopupBorderSize  = 1.0f;
    s.WindowPadding    = ImVec2(16, 14);
    s.FramePadding     = ImVec2(11, 6);
    s.ItemSpacing      = ImVec2(10, 9);
    s.ItemInnerSpacing = ImVec2(8, 6);
    s.GrabMinSize      = 14.0f;
    s.ScrollbarSize    = 12.0f;

    ImVec4* c = s.Colors;
    const ImVec4 accent(1.000f, 0.690f, 0.400f, 1.00f);   // #ffb066
    const ImVec4 accentHi(1.000f, 0.769f, 0.541f, 1.00f); // #ffc48a

    // 바탕: 막대 뒤에 까는 스크림과 같은 흑연. 불투명에 가깝게 둬야 글자가 우주에 묻히지 않는다.
    c[ImGuiCol_WindowBg]        = ImVec4(0.043f, 0.043f, 0.055f, 0.97f);
    c[ImGuiCol_PopupBg]         = ImVec4(0.043f, 0.043f, 0.055f, 0.98f);
    c[ImGuiCol_ChildBg]         = ImVec4(1.000f, 1.000f, 1.000f, 0.03f);
    c[ImGuiCol_Border]          = ImVec4(1.000f, 1.000f, 1.000f, 0.10f);
    c[ImGuiCol_BorderShadow]    = ImVec4(0.000f, 0.000f, 0.000f, 0.00f);

    c[ImGuiCol_Text]            = ImVec4(1.000f, 1.000f, 1.000f, 1.00f);
    c[ImGuiCol_TextDisabled]    = ImVec4(0.420f, 0.404f, 0.475f, 1.00f);   // #6b6779

    // 입력 칸·버튼은 「유리」다 — 바탕색을 칠하지 않고 흰색을 옅게 얹는다.
    // 슬라이더 트랙이 여기 해당한다. 너무 옅으면 어디까지가 움직일 수 있는 길인지 안 보인다.
    c[ImGuiCol_FrameBg]         = ImVec4(1.000f, 1.000f, 1.000f, 0.11f);
    c[ImGuiCol_FrameBgHovered]  = ImVec4(1.000f, 1.000f, 1.000f, 0.16f);
    c[ImGuiCol_FrameBgActive]   = ImVec4(1.000f, 1.000f, 1.000f, 0.20f);
    c[ImGuiCol_Button]          = ImVec4(1.000f, 1.000f, 1.000f, 0.07f);
    c[ImGuiCol_ButtonHovered]   = ImVec4(1.000f, 1.000f, 1.000f, 0.13f);
    c[ImGuiCol_ButtonActive]    = ImVec4(1.000f, 0.690f, 0.400f, 0.22f);

    // 고른 것·움직이는 것에만 주황을 쓴다. 강조가 둘 이상이면 어느 것도 강조가 아니다.
    c[ImGuiCol_SliderGrab]       = accent;
    c[ImGuiCol_SliderGrabActive] = accentHi;
    c[ImGuiCol_CheckMark]        = accent;
    c[ImGuiCol_Header]           = ImVec4(1.000f, 0.690f, 0.400f, 0.16f);
    c[ImGuiCol_HeaderHovered]    = ImVec4(1.000f, 0.690f, 0.400f, 0.24f);
    c[ImGuiCol_HeaderActive]     = ImVec4(1.000f, 0.690f, 0.400f, 0.32f);
    c[ImGuiCol_ResizeGrip]       = ImVec4(1.000f, 1.000f, 1.000f, 0.08f);
    c[ImGuiCol_ResizeGripHovered]= ImVec4(1.000f, 0.690f, 0.400f, 0.30f);
    c[ImGuiCol_ResizeGripActive] = accent;

    c[ImGuiCol_Separator]        = ImVec4(1.000f, 1.000f, 1.000f, 0.12f);
    c[ImGuiCol_SeparatorHovered] = ImVec4(1.000f, 0.690f, 0.400f, 0.40f);
    c[ImGuiCol_SeparatorActive]  = accent;

    c[ImGuiCol_TitleBg]          = ImVec4(0.043f, 0.043f, 0.055f, 1.00f);
    c[ImGuiCol_TitleBgActive]    = ImVec4(0.075f, 0.071f, 0.090f, 1.00f);
    c[ImGuiCol_TitleBgCollapsed] = ImVec4(0.043f, 0.043f, 0.055f, 0.80f);

    c[ImGuiCol_ScrollbarBg]           = ImVec4(0.000f, 0.000f, 0.000f, 0.00f);
    c[ImGuiCol_ScrollbarGrab]         = ImVec4(1.000f, 1.000f, 1.000f, 0.12f);
    c[ImGuiCol_ScrollbarGrabHovered]  = ImVec4(1.000f, 1.000f, 1.000f, 0.20f);
    c[ImGuiCol_ScrollbarGrabActive]   = ImVec4(1.000f, 0.690f, 0.400f, 0.55f);

    c[ImGuiCol_PlotHistogram]        = accent;
    c[ImGuiCol_PlotHistogramHovered] = accentHi;
    c[ImGuiCol_PlotLines]            = ImVec4(0.714f, 0.698f, 0.769f, 1.00f);
    c[ImGuiCol_PlotLinesHovered]     = accent;

    // 안내문은 막대의 유리 알약과 같은 옷을 입는다.
    c[ImGuiCol_TableHeaderBg]        = ImVec4(1.000f, 1.000f, 1.000f, 0.06f);
    c[ImGuiCol_TableBorderStrong]    = ImVec4(1.000f, 1.000f, 1.000f, 0.14f);
    c[ImGuiCol_TableBorderLight]     = ImVec4(1.000f, 1.000f, 1.000f, 0.08f);
    c[ImGuiCol_NavCursor]            = accent;
    c[ImGuiCol_DragDropTarget]       = accent;
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
    // 창 이름은 여기서 한 번만 세운다. 오래 「S」 한 글자로 잘려 나오던 원인은
    // 아래 WndProc 이 DefWindowProc(=UNICODE 미정의라 ANSI 판)을 부른 데 있었다 —
    // 제목을 저장하는 기본 처리가 UTF-16 문자열을 ANSI 로 읽어 둘째 바이트 0x00 에서 끊었다.
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
    //
    // ImGui 가 주는 한글 범위에는 「일반 문장부호」 구간이 빠져 있다. 그 구간이 없으면
    // 우리가 안내문에 쓰는 긴 줄표(—)와 말줄임표(…)가 통째로 네모로 나온다.
    static const ImWchar kRanges[] = {
        0x0020, 0x00FF,   // 기본 라틴 + 라틴 보충 (·, × 도 여기 있다)
        0x2000, 0x206F,   // 일반 문장부호 — 여기가 ImGui 기본 범위에서 빠진 자리다
        0x3131, 0x3163,   // 자모
        0xAC00, 0xD7A3,   // 완성형 한글
        0xFFFD, 0xFFFD,   // 없는 글자 자리표
        0,
    };
    io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\malgun.ttf", 16.0f, nullptr, kRanges);
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
