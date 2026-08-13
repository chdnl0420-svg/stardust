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
        return ImVec2(u * viewW, (1.0f - v) * viewH);
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

    ImGui::SetNextWindowPos(ImVec2(12, 12), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.72f);
    ImGui::Begin("##hud", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoMove |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
                 ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs);

    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.37f, 0.76f, 0.48f, 1.0f));
    ImGui::Text("%.1f FPS", app.fps);
    ImGui::PopStyleColor();
    ImGui::SameLine();
    ImGui::TextDisabled("%.2f ms/frame", app.frameMs);
    ImGui::Separator();

    ImGui::TextDisabled("파티클"); ImGui::SameLine();
    ImGui::Text("%d", app.sim.particleCount());

    ImGui::TextDisabled("격자");   ImGui::SameLine();
    ImGui::Text("%d²", app.sim.gridSize()); ImGui::SameLine();
    ImGui::TextDisabled("· %s", app.cfg.boundary == Boundary::Isolated ? "고립경계" : "주기경계");

    ImGui::TextDisabled("시각");   ImGui::SameLine();
    ImGui::Text("t = %.3f", app.sim.simTime());

    // 시간 간격이 CFL 한계에 잘렸으면 알린다 — 이 동안은 화면 속 시간이 설정한 배속보다
    // 천천히 흐른다. 판정은 "요청한 간격보다 실제로 쓴 간격이 작은가"로 한다.
    // 전에는 분할 횟수(substeps)가 1 보다 큰지를 봤는데, 코어가 분할 상한을 1 로 고정해 둬서
    // 그 조건은 결코 참이 되지 않았다 — 경고가 한 번도 뜬 적이 없다(round-06 리뷰 P2 #27).
    SimTimings t = app.sim.timings();
    const float dtWanted = 0.0016f * app.cfg.timeScale;
    if (t.dtUsed > 0.0f && t.dtUsed < dtWanted * 0.99f) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        // HUD 는 입력을 안 받아 마우스를 올려도 설명이 안 뜬다 — 문장 자체를 알아볼 수 있게 쓴다.
        ImGui::Text("빨라서 시간을 %.0f%% 잘게 쪼개는 중 (최고 속도 %.2f)",
                    100.0f * (1.0f - t.dtUsed / dtWanted), t.maxSpeed);
        ImGui::PopStyleColor();
    }
    if (app.stepsLastFrame > 1)
        ImGui::TextDisabled("화면 한 장에 %d번 계산 (배속)", app.stepsLastFrame);

    if (!app.running) {
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("일시정지");
        ImGui::PopStyleColor();
    }
    ImGui::End();
}
