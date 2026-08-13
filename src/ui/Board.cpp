#include "ui/Board.h"

#include "imgui.h"
#include <cstdio>

namespace {

void SectionNote(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.55f, 0.55f, 0.60f, 1.0f));
    ImGui::TextWrapped("%s", text);
    ImGui::PopStyleColor();
}

// 바로 앞에 그린 항목에 설명을 붙인다. 마우스를 올리면 뜬다.
//
// 왜 필요한가: 항목 이름이 대부분 물리 용어라("소프트닝"·"단열지수"·"허블 상수")
// 그 분야를 모르면 무엇을 만지는 건지 알 수 없다. 실측 피드백(2026-08-13):
// 사용자가 앱을 켜고 "뭐가 무슨 기능인지 하나도 모르겠어" — 이름만으로는 못 쓴다.
// 설명은 전문 용어를 빼고, 그 값을 올리면/내리면 화면이 어떻게 달라지는지로 쓴다.
void Help(const char* text) {
    if (!ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) return;
    ImGui::BeginTooltip();
    ImGui::PushTextWrapPos(ImGui::GetFontSize() * 24.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::EndTooltip();
}

// 섹션 제목 옆에 붙이는 물음표. 헤더 자체에 툴팁을 걸면 접기/펼치기와 겹쳐 성가시다.
void HelpMark(const char* text) {
    ImGui::SameLine();
    ImGui::TextDisabled("(?)");
    Help(text);
}

const char* PresetName(Preset p) {
    switch (p) {
        case Preset::SpiralDisk:  return "나선 은하";
        case Preset::TidalPair:   return "은하 충돌";
        case Preset::HeadOnShock: return "정면 충돌";
        case Preset::CosmicWeb:   return "우주 거미줄";
        default:                  return "빈 우주";
    }
}

// 개수를 고르는 줄 — 슬라이더로 끌거나 숫자를 직접 쳐 넣는다.
//
// 값은 만 단위로 다룬다. 3000만을 숫자로 치려면 0 을 여덟 번 세야 하는데, 만 단위면 3000 이다.
// 슬라이더는 **손을 뗐을 때** 한 번만 적용한다 — 끄는 동안 매 프레임 적용하면 지나치는 값마다
// 수 GB 메모리를 다시 잡아 그래픽 드라이버가 넘어간다(2026-08-13 실측).
// 반환값: 값이 확정됐으면 true.
bool CountRow(const char* label, int* valueMan, int minMan, int maxMan, int* dragCache) {
    bool committed = false;

    if (*dragCache < 0 || !ImGui::IsAnyItemActive()) *dragCache = *valueMan;

    // 라벨을 위 줄에 둔다. 슬라이더 오른쪽에 붙이면 보드 폭(330)에 안 들어가 글자가 잘린다.
    ImGui::TextUnformatted(label);
    ImGui::PushID(label);
    ImGui::SetNextItemWidth(-74.0f);
    ImGui::SliderInt("##slider", dragCache, minMan, maxMan, "%d만",
                     ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_Logarithmic);
    if (ImGui::IsItemDeactivatedAfterEdit()) committed = true;

    ImGui::SameLine();
    ImGui::SetNextItemWidth(66.0f);
    if (ImGui::InputInt("##typed", dragCache, 0, 0, ImGuiInputTextFlags_EnterReturnsTrue))
        committed = true;
    Help("숫자를 직접 쳐 넣을 수 있습니다. 단위는 만 개입니다 — 3000 을 넣으면 3000만 개입니다.\n"
         "입력 후 Enter 를 누르세요.");
    ImGui::PopID();

    if (committed) {
        if (*dragCache < minMan) *dragCache = minMan;
        if (*dragCache > maxMan) *dragCache = maxMan;
        *valueMan = *dragCache;
    }
    return committed;
}

} // namespace

void DrawBoard(App& app, bool& boardOpen) {
    if (!boardOpen) return;

    ImGuiIO& io = ImGui::GetIO();
    const float boardW = 330.0f;
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - boardW, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(boardW, io.DisplaySize.y), ImGuiCond_Always);
    ImGui::Begin("설정", nullptr,
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBringToFrontOnFocus);

    if (ImGui::Button("◂ 접기")) boardOpen = false;
    Help("설정을 접습니다. 화면 전체를 감추려면 Tab 키를 누르세요.");
    ImGui::SameLine();
    ImGui::TextDisabled("Tab: 화면만 보기");
    ImGui::Separator();

    // ---------------- 1. 장면 ----------------
    if (ImGui::CollapsingHeader("장면", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("미리 만들어 둔 우주입니다. 누르면 그 장면이 처음부터 시작합니다.");
        const char* sceneHelp[5] = {
            "은하 하나가 돌면서 나선 팔을 만듭니다. 가장 기본이 되는 장면입니다.",
            "은하 두 개가 서로를 스치고 지나가며 긴 꼬리를 남깁니다.",
            "가스 덩어리 두 개가 정면으로 부딪혀 경계선이 서고 달아오릅니다. "
            "「보기」를 온도로 바꾸면 뜨거워지는 것이 색으로 보입니다.",
            "우주에 물질을 고루 뿌려 두면 스스로 실 같은 거미줄 구조가 자랍니다. "
            "오래 걸리니 시간을 빠르게 해서 보세요.",
            "아무것도 없는 우주입니다. 아래 「만들기」로 직접 놓아 보세요.",
        };
        const Preset order[5] = { Preset::SpiralDisk, Preset::TidalPair, Preset::HeadOnShock,
                                  Preset::CosmicWeb, Preset::Empty };
        for (int i = 0; i < 5; ++i) {
            const bool sel = (app.cfg.preset == order[i]);
            if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
            if (ImGui::Button(PresetName(order[i]), ImVec2(148, 0))) {
                ApplyPresetDefaults(app.cfg, order[i]);
                // 순서가 중요하다 — 코어에 새 장면을 넘긴 뒤에 배치를 다시 만든다.
                app.applyConfig();
                app.sim.reset();
                app.running = true;
            }
            Help(sceneHelp[i]);
            if (sel) ImGui::PopStyleColor();
            if (i % 2 == 0 && i < 4) ImGui::SameLine();
        }
    }

    // ---------------- 2. 만들기 ----------------
    if (ImGui::CollapsingHeader("만들기", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("모양을 고르고 화면을 클릭하면 그 자리에 놓입니다. "
                 "아래 도구 막대에서 「놓기」가 골라져 있어야 합니다.");

        const char* shapeNames[5] = { "은하", "태양", "고리", "구름", "덩어리" };
        const char* shapeHelp[5] = {
            "도는 원반입니다. 놓는 자리의 중력에 맞는 속도가 들어가 모양을 유지하며 돕니다.",
            "가운데로 갈수록 빽빽하고 뜨겁습니다. 별 하나처럼 보입니다.",
            "가운데가 빈 도넛입니다. 돌면서 안쪽으로 무너져 들어갑니다.",
            "넓고 성기게 퍼진 차가운 성운입니다. 속도 없이 놓여 천천히 뭉칩니다.",
            "고르게 찬 공입니다. 속도 없이 놓여 그대로 무너져 내립니다.",
        };
        for (int i = 0; i < 5; ++i) {
            const bool sel = ((int)app.brush.shapeKind == i);
            if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
            if (ImGui::Button(shapeNames[i], ImVec2(58, 0))) {
                app.brush.shapeKind = (ShapeKind)i;
                app.tool = Tool::AddShape;      // 모양을 고르면 바로 놓을 수 있게
            }
            Help(shapeHelp[i]);
            if (sel) ImGui::PopStyleColor();
            if (i < 4) ImGui::SameLine();
        }

        ImGui::SliderFloat("크기", &app.brush.shapeRadius, 0.01f, 0.4f, "%.2f");
        Help("놓을 덩어리의 크기입니다.");

        // 한 번에 놓을 개수 — 1만 개부터 현재 정한 최대치까지.
        int shapeMan = app.brush.shapeCount / 10000;
        if (shapeMan < 1) shapeMan = 1;
        const int capMan = (app.cfg.particleCount / 10000) > 1 ? (app.cfg.particleCount / 10000) : 1;
        if (shapeMan > capMan) shapeMan = capMan;
        if (CountRow("한 번에 놓을 개수", &shapeMan, 1, capMan, &app.shapeCountSlider))
            app.brush.shapeCount = shapeMan * 10000;
        SectionNote("자리가 모자라면 먼저 놓은 것부터 밀려납니다 — 최대 개수를 넘지 않습니다.");

        const int alive = app.sim.activeCount();
        ImGui::Text("지금 화면에 %d 개 / 최대 %d 개", alive, app.sim.particleCount());
    }

    // ---------------- 3. 시간 ----------------
    if (ImGui::CollapsingHeader("시간", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("시간을 멈추거나 빠르게 흘립니다.");
        if (ImGui::Button(app.running ? "⏸ 멈춤" : "▶ 재생", ImVec2(96, 0)))
            app.running = !app.running;
        Help("시간을 멈추거나 다시 흐르게 합니다.");
        ImGui::SameLine();
        if (ImGui::Button("⏭ 한 칸", ImVec2(84, 0))) { app.running = false; app.stepOnce = true; }
        Help("딱 한 칸만 진행합니다. 천천히 뜯어볼 때 씁니다.");
        ImGui::SameLine();
        if (ImGui::Button("↺ 처음", ImVec2(84, 0))) {
            app.applyConfig();
            app.sim.reset();
        }
        Help("지금 장면을 처음 상태로 되돌립니다.");

        ImGui::SliderFloat("빠르기", &app.cfg.timeScale, 0.1f, 4.0f, "%.1f 배");
        // 1배를 넘는 배속은 한 프레임에 여러 번 계산해서 내므로 정수만 뜻이 있다.
        if (app.cfg.timeScale > 1.0f) app.cfg.timeScale = (float)(int)(app.cfg.timeScale + 0.5f);
        Help("1보다 내리면 느리게, 올리면 빠르게 흐릅니다.\n\n"
             "빠르게 하면 한 화면에 여러 번 계산하므로 그만큼 무거워집니다. "
             "느리게 하는 쪽은 공짜입니다.");
    }

    // ---------------- 4. 보기 ----------------
    if (ImGui::CollapsingHeader("보기", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("무엇을 색으로 나타낼지 고릅니다.");
        const bool isDensity = (app.look == App::Look::Density);
        if (isDensity) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button("밀도로 보기", ImVec2(148, 0))) { app.look = App::Look::Density; ApplyLook(app); }
        Help("얼마나 빽빽하게 모였는지를 밝기로 보여줍니다. 은하 구조를 볼 때 좋습니다.");
        if (isDensity) ImGui::PopStyleColor();
        ImGui::SameLine();
        if (!isDensity) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button("온도로 보기", ImVec2(148, 0))) { app.look = App::Look::Temperature; ApplyLook(app); }
        Help("얼마나 뜨거운지를 색으로 보여줍니다. 부딪히는 자리가 달아오르는 것이 보입니다.");
        if (!isDensity) ImGui::PopStyleColor();

        ImGui::Checkbox("점으로 그리기", &app.pointsMode);
        Help("끄면 부드러운 안개처럼, 켜면 알갱이 하나하나를 점으로 그립니다. "
             "점으로 그리면 낱개가 보이고 안개로 그리면 전체 구조가 잘 보입니다.");
        app.view.mode = app.pointsMode ? RenderMode::Points : RenderMode::DensityField;

        ImGui::SliderFloat("밝기", &app.view.brightness, 0.05f, 8.0f, "%.2f");
        Help("어두운 바깥쪽 구조가 안 보이면 올려 보세요.");

        if (ImGui::Button("화면만 보기 (Tab)", ImVec2(-1, 0))) app.uiHidden = true;
        Help("설정과 표시를 모두 감춥니다. Tab 키를 누르면 돌아옵니다. 녹화할 때 쓰세요.");
    }

    // ---------------- 5. 녹화 ----------------
    if (ImGui::CollapsingHeader("녹화", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("화면을 그림 파일로 남깁니다. 실행 파일 옆 captures 폴더에 저장됩니다.");
        if (ImGui::Button("📷 지금 화면 저장", ImVec2(-1, 0))) app.snapshotRequested = true;
        Help("지금 보이는 화면을 그림 한 장으로 저장합니다.");

        if (app.recording) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.48f, 0.16f, 0.16f, 1.0f));
            if (ImGui::Button("⏹ 녹화 정지", ImVec2(-1, 0))) app.recording = false;
            ImGui::PopStyleColor();
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.29f, 0.29f, 1.0f));
            ImGui::Text("● 녹화 중 · %d 장", app.recordedFrames);
            ImGui::PopStyleColor();
        } else {
            if (ImGui::Button("⏺ 녹화 시작", ImVec2(-1, 0))) {
                app.recording = true;
                app.recordedFrames = 0;
                app.frameCounter = 0;
            }
            Help("정지할 때까지 화면을 계속 그림으로 남깁니다. 한 장씩 따로 저장되므로 "
                 "동영상으로 만들려면 나중에 다른 프로그램으로 합치면 됩니다.\n\n"
                 "한 장이 약 5 MB 라 금방 쌓입니다 — 필요한 구간만 짧게 찍는 편이 좋습니다.");
            if (app.recordedFrames > 0)
                ImGui::TextDisabled("마지막 녹화: %d 장", app.recordedFrames);
        }
        if (app.lastSaveFailed) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.92f, 0.35f, 0.30f, 1.0f));
            ImGui::TextWrapped("저장이 실패했습니다 — captures 폴더의 빈 공간과 쓰기 권한을 확인해 주세요.");
            ImGui::PopStyleColor();
            if (ImGui::SmallButton("안내 지우기")) app.lastSaveFailed = false;
        }
    }

    // ---------------- 6. 한도 ----------------
    if (ImGui::CollapsingHeader("한도", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("화면에 둘 수 있는 알갱이의 최대 개수입니다. 이 수를 넘지 않도록 "
                 "먼저 놓은 것부터 자동으로 밀려납니다.");
        int maxMan = app.cfg.particleCount / 10000;
        if (maxMan < 1) maxMan = 1;
        // 3000만이 상한이다. 그 위로는 이 그래픽카드에서 안정적으로 돌지 않는다.
        if (CountRow("최대 개수", &maxMan, 1, 3000, &app.particleSlider))
            app.cfg.particleCount = maxMan * 10000;
        SectionNote("1000만 개까지가 넉넉합니다. 그 위로는 화면이 느려집니다.");

        if (app.sim.particleCount() < app.cfg.particleCount) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
            ImGui::TextWrapped("그래픽 메모리가 모자라 %d 개로 줄였습니다 (요청 %d)",
                               app.sim.particleCount(), app.cfg.particleCount);
            ImGui::PopStyleColor();
            if (ImGui::SmallButton("줄인 값으로 맞추기"))
                app.cfg.particleCount = app.sim.particleCount();
        }
        if (app.cfg.particleCount > 20000000) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
            ImGui::TextWrapped("2000만이 넘습니다 — 다른 무거운 프로그램은 닫아 두세요.");
            ImGui::PopStyleColor();
        }
        ImGui::TextDisabled("초당 %.0f 장 · 그래픽 메모리 여유 %.0f MB",
                            app.fps, Sim::deviceFreeBytes() / 1048576.0);
        Help("초당 장 수가 60 아래로 떨어지면 최대 개수를 낮춰 보세요.");
    }

    // ---------------- 고급 (평소엔 접혀 있다) ----------------
    ImGui::Separator();
    if (ImGui::CollapsingHeader("고급 설정")) {
        SectionNote("여기 값들은 장면에 맞춰 자동으로 정해집니다. 직접 만져 보고 싶을 때만 여세요.");

        if (ImGui::TreeNode("중력")) {
            ImGui::SliderFloat("중력 세기", &app.cfg.gravity, 0.0f, 2.0f, "%.2f");
            Help("서로 끌어당기는 힘입니다. 0 이면 아무도 안 끌어당기고, 올릴수록 빨리 뭉칩니다.");
            const char* lawItems[] = { "1/r² (3D형)", "1/r (진짜 2D)" };
            int lawIdx = (app.cfg.law == GravityLaw::InverseSquare) ? 0 : 1;
            if (ImGui::Combo("힘 공식", &lawIdx, lawItems, 2))
                app.cfg.law = (lawIdx == 0) ? GravityLaw::InverseSquare : GravityLaw::InverseR;
            Help("거리가 멀어질 때 힘이 얼마나 빨리 약해지는지입니다. 3D형이 우리 우주와 같습니다.");
            const char* bndItems[] = { "고립 (은하)", "주기 (우주론)" };
            int bndIdx = (app.cfg.boundary == Boundary::Isolated) ? 0 : 1;
            if (ImGui::Combo("경계 조건", &bndIdx, bndItems, 2))
                app.cfg.boundary = (bndIdx == 0) ? Boundary::Isolated : Boundary::Periodic;
            Help("화면 바깥이 텅 빈 우주인지(고립), 반대편으로 이어지는지(주기)입니다.");
            ImGui::SliderFloat("소프트닝", &app.cfg.softeningCells, 0.5f, 6.0f, "%.1f 셀");
            Help("아주 가까이 붙은 알갱이끼리 힘이 치솟는 것을 막는 뭉툭함입니다.");
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("가스")) {
            ImGui::Checkbox("압력", &app.cfg.pressureEnabled);
            Help("가스가 서로를 밀어냅니다. 끄면 중력만 남아 한 점으로 무너집니다.");
            ImGui::SliderFloat("압력 세기", &app.cfg.pressureK, 0.0f, 2.0f, "%.2f");
            ImGui::SliderFloat("단열지수", &app.cfg.gamma, 1.0f, 2.5f, "%.2f");
            Help("가스를 누를 때 얼마나 뻣뻣하게 버티는지입니다. 공기는 대략 1.4 입니다.");
            ImGui::Checkbox("온도 추적", &app.cfg.temperatureEnabled);
            ImGui::Checkbox("복사 냉각", &app.cfg.coolingEnabled);
            Help("가스가 빛을 내며 식습니다. 식으면 더 잘 뭉칩니다.");
            ImGui::SliderFloat("냉각률", &app.cfg.coolingRate, 0.0f, 1.0f, "%.2f");
            ImGui::Checkbox("별 만들기", &app.cfg.starFormationEnabled);
            Help("충분히 빽빽하고 차가워진 가스를 별로 바꿉니다.");
            ImGui::SliderFloat("임계 밀도", &app.cfg.starDensityThreshold, 1.0f, 400.0f, "%.0f");
            ImGui::SliderFloat("임계 온도", &app.cfg.starTempThreshold, 0.0f, 1.0f, "%.3f");
            if (app.cfg.starFormationEnabled) {
                ImGui::Text("별 %d 개 (%.1f%%)", app.sim.starCount(),
                            app.sim.activeCount() > 0
                                ? 100.0 * app.sim.starCount() / app.sim.activeCount() : 0.0);
            }
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("우주")) {
            const bool periodic = (app.cfg.boundary == Boundary::Periodic);
            ImGui::BeginDisabled(!periodic);
            ImGui::Checkbox("우주 팽창", &app.cfg.expansionEnabled);
            Help("공간이 늘어나 물질을 서로 멀어지게 합니다. 중력과 겨루어 거미줄 구조를 만듭니다.");
            ImGui::SliderFloat("허블 상수", &app.cfg.hubble, 0.0f, 1.0f, "%.2f");
            ImGui::EndDisabled();
            if (!periodic) {
                app.cfg.expansionEnabled = false;
                SectionNote("고립 경계에서는 잠깁니다. 경계를 주기로 바꾸면 열립니다.");
            }
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("계산")) {
            const char* gridItems[] = { "1024²", "2048²", "4096²" };
            int gridIdx = (app.cfg.gridSize == 1024) ? 0 : (app.cfg.gridSize == 2048) ? 1 : 2;
            if (ImGui::Combo("격자 해상도", &gridIdx, gridItems, 3))
                app.cfg.gridSize = (gridIdx == 0) ? 1024 : (gridIdx == 1) ? 2048 : 4096;
            Help("중력을 계산할 눈금의 촘촘함입니다. 촘촘할수록 세밀하고 느립니다.");
            ImGui::SliderInt("정렬 주기", &app.cfg.sortInterval, 1, 120, "%d 칸");
            Help("속도를 위한 항목입니다 — 그림은 달라지지 않습니다. 40 근처가 가장 빠릅니다.");
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("표시 세부")) {
            const char* cmapItems[] = { "천체", "흑백", "열화상" };
            int cmIdx = (int)app.view.cmap;
            if (ImGui::Combo("컬러맵", &cmIdx, cmapItems, 3)) app.view.cmap = (ColorMap)cmIdx;
            const char* colorItems[] = { "밀도", "온도", "속도" };
            int cIdx = (int)app.view.colorBy;
            if (ImGui::Combo("색 기준", &cIdx, colorItems, 3)) app.view.colorBy = (ColorBy)cIdx;
            Help("「보기」에서 고른 것을 덮어씁니다. 속도로 보면 은하가 도는 모습이 잘 보입니다.");
            ImGui::SliderFloat("대비", &app.view.gamma, 0.5f, 4.0f, "%.2f");
            ImGui::Checkbox("상태 표시", &app.view.showHud);
            ImGui::SliderInt("녹화 간격", &app.recordEvery, 1, 10, "%d 장마다");
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("마우스")) {
            ImGui::SliderFloat("브러시 크기", &app.brush.radius, 0.005f, 0.25f, "%.3f");
            Help("뿌리기·끌기·지우개가 한 번에 닿는 동그라미 크기입니다.");
            ImGui::SliderFloat("브러시 세기", &app.brush.strength, 0.02f, 2.0f, "%.2f");
            ImGui::Checkbox("놓을 때 도는 속도 주기", &app.brush.autoOrbit);
            Help("끄면 속도 없이 놓여 그대로 무너집니다.");
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("성능")) {
            SimTimings t = app.sim.timings();
            ImGui::Text("한 장 %.2f ms / 예산 16.7 ms", app.frameMs);
            float frac = app.frameMs / 16.7f;
            ImVec4 barCol = (frac < 0.7f) ? ImVec4(0.37f, 0.76f, 0.48f, 1.f)
                          : (frac < 1.0f) ? ImVec4(0.88f, 0.64f, 0.29f, 1.f)
                                          : ImVec4(0.88f, 0.42f, 0.35f, 1.f);
            ImGui::PushStyleColor(ImGuiCol_PlotHistogram, barCol);
            ImGui::ProgressBar(frac > 1.f ? 1.f : frac, ImVec2(-1, 8), "");
            ImGui::PopStyleColor();
            ImGui::Text("산란 %.3f   FFT %.3f", t.scatterMs, t.poissonMs);
            ImGui::Text("보간 %.3f   가스 %.3f", t.gatherMs, t.gasMs);
            ImGui::Text("계산 합계 %.3f ms", t.totalMs);
            if (app.stepsLastFrame > 1)
                ImGui::Text("한 장에 %d 번 계산 (빠르기 %.1f배)", app.stepsLastFrame, app.cfg.timeScale);
            ImGui::Text("격자 %d²", app.sim.gridSize());
            ImGui::TreePop();
        }
    }

    ImGui::End();
}

void DrawToolbar(App& app, int viewW, int viewH) {
    const char* labels[5] = { "카메라", "놓기", "뿌리기", "끌기", "지우개" };
    // 화면 아래 단추에도 설명을 붙인다 — 설정을 접어 둔 채로 쓰는 사람이 여기부터 만난다.
    const char* toolHelp[5] = {
        "화면을 끌어 이동하고 마우스 휠로 확대·축소합니다.",
        "누른 자리에 「만들기」에서 고른 모양을 놓습니다. 누를 때 한 번만 들어갑니다.",
        "끄는 동안 그 자리 가스를 바깥으로 밀어냅니다.",
        "끄는 동안 보이지 않는 무거운 것을 놓아 물질을 그쪽으로 끌어당깁니다.",
        "끄는 동안 그 자리 알갱이를 지웁니다.",
    };
    // 화면 순서와 Tool 값의 순서가 다르다 — 자주 쓰는 「놓기」를 앞으로 뺐다.
    const Tool order[5] = { Tool::Camera, Tool::AddShape, Tool::Spray, Tool::Well, Tool::Erase };

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
        const bool sel = (app.tool == order[i]);
        if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button(labels[i], ImVec2(72, 30))) app.tool = order[i];
        if (ImGui::IsItemHovered()) {
            ImGui::BeginTooltip();
            ImGui::PushTextWrapPos(ImGui::GetFontSize() * 22.0f);
            ImGui::TextUnformatted(toolHelp[i]);
            ImGui::PopTextWrapPos();
            ImGui::EndTooltip();
        }
        if (sel) ImGui::PopStyleColor();
        if (i < 4) ImGui::SameLine();
    }
    ImGui::End();
    ImGui::PopStyleVar();
}
