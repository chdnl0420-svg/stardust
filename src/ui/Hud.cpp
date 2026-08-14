#include "ui/Hud.h"

#include "imgui.h"

// 블랙홀 장면에서 중요한 세 반지름을 화면에 겹쳐 그린다.
// 숫자로만 알려주면 어디서 무슨 일이 벌어지는지 볼 수 없다 — 파티클이 어느 원을 넘을 때
// 나선으로 꺾이는지가 이 장면의 핵심이다.
void DrawBlackHoleRings(const App& app, int viewW, int viewH) {
    if (!app.cfg.blackHoleEnabled || app.uiHidden) return;
    if (viewW <= 0 || viewH <= 0) return;

    // 시뮬 좌표 -> 화면 픽셀. 렌더 셰이더(kShade·kSplatPoints)와 같은 변환이라야 자리가 맞는다.
    const float aspect = (float)viewW / (float)viewH;
    auto toScreen = [&](float sx, float sy) -> ImVec2 {
        float u = (sx - 0.5f + app.panX) * app.zoom + 0.5f;
        float v = (sy - 0.5f + app.panY) * app.zoom + 0.5f;
        if (aspect > 1.0f) u = (u - 0.5f) / aspect + 0.5f;
        else               v = (v - 0.5f) * aspect + 0.5f;
        // 세로를 여기서 뒤집지 않는다. 밀도 격자를 화면에 붙이는 쿼드가 텍스처 (0,0) 을
        // 화면 왼쪽 **아래**에 두고(glVertex2f(-1,-1)), 격자를 담을 때 행을 (1-v)·H 로 이미
        // 한 번 뒤집는다 — 두 번 뒤집으면 제자리로 돌아온다. 마우스 입력(screenToSim)도
        // 화면 위를 v=0 으로 읽으므로 같은 방향이다.
        // 뒤집힌 채로 두면 천체가 가스와 아래위 반대편에 그려진다(2026-08-14 실측).
        // 블랙홀 원은 중심 대칭이라 같은 버그를 갖고도 멀쩡해 보였다.
        return ImVec2(u * viewW, v * viewH);
    };

    const ImVec2 c = toScreen(0.5f, 0.5f);
    // 반지름은 중심에서 한 칸 옆으로 옮긴 점까지의 화면 거리로 잰다(줌·화면비가 저절로 반영된다).
    auto radiusPx = [&](float r) {
        const ImVec2 e = toScreen(0.5f + r, 0.5f);
        return e.x - c.x;
    };

    const float rs = app.cfg.blackHoleRs;
    struct Ring { float r; unsigned col; const char* label; };
    const Ring rings[3] = {
        { rs,        IM_COL32(230,  80,  60, 210), "지평선" },
        { 1.5f * rs, IM_COL32(250, 190,  70, 160), "광자 구면" },
        { 3.0f * rs, IM_COL32(120, 200, 255, 140), "최소 안정 궤도" },
    };

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    for (const Ring& g : rings) {
        const float px = radiusPx(g.r);
        if (px < 2.0f || px > (float)viewW * 4.0f) continue;   // 너무 작거나 화면을 벗어나면 생략
        dl->AddCircle(c, px, g.col, 96, 1.6f);
        dl->AddText(ImVec2(c.x + px * 0.70f, c.y - px * 0.70f - 14.0f), g.col, g.label);
    }
    // 지평선 안쪽은 빛도 못 나오는 곳이라 까맣게 덮는다.
    const float rsPx = radiusPx(rs);
    if (rsPx > 2.0f) dl->AddCircleFilled(c, rsPx, IM_COL32(0, 0, 0, 255), 96);
}

void DrawHud(const App& app) {
    // CUDA 가 실패하면 시뮬레이션이 멈춘다. 화면은 마지막 그림 그대로라 앱이 살아 있는 것처럼
    // 보이므로, HUD 를 꺼 둔 상태에서도 이것만은 반드시 띄운다.
    if (Sim::failed()) {
        ImGui::SetNextWindowPos(ImVec2(12, 12), ImGuiCond_Always);
        ImGui::SetNextWindowBgAlpha(0.85f);
        ImGui::Begin("##simfail", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_AlwaysAutoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs);
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.92f, 0.35f, 0.30f, 1.0f));
        ImGui::TextUnformatted("GPU 오류로 시뮬레이션이 멈췄습니다");
        ImGui::PopStyleColor();
        ImGui::TextWrapped("%s", Sim::failMessage().c_str());
        ImGui::TextDisabled("파티클 수나 격자 해상도를 낮춘 뒤 앱을 다시 켜 주세요.");
        ImGui::End();
    }

    if (!app.view.showHud) return;

    // 상태줄은 화면 맨 위에 한 줄로 흐리게 깐다.
    // 늘 보이되 주인공은 우주여야 하므로, 마우스를 올렸을 때만 또렷해진다.
    {
        const ImGuiIO& io = ImGui::GetIO();
        const bool near = (io.MousePos.y >= 0.0f && io.MousePos.y < 40.0f);
        char line[192];
        char cnt[24];
        const int n = app.sim.particleCount();
        if (n >= 10000) snprintf(cnt, sizeof(cnt), "%d만 알", n / 10000);
        else            snprintf(cnt, sizeof(cnt), "%d 알", n);
        // 시간이 잘리는 것은 늘 일어나므로 따로 창을 띄우지 않고 이 줄에 붙인다.
        // 상주하는 경고 창은 「평소엔 우주뿐」을 무너뜨린다.
        const SimTimings tt = app.sim.timings();
        const float want = 0.0016f * app.cfg.timeScale;
        char slow[48] = { 0 };
        if (tt.dtUsed > 0.0f && tt.dtUsed < want * 0.9f)
            snprintf(slow, sizeof(slow), " · 시간 %.0f%% 눌림", 100.0f * (1.0f - tt.dtUsed / want));
        snprintf(line, sizeof(line), "%.1f FPS · %s · %d² · t %.3f%s",
                 app.fps, cnt, app.sim.gridSize(), app.sim.simTime(), slow);
        ImGui::GetBackgroundDrawList()->AddText(
            ImVec2(14.0f, 9.0f),
            IM_COL32(154, 154, 168, near ? 255 : 115), line);
    }

    // 아래는 알려야 할 것이 있을 때만 뜨는 알림이다. 평소에는 아무것도 그리지 않는다.
    // 접촉은 켜졌는데 알갱이가 많아 못 도는 경우만 알린다. 잘 돌 때는 조용하다.
    const bool contactNote = app.cfg.contactEnabled
                          && !ContactFitsCount(app.sim.particleCount(), app.sim.gridSize());
    if (!contactNote && app.running) return;

    ImGui::SetNextWindowPos(ImVec2(12, 34), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.55f);
    ImGui::Begin("##hud", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoMove |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
                 ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs);

    if (contactNote) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("알갱이가 너무 많아 충돌을 껐습니다");
        ImGui::PopStyleColor();
        ImGui::TextDisabled("최대 개수를 %d 이하로 낮추면 켜집니다",
                            (int)(0.764 * (double)app.sim.gridSize() * app.sim.gridSize()));
    }

    if (!app.running) {
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("일시정지");
        ImGui::PopStyleColor();
    }
    ImGui::End();
}
