#include "ui/Board.h"

#include "imgui.h"
#include <cstdio>

namespace {

// 아직 동작하지 않는 항목에 붙인다. 자리는 시안대로 두되 회색으로 잠근다
// (spec.md 머리말: 기능이 뒤 증분이어도 자리는 첫 증분부터 시안대로 놓는다).
struct Pending {
    Pending()  { ImGui::BeginDisabled(true); }
    ~Pending() { ImGui::EndDisabled(); }
};

void SectionNote(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.55f, 0.55f, 0.60f, 1.0f));
    ImGui::TextWrapped("%s", text);
    ImGui::PopStyleColor();
}

const char* PresetName(Preset p) {
    switch (p) {
        case Preset::SpiralDisk:  return "나선팔";
        case Preset::TidalPair:   return "조석 꼬리";
        case Preset::HeadOnShock: return "충격파";
        case Preset::CosmicWeb:   return "구조 형성";
        default:                  return "빈 판";
    }
}

} // namespace

void DrawBoard(App& app, bool& boardOpen) {
    if (!boardOpen) return;

    ImGuiIO& io = ImGui::GetIO();
    const float boardW = 320.0f;
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - boardW, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(boardW, io.DisplaySize.y), ImGuiCond_Always);
    ImGui::Begin("설정 보드", nullptr,
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBringToFrontOnFocus);

    if (ImGui::Button("◂ 접기")) boardOpen = false;
    ImGui::SameLine();
    ImGui::TextDisabled("X1 · CUDA");
    ImGui::Separator();

    // ---------------- 1. 시뮬레이션 ----------------
    if (ImGui::CollapsingHeader("시뮬레이션", ImGuiTreeNodeFlags_DefaultOpen)) {
        if (ImGui::Button(app.running ? "⏸ 일시정지" : "▶ 재생")) app.running = !app.running;
        ImGui::SameLine();
        if (ImGui::Button("⏭ 한 스텝")) { app.running = false; app.stepOnce = true; }
        ImGui::SameLine();
        if (ImGui::Button("↺ 리셋")) {
            // 지금 화면에 있는 설정으로 초기조건을 다시 만든다.
            // 코어에 먼저 넘기지 않으면 이번 프레임에 만진 값이 빠진 채로 리셋된다.
            app.applyConfig();
            app.sim.reset();
        }

        int n = app.cfg.particleCount / 100000;
        if (ImGui::SliderInt("파티클 수", &n, 1, 300, "%d0만"))
            app.cfg.particleCount = n * 100000;
        // 코어가 VRAM 에 안 들어가는 요청을 최대 가능 수로 잘랐으면 그 사실을 알린다.
        // 조용히 줄이면 사용자는 슬라이더 값이 반영된 줄 안다.
        if (app.sim.particleCount() < app.cfg.particleCount) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
            ImGui::TextWrapped("VRAM 이 모자라 %d 개로 줄였습니다 (요청 %d)",
                               app.sim.particleCount(), app.cfg.particleCount);
            ImGui::PopStyleColor();
            if (ImGui::SmallButton("최대치로 맞추기")) {
                app.cfg.particleCount = app.sim.particleCount();
            }
        }

        const char* gridItems[] = { "1024²", "2048²", "4096²" };
        int gridIdx = (app.cfg.gridSize == 1024) ? 0 : (app.cfg.gridSize == 2048) ? 1 : 2;
        if (ImGui::Combo("격자 해상도", &gridIdx, gridItems, 3))
            app.cfg.gridSize = (gridIdx == 0) ? 1024 : (gridIdx == 1) ? 2048 : 4096;

        ImGui::SliderFloat("시간 배속", &app.cfg.timeScale, 0.1f, 4.0f, "%.1fx");
        // 1배를 넘는 배속은 프레임당 스텝 횟수로 내므로 정수만 뜻이 있다.
        // 스냅하지 않으면 3.4배속이 조용히 3회로 반올림돼, 슬라이더 값과 실제 진행이 어긋난다.
        if (app.cfg.timeScale > 1.0f) {
            app.cfg.timeScale = (float)(int)(app.cfg.timeScale + 0.5f);
            SectionNote("배속을 1보다 올리면 한 프레임에 스텝을 여러 번 돈다 — 계산량도 그만큼 늘어난다. "
                        "시간 간격은 안정성 한계에 묶여 있으므로 이 구간은 정수 배속만 쓴다.");
        }
        ImGui::SliderInt("정렬 주기", &app.cfg.sortInterval, 1, 120, "%d 스텝");
        SectionNote("정렬 주기는 성능에만 영향을 준다. 실측상 40스텝까지는 유지되고 80부터 나빠진다.");
    }

    // ---------------- 2. 중력 ----------------
    if (ImGui::CollapsingHeader("중력", ImGuiTreeNodeFlags_DefaultOpen)) {
        ImGui::SliderFloat("중력 세기", &app.cfg.gravity, 0.0f, 2.0f, "%.2f");

        const char* lawItems[] = { "1/r² (3D형)", "1/r (진짜 2D)" };
        int lawIdx = (app.cfg.law == GravityLaw::InverseSquare) ? 0 : 1;
        if (ImGui::Combo("힘 공식", &lawIdx, lawItems, 2)) {
            app.cfg.law = (lawIdx == 0) ? GravityLaw::InverseSquare : GravityLaw::InverseR;
        }
        const char* bndItems[] = { "고립 (은하)", "주기 (우주론)" };
        int bndIdx = (app.cfg.boundary == Boundary::Isolated) ? 0 : 1;
        if (ImGui::Combo("경계 조건", &bndIdx, bndItems, 2))
            app.cfg.boundary = (bndIdx == 0) ? Boundary::Isolated : Boundary::Periodic;
        ImGui::SliderFloat("소프트닝", &app.cfg.softeningCells, 0.5f, 6.0f, "%.1f 셀");
    }

    // ---------------- 3. 가스 ----------------
    if (ImGui::CollapsingHeader("가스")) {
        ImGui::Checkbox("압력", &app.cfg.pressureEnabled);
        ImGui::SliderFloat("압력 세기", &app.cfg.pressureK, 0.0f, 2.0f, "%.2f");
        ImGui::SliderFloat("단열지수 γ", &app.cfg.gamma, 1.0f, 2.5f, "%.2f");
        ImGui::Checkbox("온도 추적", &app.cfg.temperatureEnabled);
        ImGui::Checkbox("복사 냉각", &app.cfg.coolingEnabled);
        ImGui::SliderFloat("냉각률", &app.cfg.coolingRate, 0.0f, 1.0f, "%.2f");
        ImGui::Checkbox("별 형성", &app.cfg.starFormationEnabled);
        ImGui::SliderFloat("임계 밀도", &app.cfg.starDensityThreshold, 1.0f, 400.0f, "%.0f");
        ImGui::SliderFloat("임계 온도", &app.cfg.starTempThreshold, 0.0f, 1.0f, "%.3f");
        if (app.cfg.starFormationEnabled) {
            ImGui::Text("별 %d 개 (%.1f%%)", app.sim.starCount(),
                        app.sim.activeCount() > 0
                            ? 100.0 * app.sim.starCount() / app.sim.activeCount() : 0.0);
        }
        SectionNote("별은 밀도와 온도가 둘 다 임계를 넘어야 생긴다. 하나만 보면 뜨겁고 조밀한 충격파면에서 잘못 생긴다.");
    }

    // ---------------- 4. 우주 ----------------
    if (ImGui::CollapsingHeader("우주")) {
        const bool periodic = (app.cfg.boundary == Boundary::Periodic);
        // 팽창은 주기 경계에서만 물리적 의미가 있다. 고립이면 자동으로 잠근다(design.md O-우주).
        ImGui::BeginDisabled(!periodic);
        ImGui::Checkbox("우주 팽창", &app.cfg.expansionEnabled);
        ImGui::SliderFloat("허블 상수", &app.cfg.hubble, 0.0f, 1.0f, "%.2f");
        ImGui::EndDisabled();
        if (!periodic) {
            app.cfg.expansionEnabled = false;
            SectionNote("고립 경계에서는 팽창이 잠긴다. 경계를 주기로 바꾸면 열린다.");
        }
    }

    // ---------------- 5. 표시 ----------------
    if (ImGui::CollapsingHeader("표시", ImGuiTreeNodeFlags_DefaultOpen)) {
        const char* modeItems[] = { "밀도 필드", "파티클 점" };
        int modeIdx = (app.view.mode == RenderMode::DensityField) ? 0 : 1;
        if (ImGui::Combo("렌더 모드", &modeIdx, modeItems, 2))
            app.view.mode = (modeIdx == 0) ? RenderMode::DensityField : RenderMode::Points;

        const char* colorItems[] = { "밀도", "온도", "속도" };
        int cIdx = (int)app.view.colorBy;
        if (ImGui::Combo("색 기준", &cIdx, colorItems, 3)) app.view.colorBy = (ColorBy)cIdx;
        const char* cmapItems[] = { "천체", "흑백", "열화상" };
        int cmIdx = (int)app.view.cmap;
        if (ImGui::Combo("컬러맵", &cmIdx, cmapItems, 3)) app.view.cmap = (ColorMap)cmIdx;

        ImGui::SliderFloat("밝기", &app.view.brightness, 0.05f, 8.0f, "%.2f");
        ImGui::SliderFloat("대비", &app.view.gamma, 0.5f, 4.0f, "%.2f");
        ImGui::Checkbox("HUD 표시", &app.view.showHud);
    }

    // ---------------- 6. 마우스 도구 ----------------
    if (ImGui::CollapsingHeader("마우스 도구", ImGuiTreeNodeFlags_DefaultOpen)) {
        const char* toolItems[] = { "카메라 (줌·팬)", "가스 뿌리기", "중력 우물", "형태 추가", "지우개" };
        int t = (int)app.tool;
        if (ImGui::Combo("도구", &t, toolItems, 5)) app.tool = (Tool)t;

        ImGui::SliderFloat("브러시 크기", &app.brush.radius, 0.005f, 0.25f, "%.3f");
        ImGui::SliderFloat("브러시 세기", &app.brush.strength, 0.02f, 2.0f, "%.2f");

        const char* shapes[] = { "회전 원반", "정지 덩어리", "가스 고리" };
        int sk = (int)app.brush.shapeKind;
        if (ImGui::Combo("형태", &sk, shapes, 3)) app.brush.shapeKind = (ShapeKind)sk;
        ImGui::SliderFloat("형태 반지름", &app.brush.shapeRadius, 0.01f, 0.4f, "%.2f");
        int sn = app.brush.shapeCount / 10000;
        if (ImGui::SliderInt("형태 파티클", &sn, 1, 100, "%d만")) app.brush.shapeCount = sn * 10000;
        ImGui::Checkbox("궤도속도 자동", &app.brush.autoOrbit);

        // 남은 빈 슬롯을 보여준다 — 다 차면 형태를 더 못 넣는다.
        const int room = app.sim.particleCount() - app.sim.activeCount();
        ImGui::Text("살아있는 파티클 %d / 빈 슬롯 %d", app.sim.activeCount(), room);
        if (room < app.brush.shapeCount) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
            ImGui::TextWrapped("빈 슬롯이 모자라 %d 개만 들어갑니다", room);
            ImGui::PopStyleColor();
        }
        SectionNote("화면을 클릭해 보세요. 형태 추가는 누를 때 한 번 들어가고, 뿌리기·우물·지우개는 드래그하는 동안 계속 먹습니다.");
    }

    // ---------------- 7. 프리셋 ----------------
    if (ImGui::CollapsingHeader("프리셋", ImGuiTreeNodeFlags_DefaultOpen)) {
        const Preset order[5] = { Preset::SpiralDisk, Preset::TidalPair, Preset::HeadOnShock,
                                  Preset::CosmicWeb, Preset::Empty };
        for (int i = 0; i < 5; ++i) {
            const bool sel = (app.cfg.preset == order[i]);
            if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
            if (ImGui::Button(PresetName(order[i]), ImVec2(138, 0))) {
                // 경계·압력·팽창을 시나리오에 맞게 함께 바꾼다(App.cpp 의 공통 규칙)
                ApplyPresetDefaults(app.cfg, order[i]);
                // 순서가 중요하다 — 코어에 새 프리셋을 넘긴 뒤에 초기조건을 다시 만든다.
                // 전에는 reset() 이 먼저라 옛 프리셋으로 배치됐다(round-06 리뷰 P1 #3).
                app.applyConfig();
                app.sim.reset();
                app.running = true;
            }
            if (sel) ImGui::PopStyleColor();
            if (i % 2 == 0 && i < 4) ImGui::SameLine();
        }
        SectionNote("프리셋을 고르면 경계 조건이 그 시나리오에 맞게 함께 바뀐다.");
    }

    // ---------------- 8. 녹화 ----------------
    if (ImGui::CollapsingHeader("녹화")) {
        if (ImGui::Button("📷 스냅샷 저장", ImVec2(-1, 0))) app.snapshotRequested = true;

        if (app.recording) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.48f, 0.16f, 0.16f, 1.0f));
            if (ImGui::Button("⏹ 녹화 정지", ImVec2(-1, 0))) app.recording = false;
            ImGui::PopStyleColor();
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.29f, 0.29f, 1.0f));
            ImGui::Text("● 녹화 중 · %d 프레임", app.recordedFrames);
            ImGui::PopStyleColor();
        } else {
            if (ImGui::Button("⏺ 녹화 시작", ImVec2(-1, 0))) {
                app.recording = true;
                app.recordedFrames = 0;
                app.frameCounter = 0;
            }
            if (app.recordedFrames > 0)
                ImGui::TextDisabled("마지막 녹화: %d 프레임", app.recordedFrames);
        }
        // 저장이 실패하면 알린다. 조용히 넘어가면 사용자는 파일이 생긴 줄 알고 나중에야 빈 폴더를 본다.
        if (app.lastSaveFailed) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.92f, 0.35f, 0.30f, 1.0f));
            ImGui::TextWrapped("마지막 저장이 실패했습니다 — captures 폴더의 여유 공간과 쓰기 권한을 확인해 주세요.");
            ImGui::PopStyleColor();
            if (ImGui::SmallButton("안내 지우기")) app.lastSaveFailed = false;
        }
        ImGui::SliderInt("프레임 간격", &app.recordEvery, 1, 10, "%d 프레임마다");
        const char* fmt[] = { "PNG 시퀀스" };
        int f = 0;
        ImGui::Combo("출력 형식", &f, fmt, 1);
        SectionNote("captures/ 폴더에 저장한다. 동영상 인코더를 앱에 넣지 않으므로 합치기는 외부 도구로 한다.");
    }

    // ---------------- 9. 성능 ----------------
    if (ImGui::CollapsingHeader("성능", ImGuiTreeNodeFlags_DefaultOpen)) {
        SimTimings t = app.sim.timings();
        ImGui::Text("프레임 %.2f ms / 예산 16.7 ms", app.frameMs);

        // 예산 대비 막대. 넘치면 색이 바뀌어 눈에 띈다.
        float frac = app.frameMs / 16.7f;
        ImVec4 barCol = (frac < 0.7f) ? ImVec4(0.37f, 0.76f, 0.48f, 1.f)
                      : (frac < 1.0f) ? ImVec4(0.88f, 0.64f, 0.29f, 1.f)
                                      : ImVec4(0.88f, 0.42f, 0.35f, 1.f);
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, barCol);
        ImGui::ProgressBar(frac > 1.f ? 1.f : frac, ImVec2(-1, 8), "");
        ImGui::PopStyleColor();

        ImGui::Text("산란 %.3f   FFT %.3f", t.scatterMs, t.poissonMs);
        ImGui::Text("보간 %.3f   가스 %.3f", t.gatherMs, t.gasMs);
        ImGui::Text("스텝 합계 %.3f ms", t.totalMs);
        // 배속을 올리면 한 프레임에 여러 스텝을 돈다. 위 항목은 스텝 하나의 시간이라
        // 그 곱이 프레임에 실린 계산량이 된다.
        if (app.stepsLastFrame > 1)
            ImGui::Text("프레임당 스텝 %d 회 (배속 %.1fx)", app.stepsLastFrame, app.cfg.timeScale);
        ImGui::Separator();
        ImGui::Text("파티클 %d", app.sim.particleCount());
        ImGui::Text("격자 %d²", app.sim.gridSize());
        ImGui::Text("VRAM 여유 %.0f MB", Sim::deviceFreeBytes() / 1048576.0);
        SectionNote("산란·FFT·보간 항목은 총 시간을 설계 예산 비율로 나눈 근사다. 총 시간은 실측이다.");
    }

    ImGui::End();
}

void DrawToolbar(App& app, int viewW, int viewH) {
    const char* labels[5] = { "카메라", "뿌리기", "중력우물", "형태추가", "지우개" };
    const float w = 5 * 78.0f + 16.0f, h = 44.0f;
    ImGui::SetNextWindowPos(ImVec2(viewW * 0.5f - w * 0.5f, (float)viewH - h - 14.0f),
                            ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(6, 6));
    ImGui::Begin("##toolbar", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings);
    for (int i = 0; i < 5; ++i) {
        const bool sel = ((int)app.tool == i);
        if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button(labels[i], ImVec2(72, 30))) app.tool = (Tool)i;
        if (sel) ImGui::PopStyleColor();
        if (i < 4) ImGui::SameLine();
    }
    ImGui::End();
    ImGui::PopStyleVar();
}
