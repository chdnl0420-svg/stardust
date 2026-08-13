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

// 바로 앞에 그린 항목에 설명을 붙인다. 마우스를 올리면 뜬다.
//
// 왜 필요한가: 이 보드의 항목 이름은 대부분 물리 용어라("소프트닝"·"단열지수"·"허블 상수")
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
        HelpMark("돌리고 멈추고 되돌리는 곳. 처음이라면 아래 「프리셋」에서 장면부터 골라 보세요.");
        if (ImGui::Button(app.running ? "⏸ 일시정지" : "▶ 재생")) app.running = !app.running;
        Help("시간을 멈추거나 다시 흐르게 합니다. 멈춘 동안에도 설정은 바꿀 수 있습니다.");
        ImGui::SameLine();
        if (ImGui::Button("⏭ 한 스텝")) { app.running = false; app.stepOnce = true; }
        Help("딱 한 칸만 진행합니다. 무엇이 어떻게 움직이는지 천천히 볼 때 씁니다.");
        ImGui::SameLine();
        if (ImGui::Button("↺ 리셋")) {
            // 지금 화면에 있는 설정으로 초기조건을 다시 만든다.
            // 코어에 먼저 넘기지 않으면 이번 프레임에 만진 값이 빠진 채로 리셋된다.
            app.applyConfig();
            app.sim.reset();
        }
        Help("지금 설정 그대로 처음 상태로 되돌립니다. 값을 바꾼 뒤 다시 보고 싶을 때 누르세요.");

        // 슬라이더를 **놓았을 때** 한 번만 적용한다.
        // 끄는 동안 매 프레임 적용하면 지나치는 값마다 파티클 버퍼(수 GB)를 해제하고 다시 잡는데,
        // 그 반복이 그래픽 드라이버를 넘어뜨린다(2026-08-13: 100만→3000만으로 끌다가 시스템 재부팅.
        // BugCheck 0xD1 / nvlddmkm.sys). 끄는 동안에는 숫자만 바뀌고 화면은 그대로다.
        if (app.particleSlider < 0 || !ImGui::IsAnyItemActive())
            app.particleSlider = app.cfg.particleCount / 100000;
        ImGui::SliderInt("파티클 수", &app.particleSlider, 1, 300, "%d0만");
        if (ImGui::IsItemDeactivatedAfterEdit())
            app.cfg.particleCount = app.particleSlider * 100000;
        Help("화면에 뿌릴 알갱이 개수입니다. **슬라이더에서 손을 떼면 적용됩니다.**\n\n"
             "많을수록 은하가 촘촘하고 예쁘지만 그만큼 느려지고 그래픽 메모리를 많이 씁니다. "
             "이 그래픽카드에서는 1000만 개가 초당 150장으로 가장 넉넉합니다.\n\n"
             "2000만을 넘겨 쓸 때는 다른 무거운 프로그램(게임·영상 편집기)을 닫아 두세요.");
        if (app.particleSlider > 200) {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
            ImGui::TextWrapped("2000만이 넘습니다 — 다른 프로그램이 그래픽 메모리를 많이 쓰고 있으면 "
                               "불안정할 수 있습니다.");
            ImGui::PopStyleColor();
        }
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
        Help("중력을 계산할 때 쓰는 눈금의 촘촘함입니다.\n\n"
             "촘촘할수록 작은 덩어리까지 살아나 그림이 세밀해지고, 그만큼 느려집니다. "
             "넓은 구조를 볼 때는 1024, 세부를 볼 때는 4096 이 어울립니다.");

        ImGui::SliderFloat("시간 배속", &app.cfg.timeScale, 0.1f, 4.0f, "%.1fx");
        Help("빨리감기 / 느리게 보기입니다.\n\n"
             "1보다 내리면 시간이 천천히 흘러 충돌 순간을 자세히 볼 수 있습니다. "
             "1보다 올리면 한 장면에 여러 번 계산해 빨리 감는데, 그만큼 무거워집니다.");
        // 1배를 넘는 배속은 프레임당 스텝 횟수로 내므로 정수만 뜻이 있다.
        // 스냅하지 않으면 3.4배속이 조용히 3회로 반올림돼, 슬라이더 값과 실제 진행이 어긋난다.
        if (app.cfg.timeScale > 1.0f) {
            app.cfg.timeScale = (float)(int)(app.cfg.timeScale + 0.5f);
            SectionNote("배속을 1보다 올리면 한 프레임에 스텝을 여러 번 돈다 — 계산량도 그만큼 늘어난다. "
                        "시간 간격은 안정성 한계에 묶여 있으므로 이 구간은 정수 배속만 쓴다.");
        }
        ImGui::SliderInt("정렬 주기", &app.cfg.sortInterval, 1, 120, "%d 스텝");
        Help("속도를 위한 항목입니다 — 그림은 달라지지 않으니 그대로 두셔도 됩니다.\n\n"
             "가까이 있는 알갱이끼리 메모리에서도 가까이 두면 계산이 빨라지는데, "
             "그 정리를 몇 칸마다 할지 정합니다. 40 근처가 가장 빠릅니다.");
    }

    // ---------------- 2. 중력 ----------------
    if (ImGui::CollapsingHeader("중력", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("알갱이들이 서로 끌어당기는 방식입니다. 이 중 「중력 세기」가 화면을 가장 크게 바꿉니다.");
        ImGui::SliderFloat("중력 세기", &app.cfg.gravity, 0.0f, 2.0f, "%.2f");
        Help("서로 끌어당기는 힘의 크기입니다.\n\n"
             "0 으로 두면 아무도 끌어당기지 않아 흩어진 채 떠다닙니다. "
             "올릴수록 빠르게 가운데로 뭉쳐 은하가 됩니다.\n"
             "바꾼 뒤 「리셋」을 누르면 처음부터 그 세기로 다시 볼 수 있습니다.");

        const char* lawItems[] = { "1/r² (3D형)", "1/r (진짜 2D)" };
        int lawIdx = (app.cfg.law == GravityLaw::InverseSquare) ? 0 : 1;
        if (ImGui::Combo("힘 공식", &lawIdx, lawItems, 2)) {
            app.cfg.law = (lawIdx == 0) ? GravityLaw::InverseSquare : GravityLaw::InverseR;
        }
        Help("거리가 멀어질 때 힘이 얼마나 빨리 약해지는지 고릅니다.\n\n"
             "· 3D형 — 우리가 사는 우주와 같은 방식입니다. 평소엔 이쪽입니다.\n"
             "· 진짜 2D — 납작한 세계에서 수학적으로 올바른 답입니다. 멀리서도 힘이 잘 안 약해져 "
             "판 전체가 한 덩어리로 무너집니다. 그 차이를 보고 싶을 때만 고르세요.");

        const char* bndItems[] = { "고립 (은하)", "주기 (우주론)" };
        int bndIdx = (app.cfg.boundary == Boundary::Isolated) ? 0 : 1;
        if (ImGui::Combo("경계 조건", &bndIdx, bndItems, 2))
            app.cfg.boundary = (bndIdx == 0) ? Boundary::Isolated : Boundary::Periodic;
        Help("화면 바깥에 무엇이 있다고 볼지 정합니다.\n\n"
             "· 고립 — 바깥은 텅 빈 우주입니다. 은하 하나를 볼 때 씁니다.\n"
             "· 주기 — 오른쪽 끝으로 나가면 왼쪽 끝에서 다시 들어옵니다. "
             "우주 전체의 한 조각을 보는 셈이라 거대 구조를 볼 때 씁니다.");

        ImGui::SliderFloat("소프트닝", &app.cfg.softeningCells, 0.5f, 6.0f, "%.1f 셀");
        Help("아주 가까이 붙은 알갱이끼리 힘이 치솟는 것을 막는 「뭉툭함」입니다.\n\n"
             "작게 두면 가까운 거리의 힘이 날카로워져 더 세게 뭉치고, "
             "크게 두면 부드러워져 덜 뭉칩니다. 너무 작으면 알갱이가 튕겨 나갑니다.");
    }

    // ---------------- 3. 가스 ----------------
    if (ImGui::CollapsingHeader("가스")) {
        HelpMark("알갱이를 「가스」답게 만드는 곳입니다. 여기를 다 끄면 서로 통과하며 끌어당기기만 하고, "
                 "켜면 부딪히고 달아오르고 식습니다. 「충격파」 프리셋과 함께 보면 차이가 뚜렷합니다.");
        ImGui::Checkbox("압력", &app.cfg.pressureEnabled);
        Help("가스가 서로를 밀어내게 합니다.\n\n"
             "끄면 중력만 남아 한 점으로 계속 무너집니다. 켜면 빽빽해진 곳이 되밀어서 "
             "부딪히는 자리에 뚜렷한 경계선(충격파)이 생깁니다.");
        ImGui::SliderFloat("압력 세기", &app.cfg.pressureK, 0.0f, 2.0f, "%.2f");
        Help("밀어내는 힘의 크기입니다. 올리면 덜 뭉치고 더 부풀어 오릅니다.");
        ImGui::SliderFloat("단열지수 γ", &app.cfg.gamma, 1.0f, 2.5f, "%.2f");
        Help("가스를 누를 때 얼마나 뻣뻣하게 버티는지입니다.\n\n"
             "값이 크면 조금만 눌러도 세게 되밀어 딱딱한 느낌이 나고, "
             "작으면 물렁해서 잘 눌립니다. 공기는 대략 1.4 입니다.");
        ImGui::Checkbox("온도 추적", &app.cfg.temperatureEnabled);
        Help("눌리면 뜨거워지는 성질을 켭니다.\n\n"
             "켠 뒤 「표시」의 색 기준을 온도로 바꾸면 부딪히는 자리가 달아오르는 것이 색으로 보입니다.");
        ImGui::Checkbox("복사 냉각", &app.cfg.coolingEnabled);
        Help("가스가 빛을 내며 열을 잃게 합니다.\n\n"
             "식으면 되미는 힘이 약해져 더 잘 뭉칩니다. 실제 우주에서 별이 태어나는 과정입니다.");
        ImGui::SliderFloat("냉각률", &app.cfg.coolingRate, 0.0f, 1.0f, "%.2f");
        Help("얼마나 빨리 식는지입니다. 올릴수록 빨리 식고 빨리 뭉칩니다.");
        ImGui::Checkbox("별 형성", &app.cfg.starFormationEnabled);
        Help("충분히 빽빽하고 차가워진 가스를 별로 바꿉니다.\n\n"
             "아래 두 조건을 **둘 다** 넘겨야 별이 됩니다. 켜면 개수가 아래에 표시됩니다.");
        ImGui::SliderFloat("임계 밀도", &app.cfg.starDensityThreshold, 1.0f, 400.0f, "%.0f");
        Help("이만큼 빽빽해져야 별이 될 수 있습니다. 낮추면 별이 쉽게 많이 생깁니다.");
        ImGui::SliderFloat("임계 온도", &app.cfg.starTempThreshold, 0.0f, 1.0f, "%.3f");
        Help("이보다 차가워져야 별이 될 수 있습니다. 「복사 냉각」을 켜야 온도가 내려갑니다.");
        if (app.cfg.starFormationEnabled) {
            ImGui::Text("별 %d 개 (%.1f%%)", app.sim.starCount(),
                        app.sim.activeCount() > 0
                            ? 100.0 * app.sim.starCount() / app.sim.activeCount() : 0.0);
        }
        SectionNote("별은 밀도와 온도가 둘 다 임계를 넘어야 생긴다. 하나만 보면 뜨겁고 조밀한 충격파면에서 잘못 생긴다.");
    }

    // ---------------- 4. 우주 ----------------
    if (ImGui::CollapsingHeader("우주")) {
        HelpMark("우주가 부풀어 오르는 효과입니다. 「구조 형성」 프리셋에서만 뜻이 있습니다.");
        const bool periodic = (app.cfg.boundary == Boundary::Periodic);
        // 팽창은 주기 경계에서만 물리적 의미가 있다. 고립이면 자동으로 잠근다(design.md O-우주).
        ImGui::BeginDisabled(!periodic);
        ImGui::Checkbox("우주 팽창", &app.cfg.expansionEnabled);
        Help("공간 자체가 늘어나 물질을 서로 멀어지게 합니다.\n\n"
             "중력은 모으려 하고 팽창은 흩으려 해서, 둘이 겨루는 결과로 거미줄 같은 구조가 만들어집니다. "
             "이것이 실제 우주가 지금 모습이 된 이유입니다.");
        ImGui::SliderFloat("허블 상수", &app.cfg.hubble, 0.0f, 1.0f, "%.2f");
        Help("우주가 부풀어 오르는 속도입니다. 올리면 물질이 뭉칠 새 없이 흩어집니다.");
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
        Help("색으로 무엇을 나타낼지 고릅니다.\n\n"
             "· 밀도 — 얼마나 빽빽한가 (기본)\n"
             "· 온도 — 얼마나 뜨거운가. 「가스」의 온도 추적을 켜야 뜻이 있습니다\n"
             "· 속도 — 얼마나 빨리 움직이는가. 은하가 회전하는 모습이 잘 보입니다");

        const char* cmapItems[] = { "천체", "흑백", "열화상" };
        int cmIdx = (int)app.view.cmap;
        if (ImGui::Combo("컬러맵", &cmIdx, cmapItems, 3)) app.view.cmap = (ColorMap)cmIdx;
        Help("색을 고르는 방식입니다. 천체는 보라·주황, 흑백은 무채색, 열화상은 검정에서 노랑까지 갑니다.");

        ImGui::SliderFloat("밝기", &app.view.brightness, 0.05f, 8.0f, "%.2f");
        Help("화면 전체를 밝게/어둡게 합니다. 옅은 바깥쪽 구조가 안 보이면 올려 보세요.");
        ImGui::SliderFloat("대비", &app.view.gamma, 0.5f, 4.0f, "%.2f");
        Help("밝은 곳과 어두운 곳의 차이를 키우거나 줄입니다. 올리면 또렷하고 내리면 부드럽습니다.");
        ImGui::Checkbox("HUD 표시", &app.view.showHud);
        Help("왼쪽 위의 상태 표시(초당 화면 수·알갱이 개수·경과 시간)를 켜고 끕니다. "
             "화면을 저장할 때 끄면 그림만 남습니다.");
    }

    // ---------------- 6. 마우스 도구 ----------------
    if (ImGui::CollapsingHeader("마우스 도구", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("화면을 직접 클릭해 우주를 만드는 곳입니다. 「프리셋」에서 빈 판을 고른 뒤 "
                 "형태 추가로 직접 은하를 놓아 보세요.");
        const char* toolItems[] = { "카메라 (줌·팬)", "가스 뿌리기", "중력 우물", "형태 추가", "지우개" };
        int t = (int)app.tool;
        if (ImGui::Combo("도구", &t, toolItems, 5)) app.tool = (Tool)t;
        Help("화면을 클릭했을 때 무슨 일이 일어날지 고릅니다. 화면 아래 단추와 같습니다.\n\n"
             "· 카메라 — 끌어서 이동, 휠로 확대\n"
             "· 가스 뿌리기 — 그 자리 가스를 바깥으로 밀어냅니다\n"
             "· 중력 우물 — 보이지 않는 무거운 것을 놓아 물질을 끌어당깁니다\n"
             "· 형태 추가 — 새 덩어리를 놓습니다 (누를 때 한 번)\n"
             "· 지우개 — 그 자리 알갱이를 지웁니다");

        ImGui::SliderFloat("브러시 크기", &app.brush.radius, 0.005f, 0.25f, "%.3f");
        Help("뿌리기·우물·지우개가 한 번에 영향을 주는 동그라미의 크기입니다.");
        ImGui::SliderFloat("브러시 세기", &app.brush.strength, 0.02f, 2.0f, "%.2f");
        Help("뿌리기와 우물의 힘입니다. 올리면 더 세게 밀거나 당깁니다.");

        const char* shapes[] = { "회전 원반", "정지 덩어리", "가스 고리" };
        int sk = (int)app.brush.shapeKind;
        if (ImGui::Combo("형태", &sk, shapes, 3)) app.brush.shapeKind = (ShapeKind)sk;
        Help("「형태 추가」로 놓을 덩어리의 모양입니다.\n\n"
             "· 회전 원반 — 빙글빙글 도는 은하. 모양을 유지합니다\n"
             "· 정지 덩어리 — 가만히 있다가 스스로 무너집니다\n"
             "· 가스 고리 — 가운데가 빈 도넛");
        ImGui::SliderFloat("형태 반지름", &app.brush.shapeRadius, 0.01f, 0.4f, "%.2f");
        Help("놓을 덩어리의 크기입니다.");
        int sn = app.brush.shapeCount / 10000;
        if (ImGui::SliderInt("형태 파티클", &sn, 1, 100, "%d만")) app.brush.shapeCount = sn * 10000;
        Help("한 번 놓을 때 들어갈 알갱이 개수입니다. 아래 「빈 슬롯」보다 많이는 못 넣습니다.");
        ImGui::Checkbox("궤도속도 자동", &app.brush.autoOrbit);
        Help("놓는 순간 그 자리의 중력을 재서, 흩어지지도 무너지지도 않고 도는 속도를 넣어 줍니다.\n\n"
             "끄면 속도 없이 놓여 그대로 무너져 내립니다.");

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
        HelpMark("미리 만들어 둔 장면입니다. **여기부터 눌러 보세요** — 누르면 그 장면이 처음부터 시작합니다.");
        // 버튼마다 무엇을 보게 되는지 한 줄로 알려준다. 이름만으로는 무슨 장면인지 알 수 없다.
        const char* presetHelp[5] = {
            "은하 하나가 빙글빙글 돌면서 나선 팔과 막대 구조를 만듭니다. 가장 기본이 되는 장면입니다.",
            "은하 두 개가 서로를 스치고 지나갑니다. 중력에 끌려 길게 늘어진 꼬리가 생깁니다.",
            "가스 덩어리 두 개가 정면으로 부딪힙니다. 부딪히는 자리에 뚜렷한 경계선이 서고 달아오릅니다. "
            "「가스」 섹션의 압력을 켜야 제대로 보입니다.",
            "온 우주에 알갱이를 고루 뿌려 두고 시간을 흘립니다. 스스로 실처럼 이어진 거미줄 구조가 자랍니다. "
            "실제 우주가 지금 모습이 된 과정입니다. 오래 걸리니 시간 배속을 올려 보세요.",
            "아무것도 없는 판입니다. 아래 「마우스 도구」의 형태 추가로 직접 은하를 놓아 보세요.",
        };
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
            Help(presetHelp[i]);
            if (sel) ImGui::PopStyleColor();
            if (i % 2 == 0 && i < 4) ImGui::SameLine();
        }
        SectionNote("장면을 고르면 경계 조건과 압력 설정도 그 장면에 맞게 함께 바뀝니다.");
    }

    // ---------------- 8. 녹화 ----------------
    if (ImGui::CollapsingHeader("녹화")) {
        HelpMark("화면을 그림 파일로 남깁니다. 실행 파일 옆의 captures 폴더에 저장됩니다.");
        if (ImGui::Button("📷 스냅샷 저장", ImVec2(-1, 0))) app.snapshotRequested = true;
        Help("지금 화면을 그림 한 장으로 저장합니다. HUD 를 끄고 찍으면 그림만 깔끔하게 남습니다.");

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
            Help("정지할 때까지 화면을 계속 그림으로 남깁니다. 한 장씩 따로 저장되므로 "
                 "동영상으로 만들려면 나중에 다른 프로그램으로 합치면 됩니다.\n\n"
                 "한 장이 약 5 MB 라 금방 쌓입니다 — 필요한 구간만 짧게 찍는 편이 좋습니다.");
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
        Help("몇 장에 한 번 저장할지입니다. 2 로 두면 절반만 남아 용량이 절반이 됩니다.");
        const char* fmt[] = { "PNG 시퀀스" };
        int f = 0;
        ImGui::Combo("출력 형식", &f, fmt, 1);
        Help("낱장 그림으로만 저장합니다. 동영상 변환기를 앱에 넣지 않아 선택지가 하나입니다.");
        SectionNote("실행 파일 옆 captures 폴더에 저장됩니다.");
    }

    // ---------------- 9. 성능 ----------------
    if (ImGui::CollapsingHeader("성능", ImGuiTreeNodeFlags_DefaultOpen)) {
        HelpMark("얼마나 빠르게 돌고 있는지 보여줍니다. 느려지면 「파티클 수」나 「격자 해상도」를 낮추세요.");
        SimTimings t = app.sim.timings();
        ImGui::Text("프레임 %.2f ms / 예산 16.7 ms", app.frameMs);
        Help("화면 한 장을 만드는 데 걸린 시간입니다.\n\n"
             "16.7 밀리초 아래면 초당 60장이 나와 부드럽습니다. 막대가 초록이면 여유, "
             "주황이면 아슬아슬, 빨강이면 예산을 넘긴 것입니다.");

        // 예산 대비 막대. 넘치면 색이 바뀌어 눈에 띈다.
        float frac = app.frameMs / 16.7f;
        ImVec4 barCol = (frac < 0.7f) ? ImVec4(0.37f, 0.76f, 0.48f, 1.f)
                      : (frac < 1.0f) ? ImVec4(0.88f, 0.64f, 0.29f, 1.f)
                                      : ImVec4(0.88f, 0.42f, 0.35f, 1.f);
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, barCol);
        ImGui::ProgressBar(frac > 1.f ? 1.f : frac, ImVec2(-1, 8), "");
        ImGui::PopStyleColor();

        ImGui::Text("산란 %.3f   FFT %.3f", t.scatterMs, t.poissonMs);
        Help("한 번 계산할 때 각 단계에 쓰인 시간(밀리초)입니다.\n\n"
             "· 산란 — 알갱이들을 눈금판에 뿌려 어디가 빽빽한지 세는 단계\n"
             "· FFT — 그 빽빽함으로부터 중력을 한 번에 푸는 단계. 이 방식 덕분에 "
             "알갱이가 천만 개여도 서로를 일일이 비교하지 않습니다");
        ImGui::Text("보간 %.3f   가스 %.3f", t.gatherMs, t.gasMs);
        Help("· 보간 — 눈금판에서 구한 힘을 알갱이 하나하나에 되돌려 주는 단계\n"
             "· 가스 — 압력·온도 계산. 「가스」를 끄면 0 입니다");
        ImGui::Text("스텝 합계 %.3f ms", t.totalMs);
        Help("위 단계를 모두 더한 시간입니다. 화면 한 장을 만드는 시간에서 그림 그리기를 뺀 부분입니다.");
        // 배속을 올리면 한 프레임에 여러 스텝을 돈다. 위 항목은 스텝 하나의 시간이라
        // 그 곱이 프레임에 실린 계산량이 된다.
        if (app.stepsLastFrame > 1)
            ImGui::Text("프레임당 스텝 %d 회 (배속 %.1fx)", app.stepsLastFrame, app.cfg.timeScale);
        ImGui::Separator();
        ImGui::Text("파티클 %d", app.sim.particleCount());
        ImGui::Text("격자 %d²", app.sim.gridSize());
        ImGui::Text("VRAM 여유 %.0f MB", Sim::deviceFreeBytes() / 1048576.0);
        Help("그래픽카드에 남은 메모리입니다. 부족하면 파티클 수가 자동으로 줄어듭니다.");
        SectionNote("산란·FFT·보간은 총 시간을 단계별 비율로 나눈 어림값이고, 총 시간은 실제로 잰 값입니다.");
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
    // 화면 아래 단추에도 설명을 붙인다 — 보드를 접어 둔 채로 쓰는 사람이 여기부터 만난다.
    const char* toolHelp[5] = {
        "화면을 끌어 이동하고 마우스 휠로 확대·축소합니다.",
        "화면을 끄는 동안 그 자리 가스를 바깥으로 밀어냅니다. 흐름을 흔들어 볼 때 씁니다.",
        "화면을 끄는 동안 보이지 않는 무거운 것을 놓아 물질을 그쪽으로 끌어당깁니다.",
        "누른 자리에 새 덩어리를 놓습니다. 누를 때 한 번만 들어갑니다.\n"
        "모양·크기·개수는 설정 보드의 「마우스 도구」에서 고릅니다.",
        "화면을 끄는 동안 그 자리 알갱이를 지웁니다.",
    };
    for (int i = 0; i < 5; ++i) {
        const bool sel = ((int)app.tool == i);
        if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button(labels[i], ImVec2(72, 30))) app.tool = (Tool)i;
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
