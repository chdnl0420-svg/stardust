#include "ui/Hud.h"

#include "imgui.h"

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
        ImGui::Text("CFL 로 간격 축소 %.0f%% (최대속력 %.2f)",
                    100.0f * (1.0f - t.dtUsed / dtWanted), t.maxSpeed);
        ImGui::PopStyleColor();
    }
    if (app.stepsLastFrame > 1)
        ImGui::TextDisabled("프레임당 스텝 %d회", app.stepsLastFrame);

    if (!app.running) {
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("일시정지");
        ImGui::PopStyleColor();
    }
    ImGui::End();
}
