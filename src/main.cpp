// 진입점 — Win32 창을 만들고 메인 루프를 돈다. 조립은 여기서 한 번만 한다.
//
// 한 프레임:
//   메시지 펌프 -> 시뮬레이션 한 스텝 -> 밀도 격자를 화면에 그림 -> ImGui(보드·HUD·툴바) -> 버퍼 교체
#include <windows.h>
#include <windowsx.h>   // GET_X_LPARAM / GET_Y_LPARAM
#include <shlobj.h>     // SHBrowseForFolderW — 저장 폴더 고르기
#include <GL/gl.h>
#include <cstdio>
#include <cstring>
#include <vector>

#include "app/App.h"
#include "app/ControlBridge.h"
#include "app/Prefs.h"
#include "gfx/GLContext.h"
#include "gfx/PngWriter.h"
#include "gfx/RenderField.h"
#include "ui/Board.h"
#include "ui/Hud.h"
#include "ui/Meters.h"
#include "ui/Settings.h"

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

// 카메라가 판 밖으로 못 나가게 붙잡는다.
//
// 판은 [0,1] 이고 화면 한가운데가 시뮬 좌표 (0.5 - pan) 에 닿는다(App::screenToSim).
// 배율이 z 일 때 화면이 덮는 폭은 1/z 이므로, 판을 벗어나지 않으려면 가운데가
// [0.5/z, 1 - 0.5/z] 안에 있어야 한다. 그것을 pan 으로 옮기면 아래 식이 된다.
// 배율이 1 이면 판이 화면에 꼭 맞아 움직일 자리가 없으므로 pan 은 0 이다.
void ClampPan(App& app) {
    // 화면이 정사각이 아니면 긴 쪽으로 판 밖이 더 넓게 보인다 — 짧은 변을 [0,1] 에 맞추기
    // 때문이다(App::screenToSim). 그 몫까지 세지 않으면 가로로 끌 때 판의 테두리가 드러난다.
    const float aspect = (g_h > 0) ? (float)g_w / (float)g_h : 1.0f;
    const float spanU = (aspect > 1.0f) ? aspect : 1.0f;          // 화면이 덮는 가로 폭
    const float spanV = (aspect > 1.0f) ? 1.0f : (1.0f / aspect); // 세로 폭
    const float z = (app.zoom > 1e-3f) ? app.zoom : 1e-3f;

    const float mx = 0.5f - spanU * 0.5f / z;
    const float my = 0.5f - spanV * 0.5f / z;
    const float lx = (mx > 0.0f) ? mx : 0.0f;
    const float ly = (my > 0.0f) ? my : 0.0f;
    if (app.panX >  lx) app.panX =  lx;
    if (app.panX < -lx) app.panX = -lx;
    if (app.panY >  ly) app.panY =  ly;
    if (app.panY < -ly) app.panY = -ly;
}

// 판이 화면을 꽉 채우는 가장 작은 배율. 이보다 줄이면 판 밖의 검은 테두리가 보인다.
float MinZoom() {
    const float aspect = (g_h > 0) ? (float)g_w / (float)g_h : 1.0f;
    return (aspect > 1.0f) ? aspect : (1.0f / aspect);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
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
                const float unit = (float)(g_w < g_h ? g_w : g_h) * g_app->zoom;
                const float s = g_app->ui.dragSensitivity;
                g_app->panX += (now.x - g_dragLast.x) * s / unit;
                g_app->panY += (now.y - g_dragLast.y) * s / unit;
                ClampPan(*g_app);
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
                if (g_app->ui.wheelInverted) d = -d;
                // 한 칸에 얼마나 확대할지. 설정의 「휠 확대 속도」가 1.0 일 때 12% 다.
                const float step = 1.0f + 0.15f * g_app->ui.wheelZoomSpeed;
                g_app->zoom *= (d > 0) ? step : (1.0f / step);
                const float mz = MinZoom();     // 판이 화면을 꽉 채우는 선까지만 줄인다
                if (g_app->zoom < mz)     g_app->zoom = mz;
                if (g_app->zoom > 64.0f)  g_app->zoom = 64.0f;
                ClampPan(*g_app);
            }
            return 0;

        // 창이 뒤로 가면 계산을 멈출 수 있게 상태를 적어 둔다(설정의 「창이 뒤에 있으면 멈추기」).
        case WM_ACTIVATE:
            if (g_app) g_app->windowActive = (LOWORD(wp) != WA_INACTIVE);
            return 0;

        case WM_KEYDOWN:
            if (g_app && !ImGui::GetIO().WantCaptureKeyboard) {
                if (wp == VK_SPACE) g_app->running = !g_app->running;
                // S 와 Esc 는 아래 프레임 루프의 ImGui 쪽에서 함께 다룬다 —
                // 설정 창이 떠 있으면 키를 ImGui 가 먼저 잡아 여기까지 오지 않는다.
            }
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

// 저장할 폴더. 설정에서 고르지 않았으면 실행 파일 옆의 captures 를 쓴다.
// 없으면 만든다 — 첫 저장에서 「폴더가 없다」로 실패하면 사용자는 이유를 알 수 없다.
std::string CaptureDir(const App& app) {
    std::string d = app.ui.saveFolder.empty() ? std::string("captures") : app.ui.saveFolder;
    CreateDirectoryA(d.c_str(), nullptr);
    if (!d.empty() && d.back() != '\\' && d.back() != '/') d += '\\';
    return d;
}

// 스냅샷·녹화가 걸려 있으면 지금 화면을 집어 파일로 남긴다.
//
// 버퍼를 교체하기 **전에** 불러야 한다 — 교체하고 나면 백버퍼 내용이 바뀐다.
// 부르는 자리가 두 곳인 것은 「녹화에 UI 넣지 않기」 때문이다. 켜져 있으면 판을 그리기 전에,
// 꺼져 있으면 다 그린 뒤에 집는다.
void CaptureIfAsked(App& app, int w, int h) {
    if (!app.snapshotRequested && !app.recording) return;
    const int every = (app.recordEvery > 0) ? app.recordEvery : 1;
    const bool takeNow = app.snapshotRequested || (app.frameCounter++ % every == 0);
    if (!takeNow) return;

    std::vector<unsigned char> px((size_t)w * h * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadBuffer(GL_BACK);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
    // OpenGL 은 아래에서 위로 읽으므로 줄 순서를 뒤집는다
    std::vector<unsigned char> flipped((size_t)w * h * 4);
    for (int y = 0; y < h; ++y)
        memcpy(&flipped[(size_t)y * w * 4], &px[(size_t)(h - 1 - y) * w * 4], (size_t)w * 4);

    const std::string dir = CaptureDir(app);
    const bool jpg = (app.ui.imageFormat == 1);
    const bool isSnapshot = app.snapshotRequested;
    char name[512];
    if (isSnapshot) {
        SYSTEMTIME t; GetLocalTime(&t);
        snprintf(name, sizeof(name), "%ssnap-%02d%02d%02d-%03d.%s",
                 dir.c_str(), t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, jpg ? "jpg" : "png");
    } else {
        // 녹화는 늘 PNG 다. 이어 붙일 그림을 매 장 다시 압축해 흐리게 만들 이유가 없다.
        snprintf(name, sizeof(name), "%srec-%05d.png", dir.c_str(), app.recordedFrames);
    }

    // 저장에 성공한 뒤에야 요청을 지우고 프레임 수를 올린다.
    // 전에는 결과를 안 보고 먼저 세어서, 디스크가 차 저장이 실패해도
    // "N 프레임 녹화됨"이 그대로 올라가고 실제 파일 수와 어긋났다(round-06 리뷰 P2 #30).
    const bool saved = (isSnapshot && jpg)
                     ? WriteJpgRGBA(name, flipped.data(), w, h, 92)
                     : WritePngRGBA(name, flipped.data(), w, h);
    if (isSnapshot) {
        // 실패해도 요청은 소비한다 — 안 그러면 매 프레임 같은 실패를 반복한다.
        app.snapshotRequested = false;
        if (!saved) app.lastSaveFailed = true;
        // 찍혔다는 것을 눈으로 알기 어려우므로 소리로 알린다(켠 사람만).
        else if (app.ui.shutterSound) MessageBeep(MB_OK);
    } else if (saved) {
        ++app.recordedFrames;
    } else {
        // 녹화 중 저장이 실패하면 계속 시도해 봐야 같은 결과라 멈춘다.
        app.recording = false;
        app.lastSaveFailed = true;
    }
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
    // 지난번에 맞춰 둔 값을 먼저 읽고 그 값으로 판을 연다. 읽은 뒤에 init 을 부르므로
    // 카드가 감당 못 할 값이 들어 있어도 거기서 상한에 걸려 잘린다.
    LoadPrefs(app);
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

        // 새 버전을 찾았으면 **스스로** 받아 갈아 끼운다.
        //
        // 전에는 설정 팝업에 「새 버전이 있습니다」를 띄우고 누르기를 기다렸다. 그러면 그 팝업을
        // 열어 보지 않는 한 영영 옛 버전으로 남는다 — 「올라오면 자동으로」가 되려면 여기서 한다.
        // 시작하고 몇 초 안에 끝나므로 무언가 하던 중에 화면이 사라지는 일은 없다.
        // 받다 실패하면 조용히 물러나고, 설정 팝업의 버튼이 남아 손으로 다시 시도할 수 있다.
        if (!app.updateBusy && app.updateError.empty()) {
            const UpdateInfo up = app.updater.status();
            if (up.checked && up.available) {
                app.updateBusy = true;
                std::string err;
                if (!app.updater.applyUpdate(err)) { app.updateError = err; app.updateBusy = false; }
            }
        }

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

        // 창이 뒤에 있으면 계산을 쉰다(설정에서 끄면 뒤에서도 계속 돈다).
        // 오래 돌려 놓고 다른 일을 하려면 꺼야 하고, 배터리를 아끼려면 켜야 한다.
        if (app.ui.pauseWhenHidden && !app.windowActive) Sleep(30);
        else app.tick();

        // 창 크기가 바뀌면 판이 화면을 못 채우게 될 수 있다 — 그때마다 배율을 다시 맞춘다.
        {
            const float mz = MinZoom();
            if (app.zoom < mz) app.zoom = mz;
            ClampPan(app);
        }

        // 배경 — 순수 검정이 기본이고, 「아주 옅은 보라」는 완전한 검정이 답답한 화면에서 쓴다.
        if (app.ui.background == 1) glClearColor(0.012f, 0.009f, 0.021f, 1.f);
        else                        glClearColor(0.f, 0.f, 0.f, 1.f);
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
            // Esc 는 「지금 열려 있는 것을 닫는다」 하나로 읽힌다.
            // 감춤 상태에서는 그것이 곧 「돌아오기」다 — 화면에 아무 안내도 없으므로
            // 사람이 가장 먼저 눌러 보는 키가 통해야 한다.
            if (ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
                if (app.uiHidden)          app.uiHidden = false;
                else if (app.settingsOpen) app.settingsOpen = false;
                else { app.drawerOpen = false; app.shapeDrawerOpen = false; }
            }
            // S 로 설정을, M 으로 재는 창을 여닫는다.
            if (ImGui::IsKeyPressed(ImGuiKey_S, false)) app.settingsOpen = !app.settingsOpen;
            if (ImGui::IsKeyPressed(ImGuiKey_M, false)) app.metersOpen = !app.metersOpen;
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

        // 감추면 **아무것도 남기지 않는다.**
        //
        // 전에는 「H: 조작부 보이기」를 한 줄 띄웠다. 돌아오는 길을 알려 주려던 것인데,
        // 그 한 줄 때문에 화면이 우주만 남지 못했다 — 녹화하거나 그냥 보고 싶어서 감추는
        // 것이므로 남는 글자가 하나라도 있으면 감춘 뜻이 없다. Esc 와 H 둘 다 돌아온다.
        if (app.uiHidden) {
            // 아무것도 그리지 않는다.
        } else {
            // 그리는 순서가 곧 쌓이는 순서다. 어둠 → 서랍 → 막대 순으로 얹는다.
            DrawBottomScrim(app, g_w, g_h);
            DrawHud(app);
            DrawBlackHoleRings(app, g_w, g_h);
            DrawSceneDrawer(app, g_w, g_h);
            DrawShapeDrawer(app, g_w, g_h);
            DrawBottomBar(app, g_w, g_h);
            DrawMeters(app, g_w, g_h);
            // 설정은 맨 마지막이다 — 열려 있는 동안은 막대까지 뒤로 물러나야 한다.
            const bool wasOpen = app.settingsOpen;
            DrawSettings(app, g_w, g_h);
            // 설정 창을 닫는 순간 남긴다. 앱이 강제로 끝나도(작업 관리자, 크래시) 그때까지
            // 맞춰 둔 값은 살아 있어야 한다 — 끝낼 때 한 번만 쓰면 그런 경우에 전부 날아간다.
            if (wasOpen && !app.settingsOpen) SavePrefs(app);
        }

        ImGui::Render();

        // 「녹화에 UI 넣지 않기」가 켜져 있으면 판을 그리기 **전에** 집는다.
        // 뒤에 집으면 막대와 설정 창이 그대로 영상에 박힌다.
        const bool grabBeforeUi = app.ui.recordWithoutUi;
        if (grabBeforeUi) CaptureIfAsked(app, g_w, g_h);

        ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());

        if (!grabBeforeUi) CaptureIfAsked(app, g_w, g_h);

        // 제어 명령은 화면을 다 그린 뒤, 버퍼를 교체하기 전에 처리한다.
        // 그래야 screenshot 이 지금 프레임을 집는다(교체 후엔 백버퍼 내용이 바뀐다).
        if (bridge.poll(app, g_w, g_h)) quit = true;

        // 「기본값으로」 — 앱의 습관과 보기만 되돌린다. 물리 설정(중력·격자·알갱이 수)은
        // 장면이 정하는 것이라 여기서 건드리지 않는다. 그건 장면을 다시 고르면 돌아온다.
        if (app.resetSettingsRequested) {
            app.resetSettingsRequested = false;
            app.ui = UiSettings{};
            app.view = ViewSettings{};
            app.brightDensity = app.brightTemp = 2.0f;
            app.gammaDensity  = app.gammaTemp  = 1.8f;
            ApplyLook(app);
        }

        // 우주 상태 저장·불러오기. 파일 대화상자가 뜬 동안 프레임이 멎으므로 여기서 한다.
        if (app.stateMessageFrames > 0) --app.stateMessageFrames;
        if (app.saveStateRequested || app.loadStateRequested) {
            const bool saving = app.saveStateRequested;
            app.saveStateRequested = app.loadStateRequested = false;

            wchar_t wpath[MAX_PATH] = L"stardust.uni";
            OPENFILENAMEW ofn{};
            ofn.lStructSize = sizeof(ofn);
            ofn.hwndOwner = hwnd;
            ofn.lpstrFilter = L"Stardust 우주\0*.uni\0모든 파일\0*.*\0";
            ofn.lpstrFile = wpath;
            ofn.nMaxFile = MAX_PATH;
            ofn.lpstrDefExt = L"uni";
            ofn.Flags = OFN_NOCHANGEDIR | (saving ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
            const BOOL got = saving ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
            if (got) {
                char utf8[MAX_PATH * 3] = {0};
                WideCharToMultiByte(CP_UTF8, 0, wpath, -1, utf8, sizeof(utf8), nullptr, nullptr);
                const bool ok = saving ? app.sim.saveState(utf8) : app.sim.loadState(utf8);
                // 조용히 실패하면 사용자는 파일이 생긴 줄 안다 — 결과를 반드시 말한다.
                app.stateMessage = saving
                    ? (ok ? "저장했습니다" : "저장하지 못했습니다")
                    : (ok ? "불러왔습니다" : "불러오지 못했습니다 — 형식이 다르거나 깨진 파일입니다");
                app.stateMessageFrames = 240;
            }
        }

        // 저장 폴더 고르기. 대화상자가 뜬 동안 프레임이 멎으므로 그리기가 다 끝난 여기서 연다.
        if (app.pickSaveFolder) {
            app.pickSaveFolder = false;
            BROWSEINFOW bi{};
            bi.hwndOwner = hwnd;
            bi.lpszTitle = L"그림을 저장할 폴더";
            bi.ulFlags   = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
            LPITEMIDLIST pidl = SHBrowseForFolderW(&bi);
            if (pidl) {
                wchar_t wpath[MAX_PATH] = {0};
                if (SHGetPathFromIDListW(pidl, wpath)) {
                    char utf8[MAX_PATH * 3] = {0};
                    WideCharToMultiByte(CP_UTF8, 0, wpath, -1, utf8, sizeof(utf8), nullptr, nullptr);
                    app.ui.saveFolder = utf8;
                }
                CoTaskMemFree(pidl);
            }
        }

        // 프레임 상한.
        //
        // 「화면에 맞춤」은 화면 주사에 맞춰 기다리고(vsync), 「무제한」은 기다리지 않는다.
        // 「60」은 vsync 를 켠 채로도 남는 시간이 있으면 재워, 120 Hz 화면에서도 60 이 되게 한다.
        {
            typedef BOOL (WINAPI *SwapIntervalFn)(int);
            static SwapIntervalFn swapInterval =
                (SwapIntervalFn)wglGetProcAddress("wglSwapIntervalEXT");
            static int appliedCap = -1;
            if (swapInterval && appliedCap != app.ui.frameCap) {
                swapInterval(app.ui.frameCap == 2 ? 0 : 1);
                appliedCap = app.ui.frameCap;
            }
            if (app.ui.frameCap == 1) {
                LARGE_INTEGER end; QueryPerformanceCounter(&end);
                const double used = (end.QuadPart - prev.QuadPart) * 1000.0 / freq.QuadPart;
                const double want = 1000.0 / 60.0;
                if (used < want - 1.0) Sleep((DWORD)(want - used));
            }
        }

        g_gl.present();
    }

    // 맞춰 둔 값을 남긴다. 업데이트로 다시 뜨는 경우에도 여기를 지나므로 설정이 이어진다.
    SavePrefs(app);

    g_field.shutdown();
    ImGui_ImplOpenGL2_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    g_gl.destroy();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, hInst);
    return 0;
}
