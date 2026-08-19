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

#include <dbghelp.h>    // MiniDumpWriteDump — 앱이 스스로 죽을 때의 덤프

#include "app/App.h"
#include "app/ControlBridge.h"
#include "sim/ViewRot.h"   // 우클릭 드래그를 화면 기준 회전으로 쌓는다(viewRotOrbit)
#include "app/Forensics.h"
#include "app/Prefs.h"
#include "app/Version.h"
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

// 앱이 **스스로** 죽을 때(접근 위반 따위) 덤프를 남긴다.
//
// 이 프로젝트의 큰 사고는 시스템이 통째로 재부팅되는 쪽이라 이 손은 닿지 않는다 —
// 그건 로그의 마지막 줄로 좇아야 한다(Forensics). 여기서 잡는 것은 그보다 흔한
// 「앱만 사라졌다」 쪽이고, 그때는 덤프 하나면 어디서 죽었는지 바로 나온다.
LONG WINAPI OnAppCrash(EXCEPTION_POINTERS* ep) {
    char path[1200];
    SYSTEMTIME st{};
    GetLocalTime(&st);
    snprintf(path, sizeof(path), "%s\\crash-%04d%02d%02d-%02d%02d%02d.dmp",
             fx::logDir(), st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);

    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei{};
        mei.ThreadId = GetCurrentThreadId();
        mei.ExceptionPointers = ep;
        mei.ClientPointers = FALSE;
        // 지역 변수와 가리키는 곳까지 담는다. 파일이 몇십 MB 로 커지지만, 알갱이 수·격자처럼
        // 정작 원인을 말해 주는 값이 스택에 있어서 그것을 빼면 덤프를 열 이유가 없다.
        MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), h,
                          (MINIDUMP_TYPE)(MiniDumpWithIndirectlyReferencedMemory |
                                          MiniDumpScanMemory | MiniDumpWithThreadInfo),
                          &mei, nullptr, nullptr);
        CloseHandle(h);
    }
    if (ep && ep->ExceptionRecord) {
        fx::mark("!! 앱이 죽었습니다: 예외 0x%08lX, 주소 %p — 덤프 %s",
                 (unsigned long)ep->ExceptionRecord->ExceptionCode,
                 ep->ExceptionRecord->ExceptionAddress, path);
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

App*         g_app  = nullptr;
GLContext    g_gl;
RenderField  g_field;
int          g_w = 1600, g_h = 900;
bool         g_boardOpen = true;

// ── 테두리 없는 전체화면(창모드) ───────────────────────────────────────────
//
// **독점 전체화면이 아니라 「화면을 덮는 창」이다.** 해상도를 바꾸지 않고 창을 모니터
// 크기로 늘려 테두리만 없앤다. 알트탭이 즉시 되고, 다른 창을 위에 띄울 수 있고,
// 무엇보다 **화면 모드 전환이 없어 드라이버를 건드리지 않는다** — 이 판에서 드라이버를
// 건드리는 일은 곧 시스템이 죽는 일이다(CLAUDE.md 0번의 여덟 번).
//
// **`HWND_TOPMOST` 를 쓰지 않는다.** 최상위 고정은 그 자체로 GPU 를 요구하고,
// 2026-08-17 에 캡처 도구들이 마지막 여유를 밀어내 프레임이 89→53 으로 떨어진 적이 있다.
// 창모드 전체화면의 목적(다른 창과 함께 쓰기)에도 최상위는 어긋난다.
//
// 되돌아갈 자리는 `WINDOWPLACEMENT` 로 통째 저장한다 — 위치·크기뿐 아니라 최대화
// 상태까지 담겨서, 최대화된 창에서 들어갔다 나와도 최대화로 돌아온다.
bool             g_fullscreen = false;
WINDOWPLACEMENT  g_prevPlace{ sizeof(WINDOWPLACEMENT) };
LONG             g_prevStyle = 0;

void ToggleFullscreen(HWND hwnd) {
    if (!g_fullscreen) {
        g_prevStyle = GetWindowLongW(hwnd, GWL_STYLE);
        if (!GetWindowPlacement(hwnd, &g_prevPlace)) return;

        // **창이 지금 놓인 모니터**를 기준으로 잡는다. 주 모니터로 고정하면
        // 보조 화면에서 쓰던 사람이 창을 잃는다.
        MONITORINFO mi{ sizeof(MONITORINFO) };
        if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi)) return;

        SetWindowLongW(hwnd, GWL_STYLE, g_prevStyle & ~WS_OVERLAPPEDWINDOW);
        SetWindowPos(hwnd, HWND_TOP,
                     mi.rcMonitor.left, mi.rcMonitor.top,
                     mi.rcMonitor.right - mi.rcMonitor.left,
                     mi.rcMonitor.bottom - mi.rcMonitor.top,
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        g_fullscreen = true;
    } else {
        SetWindowLongW(hwnd, GWL_STYLE, g_prevStyle);
        SetWindowPlacement(hwnd, &g_prevPlace);
        // 테두리를 되살리려면 크기를 안 바꾸더라도 `SWP_FRAMECHANGED` 로 한 번 알려야 한다.
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        g_fullscreen = false;
    }
    if (g_app) g_app->fullscreen = g_fullscreen;   // 설정 창 체크박스가 읽는 값
    // 크기는 `WM_SIZE` 가 받아 `g_w`·`g_h` 에 넣는다. 렌더 버퍼는 **커질 때만** 다시
    // 잡히므로(`RenderField.cu` 의 `w <= allocW_` 검사) 창모드로 돌아올 때는 재할당이
    // 없다 — 오갈 때마다 잡았다 버리면 그것이 곧 CLAUDE.md 1번이 막는 사고다.
}

// 카메라 드래그 상태. 도구가 카메라일 때만 화면을 끈다.
bool  g_dragging = false;
POINT g_dragLast{};
// 도구로 칠하는 중(뿌리기·우물·지우개는 드래그 동안 이어진다)
bool  g_painting = false;
// 오른쪽 단추로 시점을 돌리는 중. 어떤 도구를 들고 있든 오른쪽 단추는 늘 시점이다 —
// 왼쪽은 도구가 가져가므로 「도구를 내려놓아야 돌려 볼 수 있는」 일이 없게 한다.
bool  g_orbiting = false;
POINT g_orbitLast{};

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

// **확대·축소를 한 곳에 둔다.** 휠과 왼쪽 줌 막대가 이것을 함께 부른다 —
// 둘로 나뉘면 같은 일을 다르게 해서 서로 어긋나기 시작한다.
// `notches` 는 휠 한 칸을 1 로 센 양(양수 = 확대).
void ApplyZoom(App& app, float notches) {
    if (notches == 0.0f) return;
    // 한 칸에 얼마나 확대할지. 설정의 「휠 확대 속도」가 1.0 일 때 12% 다.
    // 막대에서 온 것은 칸이 잘게 쪼개져 오므로 그 크기를 그대로 지수에 싣는다.
    const float mag  = fabsf(notches);
    const float step = powf(1.0f + 0.15f * app.ui.wheelZoomSpeed, mag);

    if (app.camFly) {
        // **원근에서 확대란 카메라를 앞으로 옮기는 것이다**(돌리 줌).
        //
        // 처음엔 시야각을 좁혔는데(망원렌즈) 하한 17도까지 좁혀도 3.6배라, 예전 궤도
        // 모드의 64배에 한참 못 미쳤다(2026-08-19 사용자 보고: 「확대가 이전보다 덜되는데」).
        // 시야각은 좁힐수록 원근이 사라져 평면처럼 보이는 한계도 있다. 가까이 보는 것의
        // 본질은 **가까이 가는 것**이다.
        //
        // 한 칸에 「지금 판 중심까지 거리」의 일정 비율만큼 간다. 그래야 멀리서는 성큼,
        // 가까이서는 조금씩 움직여 원하는 자리에 세우기 쉽다. 판 중심을 지나쳐 뒤로
        // 넘어가지 않게 최소 거리를 둔다.
        const float* rz = app.camRot + 6;   // 화면 깊이축(보는 방향)
        const float toC[3] = { 0.5f - app.camPos[0],
                               0.5f - app.camPos[1],
                               0.5f - app.camPos[2] };
        const float dist = toC[0]*rz[0] + toC[1]*rz[1] + toC[2]*rz[2];
        const float ref  = (dist > 0.05f) ? dist : 0.05f;
        const float mv   = ((notches > 0) ? 1.f : -1.f) * ref * (step - 1.0f);
        for (int k = 0; k < 3; ++k) app.camPos[k] += rz[k] * mv;
    } else {
        app.zoom *= (notches > 0) ? step : (1.0f / step);
        const float mz = MinZoom();     // 판이 화면을 꽉 채우는 선까지만 줄인다
        if (app.zoom < mz)     app.zoom = mz;
        if (app.zoom > 64.0f)  app.zoom = 64.0f;
        ClampPan(app);
    }
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

        // 오른쪽 단추 — **누르고 있는 동안 마우스가 시점을 조준한다.**
        //
        // **화면은 하나다.** 처음에는 누를 때 자유 비행으로, 놓을 때 궤도로 바꿨는데
        // 그러면 놓는 순간 보던 시점이 사라지고 전체 뷰로 튄다. 사용자 지적(2026-08-18):
        // 「궤도 화면과 자유모드 화면이 별도로 있어서는 안돼. 자유 모드로 이동하다가
        // 같이 화면 같은 각도에서 궤도화면으로 움직이고 다시 우클릭하고있으면 자유모드로」.
        //
        // 그래서 카메라는 **언제나 자유 비행 하나**이고, 우클릭은 조준을 잡느냐만 가른다.
        // 놓으면 커서가 풀려 UI 를 만질 수 있고, 좌클릭 드래그는 같은 시점에서 옆으로
        // 밀어 옮긴다 — 보던 각도는 그대로 남는다.
        case WM_RBUTTONDOWN:
            if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                SetCapture(hwnd);
                g_orbiting = true;
                GetCursorPos(&g_orbitLast);
            }
            return 0;

        case WM_RBUTTONUP:
            if (g_orbiting) {
                g_orbiting = false;
                ReleaseCapture();
            }
            return 0;

        case WM_MOUSEMOVE:
            if (g_orbiting && g_app) {
                POINT now; GetCursorPos(&now);
                // 화면을 가로로 한 번 지나가면 반 바퀴(180도) 돈다.
                // 한 바퀴로 두었더니 조금만 움직여도 확 돌아 겨냥이 어려웠다
                // (2026-08-18 사용자 보고: 「카메라 회전이 너무 빨라」).
                const float turn = 3.1415927f / (float)(g_w > 0 ? g_w : 1);
                // **화면 기준으로 돌린다** — 가로로 끌면 지금 보이는 화면의 세로축,
                // 세로로 끌면 화면의 가로축이 축이다. 그래서 어느 방향으로 아무리 돌려도
                // 걸리거나 뒤집히지 않고, 끄는 방향과 도는 방향이 늘 일치한다.
                // (판에 고정된 축으로 돌리면 기울여 놓았을 때 비스듬히 빙글빙글 돈다 —
                //  사용자가 「판 기준으로 돌아서 멀미가나」로 알린 것이 그것이다.)
                //
                // **가로는 부호를 뒤집는다** — 마우스를 오른쪽으로 끌면 시점이 오른쪽을
                // 보고, 그래서 판은 왼쪽으로 흘러야 한다. 안 뒤집으면 끄는 쪽과 도는 쪽이
                // 반대다(2026-08-18 사용자 보고: 「우클릭 좌우가 반대로 움직여」).
                viewRotOrbit(g_app->camRot,
                             -(now.x - g_orbitLast.x) * turn,
                              (now.y - g_orbitLast.y) * turn);
                g_orbitLast = now;
            } else if (g_dragging && g_app) {
                POINT now; GetCursorPos(&now);
                const float s = g_app->ui.dragSensitivity;
                if (g_app->camFly) {
                    // **자유 비행 — 카메라를 화면 축 방향으로 밀어 옮긴다.**
                    //
                    // 궤도 모드의 `pan` 은 판을 화면에 어떻게 놓을지의 값이라 여기서는
                    // 뜻이 없다(카메라가 공간 안에 있으므로). 대신 카메라 자체를 지금
                    // 보이는 화면의 가로축·세로축으로 옮긴다 — 회전 행렬의 첫 두 행이
                    // 곧 그 축이다.
                    //
                    // 부호: 마우스를 오른쪽으로 끌면 **판이 오른쪽으로 따라와야** 한다.
                    // 화면 좌표가 `ox = row0·(p − cam)` 이라 카메라를 +row0 로 옮기면 모든 점의
                    // ox 가 줄어 판이 왼쪽으로 간다 — 그러니 카메라는 **−row0** 로 가야 한다.
                    // (2026-08-19 에 이 부호를 두 번 뒤집었다. 사용자 보고 「좌우가 반대」→ +로
                    //  바꿨더니 「다시 반대로 됐어 회귀됐어」. 수학으로 확정: 음수가 맞다.
                    //  첫 보고 때 반대였던 것은 아마 우클릭 조준의 좌우였을 것이다.)
                    // 세로도 음수다. 「창 좌표가 아래로 커지고 화면은 `fyp=(1−v)·H` 로 뒤집혀
                    // 그려지니 그대로 더한다」고 유도했는데 실측이 반대였다(2026-08-19 사용자
                    // 보고 「위아래도 반대로 돼있어」, 조작을 좌클릭 드래그로 특정한 뒤 고침).
                    // 유도가 두 번 어긋난 자리라 **부호는 사용자 실측을 따르고**, 바꿀 때는
                    // 가로·세로 둘을 한 번에 사용자에게 확인받는다.
                    // **가까이 있을수록 조금씩 움직인다(2026-08-19).** 화면에 보이는 폭이
                    // 카메라와 판 중심 사이 거리에 비례하므로(원근), 마우스가 화면을 한 번
                    // 가로지를 때 카메라가 「지금 보이는 폭」만큼 가게 하면 어느 거리에서나
                    // 판이 손을 따라온다. 거리를 안 곱하면 확대해 놓았을 때 조금만 끌어도
                    // 화면이 통째로 날아간다(사용자 보고: 「확대됐을때 너무 화면이 빨리 변해」).
                    // 휠 확대(아래 WM_MOUSEWHEEL)와 같은 거리 기준을 쓴다.
                    const float* rx = g_app->camRot + 0;   // 화면 가로축
                    const float* ry = g_app->camRot + 3;   // 화면 세로축
                    const float* rz = g_app->camRot + 6;   // 화면 깊이축
                    const float toC[3] = { 0.5f - g_app->camPos[0],
                                           0.5f - g_app->camPos[1],
                                           0.5f - g_app->camPos[2] };
                    const float dist = toC[0]*rz[0] + toC[1]*rz[1] + toC[2]*rz[2];
                    const float ref  = (dist > 0.05f) ? dist : 0.05f;
                    // 그 거리에서 화면 세로가 덮는 폭 = 2·dist·tan(fov/2). 세로 픽셀로 나눠
                    // 픽셀당 이동량을 낸다. 가로도 같은 눈금이라야 종횡비가 안 뒤틀린다.
                    const float span = 2.0f * ref * std::tan(g_app->camFovY * 0.5f);
                    const float perPx = span / (float)(g_h > 0 ? g_h : 1) * s;
                    const float dx = (now.x - g_dragLast.x) * perPx;
                    const float dy = (now.y - g_dragLast.y) * perPx;
                    for (int k = 0; k < 3; ++k)
                        g_app->camPos[k] += -rx[k] * dx - ry[k] * dy;
                } else {
                    // 화면 픽셀 이동량을 시뮬레이션 공간 이동량으로 바꾼다.
                    // 짧은 변이 [0,1] 에 대응하므로 그 값으로 나눈다.
                    const float unit = (float)(g_w < g_h ? g_w : g_h) * g_app->zoom;
                    g_app->panX += (now.x - g_dragLast.x) * s / unit;
                    g_app->panY += (now.y - g_dragLast.y) * s / unit;
                    ClampPan(*g_app);
                }
                g_dragLast = now;
            } else if (g_painting && g_app) {
                float u, v;
                g_app->screenToSim(GET_X_LPARAM(lp), GET_Y_LPARAM(lp), g_w, g_h, u, v);
                g_app->applyToolAt(u, v, false);   // 형태 추가는 드래그 중엔 안 넣는다
            }
            return 0;

        // **휠(가운데 단추) 클릭 — 보기를 처음으로 되돌린다.**
        //
        // 돌리고 옮기고 확대하다 보면 지금 어디를 어느 방향으로 보고 있는지 알 수 없게
        // 된다. 회전 상태가 행렬이 되면서 「각도를 0 으로 되돌린다」로는 풀 수 없어졌고,
        // 되돌릴 수단이 하나 있어야 한다. 회전·이동·배율 셋을 한 번에 처음으로 돌린다.
        case WM_MBUTTONDOWN:
            if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                viewRotIdentity(g_app->camRot);       // 위에서 곧장 내려다보기
                g_app->panX = 0.0f;
                g_app->panY = 0.0f;
                g_app->zoom = MinZoom();              // 판이 화면에 꼭 맞는 배율
                ClampPan(*g_app);
                // 자유 비행이면 카메라 자리도 처음으로 — 안 되돌리면 판 밖 어딘가에
                // 떠 있는 채로 방향만 바뀌어 아무것도 안 보인다.
                g_app->camPos[0] = 0.5f;
                g_app->camPos[1] = 0.5f;
                g_app->camPos[2] = -0.6f;
                g_app->camFovY = 1.0f;                // 휠로 좁혀 둔 시야각도 처음으로
            }
            return 0;

        case WM_MOUSEWHEEL:
            // **우클릭을 누르고 있는 동안(자유 모드)은 휠을 무시한다(2026-08-19).**
            // 그때는 WASD 로 앞뒤를 오가므로 휠 확대가 겹치면 두 조작이 같은 일을 다르게 해
            // 헷갈린다. 사용자 요청: 「패널 모드에서 휠로 줌 기능은 살려줘. 자유모드일때는
            // 동작안하게해주고」.
            if (g_app && !g_orbiting && !ImGui::GetIO().WantCaptureMouse) {
                float d = GET_WHEEL_DELTA_WPARAM(wp) / 120.0f;
                if (g_app->ui.wheelInverted) d = -d;
                ApplyZoom(*g_app, d);
            }
            return 0;

        // 창이 뒤로 가면 계산을 멈출 수 있게 상태를 적어 둔다(설정의 「창이 뒤에 있으면 멈추기」).
        case WM_ACTIVATE:
            if (g_app) g_app->windowActive = (LOWORD(wp) != WA_INACTIVE);
            return 0;

        case WM_KEYDOWN:
            // **F11 은 설정 창이 떠 있어도 듣는다.** 창 크기를 바꾸는 것은 글자를 넣는
            // 일과 겹치지 않고, 전체화면에서 빠져나오려는데 창 하나 때문에 막히면
            // 갇힌 것처럼 느껴진다. 그래서 `WantCaptureKeyboard` 검사 앞에 둔다.
            if (wp == VK_F11) { ToggleFullscreen(hwnd); return 0; }
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
    // **무엇보다 먼저 사고 기록을 연다.** 카드를 찾는 것조차 실패할 수 있고, 그 사실도
    // 남아야 한다. 직전 세션이 재부팅으로 끝났으면 여기서 그 표시가 로그 맨 위에 찍힌다.
    fx::begin(STARDUST_VERSION);
    SetUnhandledExceptionFilter(OnAppCrash);

    if (!Sim::deviceAvailable()) {
        fx::mark("CUDA 장치를 찾지 못했습니다 — 끝냅니다");
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

        // ── 자유 비행 카메라 — 키로 움직인다 ────────────────────────────────
        //
        // **메시지가 아니라 매 프레임 눌린 상태를 읽는다.** `WM_KEYDOWN` 은 처음 한 번
        // 오고 나서 자동 반복이 붙는 방식이라, 누르고 있는 동안 매끄럽게 움직이려면
        // 그 반복 간격에 끌려다니게 된다. 지금 눌려 있는지를 직접 보는 편이 프레임과
        // 정확히 맞는다.
        //
        // **방향은 화면 축이다** — 회전 행렬의 각 행이 화면의 가로·세로·깊이축이므로
        // 그대로 쓰면 「보는 방향으로 앞」이 된다.
        //   W/S 앞뒤(셋째 행) · A/D 좌우(첫째 행) · Q/E 위아래(둘째 행)
        //
        // 창이 뒤에 있거나 ImGui 가 키보드를 잡고 있으면(설정 창에 값을 적는 중) 건너뛴다.
        if (app.camFly && app.windowActive && !ImGui::GetIO().WantCaptureKeyboard) {
            const float dt = dtMs * 0.001f;
            float sp = app.camSpeed * dt;
            if (GetAsyncKeyState(VK_SHIFT) & 0x8000) sp *= 2.0f;   // 빠르게
            const float* rx = app.camRot + 0;   // 화면 가로축
            const float* ry = app.camRot + 3;   // 화면 세로축
            const float* rz = app.camRot + 6;   // 화면 깊이축(보는 방향)
            float mv[3] = { 0.f, 0.f, 0.f };
            auto add = [&mv](const float* axis, float k) {
                mv[0] += axis[0] * k; mv[1] += axis[1] * k; mv[2] += axis[2] * k;
            };
            if (GetAsyncKeyState('W') & 0x8000) add(rz,  1.f);
            if (GetAsyncKeyState('S') & 0x8000) add(rz, -1.f);
            if (GetAsyncKeyState('D') & 0x8000) add(rx,  1.f);
            if (GetAsyncKeyState('A') & 0x8000) add(rx, -1.f);
            // E 가 위, Q 가 아래다. 화면 세로축은 값이 커질수록 화면 아래쪽이라
            // 부호가 뒤집혀 보인다 — 눌러 본 방향에 맞춘다(2026-08-18).
            if (GetAsyncKeyState('E') & 0x8000) add(ry, -1.f);
            if (GetAsyncKeyState('Q') & 0x8000) add(ry,  1.f);
            // Z/C — 보는 방향을 축으로 화면을 굴린다(roll). 원반을 비스듬히 볼 때
            // 수평을 맞추는 데 쓴다. 초당 한 바퀴의 1/6(60도)이고 Shift 면 두 배다.
            float roll = 0.f;
            if (GetAsyncKeyState('C') & 0x8000) roll += 1.f;
            if (GetAsyncKeyState('Z') & 0x8000) roll -= 1.f;
            if (roll != 0.f) {
                float rs = 1.0472f * dt;                            // 60도/초
                if (GetAsyncKeyState(VK_SHIFT) & 0x8000) rs *= 2.f;
                viewRotRoll(app.camRot, roll * rs);
            }
            // 대각선으로 갈 때 빨라지지 않게 길이를 맞춘다.
            const float L = std::sqrt(mv[0]*mv[0] + mv[1]*mv[1] + mv[2]*mv[2]);
            if (L > 1e-6f) {
                const float k = sp / L;
                app.camPos[0] += mv[0] * k;
                app.camPos[1] += mv[1] * k;
                app.camPos[2] += mv[2] * k;
            }
        }

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

        // 왼쪽 줌 막대가 요청한 확대를 여기서 처리한다 — 휠과 **같은 함수**를 쓴다.
        if (app.zoomRequest != 0.0f) {
            ApplyZoom(app, app.zoomRequest);
            app.zoomRequest = 0.0f;
        }

        // 설정 창에서 전체화면을 뒤집었으면 여기서 실제로 창을 옮긴다.
        // **UI 는 값만 바꾸고 창은 건드리지 않는다** — `ToggleFullscreen` 이 되돌아가며
        // `app.fullscreen` 을 다시 맞추므로 이 검사가 두 번 돌지 않는다.
        if (app.fullscreen != g_fullscreen) ToggleFullscreen(hwnd);

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
            // **설정은 F1 로 연다.** 예전에는 S 였는데, 자유 비행에서 S 가 뒤로 가기라
            // 누를 때마다 설정 창이 열렸다(2026-08-18 사용자 보고: 「s누르면 옵션 창이
            // 켜져」). 모드마다 다르게 두면 손이 헷갈리므로 **어느 모드에서나 S 는 안 쓴다.**
            // 아래 막대의 단추로도 열 수 있다.
            if (ImGui::IsKeyPressed(ImGuiKey_F1, false)) app.settingsOpen = !app.settingsOpen;
            // M 으로 재는 창을 여닫는다.
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
            DrawZoomBar(app, g_w, g_h);
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

    // 여기까지 왔으면 스스로 끝난 것이다. 표시를 지워 다음 실행이 「정상이었다」로 읽게 한다 —
    // 이 줄에 닿지 못한 모든 경우(재부팅·강제종료·드라이버 리셋)가 비정상으로 남는다.
    fx::endOk();
    return 0;
}
