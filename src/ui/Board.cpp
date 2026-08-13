#include "ui/Board.h"

#include "imgui.h"
#include <cstdio>

namespace {

// 바로 앞에 그린 항목에 설명을 붙인다. 마우스를 올려야 뜨므로 화면을 차지하지 않는다.
// 화면에 글로 적어 두면 그만큼 항목이 늘어 보인다 — 설명은 전부 여기로 몰았다.
void Help(const char* text) {
    if (!ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) return;
    ImGui::BeginTooltip();
    ImGui::PushTextWrapPos(ImGui::GetFontSize() * 22.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::EndTooltip();
}

// 개수를 고르는 줄 — 슬라이더로 끌거나 숫자를 직접 쳐 넣는다.
//
// 값은 만 단위로 다룬다. 3000만을 숫자로 치려면 0 을 여덟 번 세야 하는데, 만 단위면 3000 이다.
// 슬라이더는 **손을 뗐을 때** 한 번만 적용한다 — 끄는 동안 매 프레임 적용하면 지나치는 값마다
// 수 GB 메모리를 다시 잡아 그래픽 드라이버가 넘어간다(2026-08-13 실측).
bool CountRow(const char* id, int* valueMan, int minMan, int maxMan, int* dragCache) {
    bool committed = false;
    if (*dragCache < 0 || !ImGui::IsAnyItemActive()) *dragCache = *valueMan;

    ImGui::PushID(id);
    ImGui::SetNextItemWidth(-70.0f);
    ImGui::SliderInt("##s", dragCache, minMan, maxMan, "%d만",
                     ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_Logarithmic);
    if (ImGui::IsItemDeactivatedAfterEdit()) committed = true;
    ImGui::SameLine();
    ImGui::SetNextItemWidth(62.0f);
    if (ImGui::InputInt("##t", dragCache, 0, 0, ImGuiInputTextFlags_EnterReturnsTrue))
        committed = true;
    Help("숫자를 직접 쳐 넣을 수 있습니다. 단위는 만 개 — 3000 을 넣으면 3000만 개입니다.\n"
         "입력 후 Enter 를 누르세요.");
    ImGui::PopID();

    if (committed) {
        if (*dragCache < minMan) *dragCache = minMan;
        if (*dragCache > maxMan) *dragCache = maxMan;
        *valueMan = *dragCache;
    }
    return committed;
}

void Title(const char* text) {
    ImGui::Spacing();
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.62f, 0.68f, 0.78f, 1.0f));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

} // namespace

void DrawBoard(App& app, bool& boardOpen) {
    if (!boardOpen) return;

    ImGuiIO& io = ImGui::GetIO();
    const float boardW = 268.0f;
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - boardW, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(boardW, io.DisplaySize.y), ImGuiCond_Always);
    ImGui::Begin("##board", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoMove |
                 ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse |
                 ImGuiWindowFlags_NoBringToFrontOnFocus);

    const float full = -1.0f;
    const float half = (boardW - 24.0f) * 0.5f - 4.0f;

    // ---------------- 장면 ----------------
    Title("장면");
    struct Scene { Preset p; const char* name; const char* help; };
    const Scene scenes[6] = {
        { Preset::SpiralDisk,  "나선 은하",   "은하 하나가 돌면서 나선 팔을 만듭니다." },
        { Preset::TidalPair,   "은하 충돌",   "은하 둘이 스치며 긴 꼬리를 남깁니다." },
        { Preset::HeadOnShock, "정면 충돌",   "가스 덩어리 둘이 부딪혀 달아오릅니다. 온도로 보면 잘 보입니다." },
        { Preset::CosmicWeb,   "우주 거미줄", "우주에 고루 뿌려 두면 거미줄 구조가 자랍니다. 빠르기를 올려 보세요." },
        { Preset::BlackHole,   "블랙홀",
          "여기만 중력 공식을 쓰지 않습니다. 물질이 휘어진 시공간의 최단경로를 그대로 따라갑니다.\n\n"
          "화면의 세 원은 왼쪽부터 지평선(들어가면 못 나옴) · 광자 구면(원궤도 속도가 광속이 되는 곳) · "
          "최소 안정 궤도입니다. 마지막 원 안쪽에는 안정된 궤도가 아예 없어서 나선을 그리며 빨려 듭니다.\n\n"
          "이 셋은 따로 넣은 규칙이 아니라 곡률 항 하나에서 저절로 나옵니다." },
        { Preset::Empty,       "빈 우주",     "아무것도 없습니다. 아래 모양을 골라 화면을 클릭해 채우세요." },
    };
    for (int i = 0; i < 6; ++i) {
        const bool sel = (app.cfg.preset == scenes[i].p);
        if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button(scenes[i].name, ImVec2(half, 0))) {
            ApplyPresetDefaults(app.cfg, scenes[i].p);
            app.applyConfig();      // 코어에 넘긴 뒤에 배치를 다시 만든다(순서가 중요)
            app.sim.reset();
            app.running = true;
        }
        Help(scenes[i].help);
        if (sel) ImGui::PopStyleColor();
        if (i % 2 == 0) ImGui::SameLine();
    }

    // ---------------- 놓기 ----------------
    // 제목에 특수 문자를 쓰지 않는다 — 이 폰트에 없는 글자는 네모(◈)로 깨져 나온다.
    Title("놓기 (고르고 화면 클릭)");
    const char* shapeNames[5] = { "은하", "태양", "고리", "구름", "덩어리" };
    const char* shapeHelp[5] = {
        "도는 원반입니다. 놓는 자리 중력에 맞는 속도가 들어가 모양을 유지합니다.",
        "가운데가 빽빽하고 뜨겁습니다.",
        "가운데가 빈 도넛입니다.",
        "넓고 성기게 퍼진 차가운 성운입니다.",
        "고르게 찬 공입니다. 속도 없이 놓여 그대로 무너집니다.",
    };
    // 셋 + 둘로 나눠 놓는다. 다섯을 한 줄에 넣으면 보드 폭을 넘어 마지막 이름이 잘린다.
    const float third = (boardW - 24.0f) / 3.0f - 6.0f;
    for (int i = 0; i < 5; ++i) {
        const bool sel = ((int)app.brush.shapeKind == i);
        if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
        if (ImGui::Button(shapeNames[i], ImVec2(third, 0))) {
            app.brush.shapeKind = (ShapeKind)i;
            app.tool = Tool::AddShape;       // 모양을 고르면 바로 놓을 수 있게
        }
        Help(shapeHelp[i]);
        if (sel) ImGui::PopStyleColor();
        if (i != 2 && i != 4) ImGui::SameLine();
    }
    // 한 번에 놓을 개수 — 1만 개부터 지금 정한 최대치까지.
    int shapeMan = app.brush.shapeCount / 10000;
    if (shapeMan < 1) shapeMan = 1;
    const int capMan = (app.cfg.particleCount / 10000) > 1 ? (app.cfg.particleCount / 10000) : 1;
    if (shapeMan > capMan) shapeMan = capMan;
    if (CountRow("shape", &shapeMan, 1, capMan, &app.shapeCountSlider))
        app.brush.shapeCount = shapeMan * 10000;

    // ---------------- 시간 ----------------
    Title("시간");
    if (ImGui::Button(app.running ? "멈춤" : "재생", ImVec2(half, 0))) app.running = !app.running;
    Help("시간을 멈추거나 다시 흐르게 합니다.");
    ImGui::SameLine();
    if (ImGui::Button("처음부터", ImVec2(half, 0))) { app.applyConfig(); app.sim.reset(); }
    Help("지금 장면을 처음 상태로 되돌립니다.");
    ImGui::SetNextItemWidth(full);
    ImGui::SliderFloat("##speed", &app.cfg.timeScale, 0.1f, 4.0f, "빠르기 %.1f 배");
    // 1배를 넘는 배속은 한 화면에 여러 번 계산해 내므로 정수만 뜻이 있다.
    if (app.cfg.timeScale > 1.0f) app.cfg.timeScale = (float)(int)(app.cfg.timeScale + 0.5f);
    Help("1보다 내리면 느리게, 올리면 빠르게 흐릅니다. 올리면 그만큼 무거워집니다.");

    // ---------------- 보기 ----------------
    Title("보기");
    const bool isDensity = (app.look == App::Look::Density);
    if (isDensity) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
    if (ImGui::Button("밀도", ImVec2(half, 0))) { app.look = App::Look::Density; ApplyLook(app); }
    Help("얼마나 빽빽하게 모였는지를 밝기로 보여줍니다.");
    if (isDensity) ImGui::PopStyleColor();
    ImGui::SameLine();
    if (!isDensity) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.44f, 0.62f, 1.0f));
    if (ImGui::Button("온도", ImVec2(half, 0))) { app.look = App::Look::Temperature; ApplyLook(app); }
    Help("얼마나 뜨거운지를 색으로 보여줍니다. 부딪히는 자리가 달아오릅니다.");
    if (!isDensity) ImGui::PopStyleColor();

    // ---------------- 녹화 ----------------
    Title("녹화");
    if (ImGui::Button("한 장 저장", ImVec2(half, 0))) app.snapshotRequested = true;
    Help("지금 화면을 그림 한 장으로 저장합니다. captures 폴더에 들어갑니다.");
    ImGui::SameLine();
    if (app.recording) {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.48f, 0.16f, 0.16f, 1.0f));
        if (ImGui::Button("정지", ImVec2(half, 0))) app.recording = false;
        ImGui::PopStyleColor();
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.29f, 0.29f, 1.0f));
        ImGui::Text("녹화 중 %d 장", app.recordedFrames);
        ImGui::PopStyleColor();
    } else {
        if (ImGui::Button("녹화", ImVec2(half, 0))) {
            app.recording = true; app.recordedFrames = 0; app.frameCounter = 0;
        }
        Help("정지할 때까지 계속 그림으로 남깁니다. 한 장이 약 5 MB 라 금방 쌓입니다.");
    }
    if (app.lastSaveFailed) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.92f, 0.35f, 0.30f, 1.0f));
        ImGui::TextWrapped("저장 실패 — captures 폴더의 빈 공간을 확인하세요.");
        ImGui::PopStyleColor();
        if (ImGui::SmallButton("확인")) app.lastSaveFailed = false;
    }

    // ---------------- 최대 개수 ----------------
    Title("최대 개수");
    int maxMan = app.cfg.particleCount / 10000;
    if (maxMan < 1) maxMan = 1;
    // 3000만이 상한이다 — 그 위로는 이 그래픽카드에서 안정적으로 돌지 않는다.
    if (CountRow("cap", &maxMan, 1, 3000, &app.particleSlider))
        app.cfg.particleCount = maxMan * 10000;
    Help("화면에 둘 수 있는 알갱이의 최대 개수입니다. 이 수를 넘지 않도록 먼저 놓은 것부터 "
         "자동으로 밀려납니다.\n\n1000만까지가 넉넉하고, 그 위로는 느려집니다.");
    if (app.sim.particleCount() < app.cfg.particleCount) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.88f, 0.64f, 0.29f, 1.0f));
        ImGui::TextWrapped("메모리가 모자라 %d 개로 줄임", app.sim.particleCount());
        ImGui::PopStyleColor();
    }

    ImGui::Spacing();
    ImGui::TextDisabled("Tab: 화면만 보기");

    ImGui::End();
}

void DrawToolbar(App& app, int viewW, int viewH) {
    const char* labels[5] = { "카메라", "놓기", "뿌리기", "끌기", "지우개" };
    const char* toolHelp[5] = {
        "화면을 끌어 이동하고 휠로 확대·축소합니다.",
        "누른 자리에 위에서 고른 모양을 놓습니다.",
        "끄는 동안 그 자리 가스를 바깥으로 밀어냅니다.",
        "끄는 동안 물질을 그쪽으로 끌어당깁니다.",
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
            ImGui::PushTextWrapPos(ImGui::GetFontSize() * 20.0f);
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
