#include "ui/Hud.h"

#include "imgui.h"

void DrawHud(const App& app) {
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

    // 시간 간격이 잘려 여러 번 나눠 돌고 있으면 알린다.
    // 이게 뜨는 동안은 화면의 시간이 설정한 배속보다 천천히 흐른다.
    SimTimings t = app.sim.timings();
    if (t.substeps > 1) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::Text("CFL 분할 %d회 (최대속력 %.0f)", t.substeps, t.maxSpeed);
        ImGui::PopStyleColor();
    }

    if (!app.running) {
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("일시정지");
        ImGui::PopStyleColor();
    }
    ImGui::End();
}
