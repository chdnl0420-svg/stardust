#include "ui/Hud.h"

#include "imgui.h"

// 블랙홀 장면에서 중요한 세 반지름을 화면에 겹쳐 그린다.
// 숫자로만 알려주면 어디서 무슨 일이 벌어지는지 볼 수 없다 — 파티클이 어느 원을 넘을 때
// 나선으로 꺾이는지가 이 장면의 핵심이다.
void DrawBlackHoleRings(const App& app, int viewW, int viewH) {
    if (!app.cfg.blackHoleEnabled || app.uiHidden || !app.showOverlay) return;
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

// 가스가 뭉쳐 만들어진 천체를 화면에 겹쳐 그린다.
//
// 밀도 격자에 얹혀 있기는 하지만, 천체 하나가 격자 한두 칸이라 밀도 그림만으로는
// 「저 점이 별인지 그냥 빽빽한 가스인지」 구분할 수 없다. 등급을 색으로 갈라 준다.
void DrawBodies(const App& app, int viewW, int viewH) {
    if (!app.cfg.bodiesEnabled || app.bodyListCount <= 0 || !app.showOverlay) return;
    if (viewW <= 0 || viewH <= 0) return;

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
    // 화면 반지름 환산 배율. 중심에서 한 칸 옆으로 옮긴 점까지의 거리로 잰다.
    const ImVec2 o0 = toScreen(0.0f, 0.5f), o1 = toScreen(1.0f, 0.5f);
    const float pxPerUnit = o1.x - o0.x;

    struct Look { unsigned fill, edge; };
    const Look looks[3] = {
        { IM_COL32(170, 150, 130, 230), IM_COL32(210, 195, 175, 255) },  // 소행성 — 돌 색
        { IM_COL32( 90, 160, 220, 235), IM_COL32(150, 205, 255, 255) },  // 행성 — 푸른빛
        { IM_COL32(255, 225, 130, 245), IM_COL32(255, 250, 210, 255) },  // 별 — 노란빛
    };

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    for (int i = 0; i < app.bodyListCount; ++i) {
        const BodyView& b = app.bodyList[i];
        const int g = (b.grade < 0) ? 0 : (b.grade > 2 ? 2 : b.grade);
        const ImVec2 c = toScreen(b.x, b.y);
        if (c.x < -40.f || c.y < -40.f || c.x > viewW + 40.f || c.y > viewH + 40.f) continue;
        // 실제 반지름이 한 픽셀도 안 되는 천체가 대부분이다 — 그대로 그리면 안 보이므로
        // 등급마다 최소 크기를 준다. 커진 천체는 실제 크기를 따라간다.
        // 1.6 px 로 뒀더니 1600×900 원본에서도 가스 알갱이와 구분되지 않았다(2026-08-14 실측).
        const float minPx = 3.0f + 2.0f * g;
        float px = b.radius * pxPerUnit;
        if (px < minPx) px = minPx;
        if (px > 200.f) px = 200.f;
        dl->AddCircleFilled(c, px, looks[g].fill, 20);
        dl->AddCircle(c, px, looks[g].edge, 20, 1.2f);
        // 별은 주변을 밝히는 것이 눈에 띄어야 한다
        if (g == 2) dl->AddCircle(c, px * 2.2f, IM_COL32(255, 235, 160, 60), 24, 2.0f);
    }
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

    // 천체 현황 — 이 장면의 결과 그 자체라 눈에 잘 띄어야 한다.
    if (app.cfg.bodiesEnabled) {
        const BodyStats bs = app.sim.bodyStats();
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.82f, 0.75f, 0.66f, 1.0f));
        ImGui::Text("소행성 %d", bs.asteroids);
        ImGui::PopStyleColor();
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.45f, 0.70f, 0.92f, 1.0f));
        ImGui::Text("· 행성 %d", bs.planets);
        ImGui::PopStyleColor();
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.00f, 0.88f, 0.52f, 1.0f));
        ImGui::Text("· 별 %d", bs.stars);
        ImGui::PopStyleColor();
        ImGui::TextDisabled("가장 큰 것 %.0f 알갱이 · 합체 %d · 파괴 %d",
                            bs.heaviest, bs.merges, bs.shatters);
    }

    if (!app.running) {
        ImGui::Separator();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextUnformatted("일시정지");
        ImGui::PopStyleColor();
    }
    ImGui::End();
}
