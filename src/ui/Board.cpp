#include "ui/Board.h"
#include "app/Version.h"

#include "imgui.h"
#include <cstdio>
#include <string>

namespace {

// 시안이 정한 색. 흑연 회색 바탕에 주황 하나만 강조로 쓴다.
const ImU32 kAccent      = IM_COL32(255, 176, 102, 255);  // #ffb066
const ImU32 kAccentSoft  = IM_COL32(255, 176, 102,  41);  // 칩 배경
const ImU32 kAccentLine  = IM_COL32(255, 176, 102, 107);  // 칩 테두리
const ImU32 kAccentText  = IM_COL32(255, 196, 138, 255);  // #ffc48a
const ImU32 kInk         = IM_COL32(255, 255, 255, 255);
const ImU32 kInkDim      = IM_COL32(182, 178, 196, 255);  // #b6b2c4
const ImU32 kInkFaint    = IM_COL32(154, 149, 171, 255);  // #9a95ab
const ImU32 kInkGhost    = IM_COL32(107, 103, 121, 255);  // #6b6779
const ImU32 kRec         = IM_COL32(255,  91,  91, 255);  // #ff5b5b
const ImU32 kRecText     = IM_COL32(255, 157, 157, 255);
const ImU32 kGlass       = IM_COL32(255, 255, 255,  18);  // 알약 배경
const ImU32 kGlassLine   = IM_COL32(255, 255, 255,  26);
const ImU32 kDivider     = IM_COL32(255, 255, 255,  31);

constexpr float kBarH    = 44.0f;   // 막대 높이
constexpr float kBarPad  = 22.0f;   // 좌우 여백
constexpr float kBarGap  = 18.0f;   // 바닥에서 띄우는 높이

// 바로 앞에 그린 항목에 설명을 붙인다.
// 막대에는 그림만 두고 이름과 단축키는 올릴 때만 뜨게 한다 —
// 처음엔 배울 수 있고 익숙해지면 조용하다.
void Tip(const char* text) {
    if (!ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) return;
    ImGui::BeginTooltip();
    ImGui::PushTextWrapPos(ImGui::GetFontSize() * 20.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::EndTooltip();
}

// 막대 안의 세로 구분선.
void Divider() {
    ImGui::SameLine(0.0f, 7.0f);
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float y = p.y + (kBarH - 24.0f) * 0.5f - 6.0f;
    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x, y), ImVec2(p.x, y + 24.0f), kDivider, 1.0f);
    ImGui::Dummy(ImVec2(1.0f, 24.0f));
    ImGui::SameLine(0.0f, 7.0f);
}

float Clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

// 시안의 조절기 한 줄 — 이름과 값은 위에 나란히, 트랙은 그 아래 얇게.
//
// ImGui 기본 슬라이더는 값 글자를 트랙 한가운데 얹고 손잡이가 그 위를 지나므로,
// 손잡이가 값 근처에 오면 정작 읽어야 할 숫자가 가려진다. 여기서는 층을 나눠
// 손잡이가 어디 있든 값이 늘 읽힌다.
//
// 위치는 0~1 로만 주고받는다. 실제 값으로 바꾸는 일은 부르는 쪽이 하므로
// 선형이든 로그든 정수든 같은 그림을 쓴다.
bool TrackRow(const char* label, const char* valueText, float* t, float width) {
    const float rowH = 34.0f;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    ImGui::InvisibleButton("##row", ImVec2(width, rowH));
    const bool act = ImGui::IsItemActive();
    const bool hov = ImGui::IsItemHovered();

    bool changed = false;
    if (act) {
        const float nt = Clampf((ImGui::GetIO().MousePos.x - p.x) / width, 0.0f, 1.0f);
        if (nt != *t) { *t = nt; changed = true; }
    }

    const float ty = p.y + rowH - 7.0f;               // 트랙은 줄 아래쪽
    const float gx = p.x + width * Clampf(*t, 0.0f, 1.0f);
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const ImVec2 vsz = ImGui::CalcTextSize(valueText);
    dl->AddText(ImVec2(p.x, p.y + 1.0f), kInkDim, label);
    dl->AddText(ImVec2(p.x + width - vsz.x, p.y + 1.0f), kInk, valueText);
    dl->AddLine(ImVec2(p.x, ty), ImVec2(p.x + width, ty), IM_COL32(255, 255, 255, 28), 3.0f);
    dl->AddLine(ImVec2(p.x, ty), ImVec2(gx, ty), kAccent, 3.0f);
    dl->AddCircleFilled(ImVec2(gx, ty), (hov || act) ? 7.0f : 5.5f, kAccent);
    return changed;
}

// 실수 조절기. log 를 켜면 눈금을 배수로 나눈다 —
// 밝기처럼 0.05 와 20 이 한 줄에 있어야 하는 값은 그래야 양쪽 다 만질 수 있다.
bool SliderRow(const char* id, const char* label, float* v, float lo, float hi,
               const char* fmt, bool log = false, float width = 262.0f) {
    char val[40]; snprintf(val, sizeof(val), fmt, *v);
    float t = log ? (logf(Clampf(*v, lo, hi) / lo) / logf(hi / lo))
                  : ((Clampf(*v, lo, hi) - lo) / (hi - lo));
    ImGui::PushID(id);
    const bool moved = TrackRow(label, val, &t, width);
    ImGui::PopID();
    // 만지지 않았으면 값을 되돌려 쓰지 않는다 — 왕복 변환만으로 값이 조금씩 깎이는 것을 막는다.
    if (moved) *v = log ? lo * expf(logf(hi / lo) * t) : lo + (hi - lo) * t;
    return moved;
}

// 정수 조절기. 개수처럼 「몇 만」 단위로 세는 값에 쓴다.
bool SliderRowInt(const char* id, const char* label, int* v, int lo, int hi,
                  const char* fmt, bool log = false, float width = 262.0f) {
    char val[40]; snprintf(val, sizeof(val), fmt, *v);
    const float flo = (float)lo, fhi = (float)hi;
    const float fv = Clampf((float)*v, flo, fhi);
    float t = (hi <= lo) ? 0.0f
            : (log ? (logf(fv / flo) / logf(fhi / flo)) : ((fv - flo) / (fhi - flo)));
    ImGui::PushID(id);
    const bool moved = TrackRow(label, val, &t, width);
    ImGui::PopID();
    if (moved) {
        const float nv = log ? flo * expf(logf(fhi / flo) * t) : flo + (fhi - flo) * t;
        *v = (int)(nv + 0.5f);
        if (*v < lo) *v = lo;
        if (*v > hi) *v = hi;
    }
    return moved;
}

// 막대에서 여는 팝업은 위로 펼친다.
//
// ImGui 는 팝업을 누른 자리 아래에 여는데, 이 막대는 화면 맨 아래라 아래쪽에 자리가 없다.
// 기준점을 팝업의 **바닥**으로 잡아(pivot y=1) 누른 것 위로 자라게 한다.
// 인자는 방금 그린 항목의 좌상단 — `ImGui::GetItemRectMin()` 을 그대로 넘긴다.
// pivotX 를 1 로 주면 기준점이 팝업의 오른쪽 끝이 된다 —
// 막대 오른쪽에 붙은 것은 그렇게 열어야 창 밖으로 나가지 않는다.
void AnchorAbove(const ImVec2& itemTopLeft, float pivotX = 0.0f) {
    ImGui::SetNextWindowPos(ImVec2(itemTopLeft.x, itemTopLeft.y - 10.0f),
                            ImGuiCond_Always, ImVec2(pivotX, 1.0f));
}

// 알약 오른쪽 끝에 「좌우로 끌면 바뀐다」는 표시를 그린다.
// 폰트에 없는 기호(⇄)를 쓰면 네모로 깨지므로 화살표를 직접 그린다.
void DragMark(ImDrawList* dl, const ImVec2& c, ImU32 col) {
    const float w = 4.5f, h = 3.2f;
    dl->AddLine(ImVec2(c.x - 5.5f, c.y - 2.0f), ImVec2(c.x + 5.5f, c.y - 2.0f), col, 1.2f);
    dl->AddLine(ImVec2(c.x - 5.5f, c.y - 2.0f), ImVec2(c.x - 5.5f + w, c.y - 2.0f - h), col, 1.2f);
    dl->AddLine(ImVec2(c.x + 5.5f, c.y + 2.0f), ImVec2(c.x - 5.5f, c.y + 2.0f), col, 1.2f);
    dl->AddLine(ImVec2(c.x + 5.5f, c.y + 2.0f), ImVec2(c.x + 5.5f - w, c.y + 2.0f + h), col, 1.2f);
}

// 값을 보여 주는 알약.
//
// 값은 늘 곁에 두되 조절기는 필요할 때만 꺼낸다. 두 가지로 만질 수 있다.
//   · 좌우로 끌면 그 자리에서 값이 바뀐다(오른쪽 끝 화살표가 그 표시다)
//   · 누르면 조절기가 열려 세밀하게 맞춘다
// 끌기를 먼저 보는 이유는, 대개 조금만 올리거나 내리고 싶어서다 —
// 그때마다 창을 열었다 닫는 것은 성가시다.
//
// 돌려주는 값: 0 아무 일 없음 · 1 눌렸음(조절기를 열 차례) · 2 끄는 중(delta 에 변화량)
int Pill(const char* id, const char* label, const char* value, float* delta,
         bool accentValue = false, const ImU32* gradient = nullptr) {
    ImGui::PushID(id);
    const ImVec2 lsz = ImGui::CalcTextSize(label);
    const ImVec2 vsz = ImGui::CalcTextSize(value);
    const float extra = gradient ? 44.0f : 22.0f;   // 그라데이션 막대 또는 화살표 자리
    const float w = lsz.x + vsz.x + 8.0f + 24.0f + extra;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float h = 30.0f;

    ImGui::InvisibleButton("##pill", ImVec2(w, h),
                           ImGuiButtonFlags_MouseButtonLeft);
    const bool hov = ImGui::IsItemHovered();
    const bool act = ImGui::IsItemActive();

    int result = 0;
    if (act) {
        const ImVec2 d = ImGui::GetMouseDragDelta(ImGuiMouseButton_Left, 2.0f);
        if (d.x != 0.0f) {
            *delta = d.x;
            ImGui::ResetMouseDragDelta(ImGuiMouseButton_Left);
            result = 2;
        }
    }
    // 끌지 않고 뗐으면 그냥 누른 것이다.
    if (ImGui::IsItemDeactivated() && result == 0
        && ImGui::GetMouseDragDelta(ImGuiMouseButton_Left, 2.0f).x == 0.0f)
        result = 1;

    ImDrawList* dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h),
                      (hov || act) ? IM_COL32(255, 255, 255, 33) : kGlass, h * 0.5f);
    dl->AddRect(p, ImVec2(p.x + w, p.y + h), kGlassLine, h * 0.5f);
    const float ty = p.y + (h - lsz.y) * 0.5f;
    dl->AddText(ImVec2(p.x + 12.0f, ty), kInkFaint, label);
    dl->AddText(ImVec2(p.x + 12.0f + lsz.x + 8.0f, ty), accentValue ? kAccentText : kInk, value);

    const float rx = p.x + w - 12.0f;
    if (gradient) {
        // 지금 컬러맵을 작은 띠로 보여 준다 — 밝기를 만질 때 어떤 색이 어떤 밝기인지 함께 보인다.
        const ImVec2 a(rx - 34.0f, p.y + h * 0.5f - 4.0f), b(rx, p.y + h * 0.5f + 4.0f);
        const float step = (b.x - a.x) * 0.25f;
        for (int i = 0; i < 4; ++i)
            dl->AddRectFilledMultiColor(ImVec2(a.x + step * i, a.y), ImVec2(a.x + step * (i + 1), b.y),
                                        gradient[i], gradient[i + 1], gradient[i + 1], gradient[i]);
        dl->AddRect(a, b, IM_COL32(255, 255, 255, 41), 2.0f);
    } else {
        DragMark(dl, ImVec2(rx - 6.0f, p.y + h * 0.5f), kInkGhost);
    }
    ImGui::PopID();
    return result;
}

// 도구 하나. 36×32 자리에 도형만 그린다.
bool ToolButton(const char* id, int shape, bool selected) {
    ImGui::PushID(id);
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const ImVec2 sz(36.0f, 32.0f);
    const bool pressed = ImGui::InvisibleButton("##t", sz);
    const bool hov = ImGui::IsItemHovered();

    ImDrawList* dl = ImGui::GetWindowDrawList();
    if (selected)  dl->AddRectFilled(p, ImVec2(p.x + sz.x, p.y + sz.y), IM_COL32(255,255,255,33), 8.0f);
    else if (hov)  dl->AddRectFilled(p, ImVec2(p.x + sz.x, p.y + sz.y), IM_COL32(255,255,255,26), 8.0f);
    const ImU32 c = selected ? kInk : (hov ? kInk : kInkDim);

    const ImVec2 m(p.x + sz.x * 0.5f, p.y + sz.y * 0.5f);
    switch (shape) {
        case 0:  // 카메라 — 네모 테두리
            dl->AddRect(ImVec2(m.x - 7.5f, m.y - 6.0f), ImVec2(m.x + 7.5f, m.y + 6.0f), c, 3.0f, 0, 2.0f);
            break;
        case 1:  // 놓기 — 꽉 찬 원
            dl->AddCircleFilled(m, 6.0f, c, 16);
            break;
        case 2:  // 뿌리기 — 점선 원
            for (int i = 0; i < 8; ++i) {
                const float a0 = (float)i * 0.785398f + 0.15f;
                const float a1 = a0 + 0.44f;
                dl->PathArcTo(m, 7.0f, a0, a1, 6);
                dl->PathStroke(c, 0, 2.0f);
            }
            break;
        case 3:  // 끌기 — 가로 막대
            dl->AddRectFilled(ImVec2(m.x - 8.5f, m.y - 1.2f), ImVec2(m.x + 8.5f, m.y + 1.2f), c, 2.0f);
            break;
        default: // 지우개 — 흐린 네모
            dl->AddRect(ImVec2(m.x - 6.5f, m.y - 6.5f), ImVec2(m.x + 6.5f, m.y + 6.5f),
                        (c & 0x00FFFFFF) | 0x8C000000, 4.0f, 0, 2.0f);
            break;
    }
    ImGui::PopID();
    return pressed;
}

struct Scene { Preset p; const char* name; const char* help; };
constexpr int kSceneCount = 5;
const Scene kScenes[kSceneCount] = {
    { Preset::SpiralDisk,  "나선 은하",   "나선 팔을 가진 은하 하나가 돕니다." },
    { Preset::TidalPair,   "은하 충돌",   "나선 은하 둘이 양옆에서 서로를 끌어당겨 긴 꼬리를 남깁니다." },
    { Preset::CosmicWeb,   "우주 거미줄", "고루 뿌려 두면 거미줄 구조가 자랍니다. 빠르기를 올려 보세요." },
    { Preset::BlackHole,   "블랙홀",      "물질이 휘어진 시공간의 최단경로를 따라갑니다." },
    { Preset::Empty,       "빈 우주",     "아무것도 없습니다. 놓기로 직접 채우세요." },
};

// 카드에 그 장면의 **실제 초기 배치**를 축소해 그린다.
// 색만 다른 동그라미로는 어느 장면이 무엇인지 알 수 없다 — 미리보기는 미리 보여야 한다.
// 코어의 kPlace 와 같은 규칙으로 점을 찍으므로, 배치를 바꾸면 여기도 함께 고친다.
void DrawScenePreview(ImDrawList* dl, const ImVec2& c, float w, float h, int scene) {
    // 값이 고정된 난수. 프레임마다 흔들리면 미리보기가 지글거린다.
    auto rnd = [](unsigned s) {
        s = s * 747796405u + 2891336453u;
        unsigned w2 = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (float)((w2 >> 22u) ^ w2) * 2.3283064365386963e-10f;
    };
    const float R = (h < w ? h : w) * 0.42f;

    // 나선 한 덩이. 코어의 spiralPoint 와 같은 로그 나선이다.
    auto spiral = [&](float ox, float oy, float scale, unsigned seed, ImU32 col) {
        for (int i = 0; i < 150; ++i) {
            const float u1 = rnd(seed + (unsigned)i * 3u + 1u);
            const float u2 = rnd(seed + (unsigned)i * 3u + 2u);
            const float u3 = rnd(seed + (unsigned)i * 3u + 3u);
            const float t = 0.08f + 0.92f * sqrtf(u1);
            const float arm = (u3 < 0.5f) ? 0.f : 3.14159265f;
            const float th = arm + 3.2f * logf(t + 0.12f) + (u2 - 0.5f) * (0.85f * (1.f - t) + 0.16f) * 2.0f;
            const float r = R * scale * t;
            dl->AddCircleFilled(ImVec2(c.x + ox + cosf(th) * r, c.y + oy + sinf(th) * r), 1.15f, col, 4);
        }
    };

    const ImU32 warm = IM_COL32(255, 186, 120, 210);
    const ImU32 cool = IM_COL32(150, 150, 235, 180);

    switch (scene) {
        case 0:  // 나선 은하
            spiral(0.f, 0.f, 1.0f, 11u, warm);
            break;
        case 1:  // 은하 충돌 — 나선 둘이 양옆에
            spiral(-w * 0.20f,  h * 0.06f, 0.62f, 23u, warm);
            spiral( w * 0.20f, -h * 0.06f, 0.62f, 57u, cool);
            break;
        case 2:  // 우주 거미줄 — 판 전체에 고루
            for (int i = 0; i < 210; ++i) {
                const float x = (rnd((unsigned)i * 2u + 5u) - 0.5f) * w * 0.94f;
                const float y = (rnd((unsigned)i * 2u + 6u) - 0.5f) * h * 0.90f;
                dl->AddCircleFilled(ImVec2(c.x + x, c.y + y), 1.05f, cool, 4);
            }
            break;
        case 3:  // 블랙홀 — 가운데가 빈 고리와 지평선
            for (int i = 0; i < 190; ++i) {
                const float u = rnd((unsigned)i * 2u + 9u);
                const float a = rnd((unsigned)i * 2u + 10u) * 6.2831853f;
                const float r = R * (0.34f + 0.66f * sqrtf(u));
                dl->AddCircleFilled(ImVec2(c.x + cosf(a) * r, c.y + sinf(a) * r), 1.1f, warm, 4);
            }
            dl->AddCircleFilled(c, R * 0.17f, IM_COL32(0, 0, 0, 255), 20);
            dl->AddCircle(c, R * 0.17f, IM_COL32(255, 150, 90, 190), 20, 1.2f);
            break;
        default: // 빈 우주 — 아무것도 없다
            dl->AddText(ImVec2(c.x - 7.0f, c.y - 9.0f), IM_COL32(107, 103, 121, 255), "+");
            break;
    }
}

void DrawScenePreview(ImDrawList* dl, const ImVec2& c, float w, float h, int scene);

void SwitchScene(App& app, Preset p) {
    ApplyPresetDefaults(app.cfg, p);
    ApplyAutoGrid(app.cfg);
    app.applyConfig();
    app.sim.reset();
    app.running = true;
    app.drawerOpen = false;
}

const char* SceneName(Preset p) {
    for (const Scene& s : kScenes) if (s.p == p) return s.name;
    return "우주";
}

// 알갱이 수를 사람이 읽는 말로.
void CountText(char* buf, size_t n, int count) {
    if (count >= 10000) snprintf(buf, n, "%d만", count / 10000);
    else                snprintf(buf, n, "%d", count);
}

} // namespace

void SwitchSceneByIndex(App& app, int index) {
    if (index < 0 || index >= kSceneCount) return;
    SwitchScene(app, kScenes[index].p);
}

void DrawBottomScrim(const App& app, int viewW, int viewH) {
    if (app.uiHidden) return;
    // 아래로 갈수록 어두워지는 띠. 막대의 글자가 밝은 우주 위에서도 읽히게 한다.
    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    const float top = (float)viewH - 150.0f;
    dl->AddRectFilledMultiColor(ImVec2(0.0f, top), ImVec2((float)viewW, (float)viewH),
                                IM_COL32(6, 4, 10, 0),   IM_COL32(6, 4, 10, 0),
                                IM_COL32(6, 4, 10, 140), IM_COL32(6, 4, 10, 140));
}

// 서랍이 앉는 자리와 배경. 장면 서랍과 놓기 서랍이 같은 틀을 쓴다.
namespace {
float DrawerTop(int viewH, float panelH) {
    return (float)viewH - kBarGap - kBarH - 12.0f - panelH;
}
void DrawerScrim(int viewW, int viewH) {
    ImGui::GetBackgroundDrawList()->AddRectFilledMultiColor(
        ImVec2(0.0f, (float)viewH * 0.38f), ImVec2((float)viewW, (float)viewH),
        IM_COL32(6, 4, 10, 0),   IM_COL32(6, 4, 10, 0),
        IM_COL32(6, 4, 10, 240), IM_COL32(6, 4, 10, 240));
}
} // namespace

void DrawShapeDrawer(App& app, int viewW, int viewH) {
    if (app.uiHidden || !app.shapeDrawerOpen) return;
    DrawerScrim(viewW, viewH);

    const float cardH = 96.0f;
    const float panelH = cardH + 92.0f;
    ImGui::SetNextWindowPos(ImVec2(0.0f, DrawerTop(viewH, panelH)), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2((float)viewW, panelH), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.035f, 0.027f, 0.055f, 0.88f));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(kBarPad, 18.0f));
    ImGui::Begin("##shapedrawer", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);

    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.545f, 0.525f, 0.612f, 1.0f));
    ImGui::TextUnformatted("무엇을 놓을까요");
    ImGui::PopStyleColor();
    ImGui::SameLine(0.0f, 12.0f);
    ImGui::TextDisabled("고른 뒤 화면을 한 번 누르면 그 자리에 놓입니다");
    {
        const char* hint = "Esc 닫기";
        const float w = ImGui::CalcTextSize(hint).x;
        ImGui::SameLine(ImGui::GetWindowWidth() - kBarPad - w);
        ImGui::TextDisabled("%s", hint);
    }
    ImGui::Spacing();

    struct Shape { const char* name; const char* help; };
    const Shape shapes[6] = {
        { "은하",   "도는 원반입니다. 놓는 자리 중력에 맞는 속도가 들어가 모양을 유지합니다." },
        { "태양",   "가운데가 빽빽하고 뜨겁습니다." },
        { "고리",   "가운데가 빈 도넛입니다." },
        { "구름",   "넓고 성기게 퍼진 차가운 성운입니다." },
        { "블랙홀", "지평선을 세웁니다. 크게 놓을수록 무거워 더 멀리서부터 끌어당깁니다." },
        { "토성",   "가운데 공에 아주 얇은 고리가 둘립니다." },
    };

    const float avail = (float)viewW - kBarPad * 2.0f;
    const float gap = 12.0f;
    // 여섯 모양 뒤에 개수 조절 칸을 하나 더 둔다 — 놓기 직전에 가장 자주 바꾸는 값이다.
    const float cardW = (avail - gap * 6.0f) / 7.0f;

    for (int i = 0; i < 6; ++i) {
        if (i > 0) ImGui::SameLine(0.0f, gap);
        const bool sel = ((int)app.brush.shapeKind == i);
        ImGui::PushID(i);
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const bool pressed = ImGui::InvisibleButton("##shape", ImVec2(cardW, cardH + 34.0f));
        const bool hov = ImGui::IsItemHovered();

        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 a = p, b(p.x + cardW, p.y + cardH + 34.0f);
        dl->AddRectFilled(a, ImVec2(b.x, p.y + cardH), IM_COL32(0, 0, 0, 255), 12.0f,
                          ImDrawFlags_RoundCornersTop);

        // 모양을 그림으로 보여 준다 — 이름만으로는 고리와 구름이 어떻게 다른지 알 수 없다.
        const ImVec2 m(p.x + cardW * 0.5f, p.y + cardH * 0.5f);
        const float r = cardH * 0.30f;
        const ImU32 c = sel ? kAccent : IM_COL32(190, 185, 210, 200);
        // 미리보기는 **실제로 놓이는 배치를 그대로 축소한 그림**이다.
        //
        // 도식으로 그리면 눌러 보기 전에는 무엇이 놓일지 알 수 없고, 놓고 나서 「이게 아닌데」가
        // 된다. 아래 점 찍는 규칙은 코어의 kFillShape 와 같은 식을 쓴다 — 한쪽을 고치면
        // 다른 쪽도 함께 고쳐야 한다.
        auto rnd = [](unsigned v) {
            unsigned s = v * 747796405u + 2891336453u;
            unsigned w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
            return (float)((w >> 22u) ^ w) * 2.3283064365386963e-10f;
        };
        const ImU32 dot = (c & 0x00FFFFFF) | 0xC0000000;
        switch (i) {
            case 0: {   // 은하 — 지수 원반 위에 두 팔이 얹힌다(코어의 diskPoint 와 같은 식)
                for (int j = 0; j < 220; ++j) {
                    const unsigned s = (unsigned)j * 2654435761u + 11u;
                    const float u1 = rnd(s), u2 = rnd(s * 3u + 1u), u4 = rnd(s * 13u + 7u);
                    float rr = -0.28f * (logf(fmaxf(u1, 1e-6f)) + logf(fmaxf(u4, 1e-6f)));
                    if (rr > 1.8f) rr = 1.8f;
                    const float psi = logf(fmaxf(rr, 1e-4f) / 0.06f) / 0.325f;
                    const float rn = rr;
                    const float A = 0.95f * expf(-(rn - 0.35f) * (rn - 0.35f) / 0.45f);
                    const float th0 = u2 * 6.2831853f;
                    const float th = th0 - (A * 0.5f) * sinf(2.0f * (th0 - psi));
                    // 실제 배치는 원반이라 위에서 보면 원이다. 여기서 y 만 눌러 타원으로
                    // 그리면 놓아 보고 「사진과 다르다」가 된다.
                    const float rad = r * rr * 0.56f;
                    dl->AddCircleFilled(ImVec2(m.x + cosf(th) * rad, m.y + sinf(th) * rad),
                                        1.25f, dot, 4);
                }
                break;
            }
            case 1: {   // 태양 — 가운데로 갈수록 빽빽한 공. r = R·u² 라 중심에 몰린다
                for (int j = 0; j < 200; ++j) {
                    const unsigned s = (unsigned)j * 2654435761u + 23u;
                    const float u = rnd(s), th = rnd(s * 7u + 5u) * 6.2831853f;
                    const float rad = r * u * u;
                    dl->AddCircleFilled(ImVec2(m.x + cosf(th) * rad, m.y + sinf(th) * rad),
                                        1.25f, dot, 4);
                }
                break;
            }
            case 2: {   // 고리 — 가운데가 빈 도넛
                for (int j = 0; j < 200; ++j) {
                    const unsigned s = (unsigned)j * 2654435761u + 37u;
                    const float th = rnd(s) * 6.2831853f;
                    const float rad = r * (0.72f + 0.22f * rnd(s * 3u + 1u));
                    dl->AddCircleFilled(ImVec2(m.x + cosf(th) * rad, m.y + sinf(th) * rad),
                                        1.25f, dot, 4);
                }
                break;
            }
            case 3: {   // 구름 — 넓게 퍼진 성운
                for (int j = 0; j < 190; ++j) {
                    const unsigned s = (unsigned)j * 2654435761u + 53u;
                    const float u = rnd(s), th = rnd(s * 7u + 5u) * 6.2831853f;
                    const float rad = r * 1.25f * u * u;
                    dl->AddCircleFilled(ImVec2(m.x + cosf(th) * rad, m.y + sinf(th) * rad),
                                        1.25f, dot, 4);
                }
                break;
            }
            case 4: {   // 블랙홀 — 알갱이가 아니라 지평선. 가운데는 빛이 나오지 못해 검다
                dl->AddCircleFilled(m, r * 0.42f, IM_COL32(0, 0, 0, 255), 28);
                dl->AddCircle(m, r * 0.42f, c, 28, 2.0f);
                // 둘레의 물질이 삼켜지기 전에 달아오르는 원반
                dl->AddCircle(m, r * 0.80f, (c & 0x00FFFFFF) | 0x55000000, 32, r * 0.16f);
                break;
            }
            default: {  // 토성 — 가운데 공에 아주 얇은 고리
                for (int j = 0; j < 200; ++j) {
                    const unsigned s = (unsigned)j * 2654435761u + 71u;
                    const float u3 = rnd(s * 7u + 5u);
                    float px, py;
                    if (u3 < 0.42f) {                     // 본체
                        const float u = rnd(s), th = rnd(s * 11u + 3u) * 6.2831853f;
                        const float rad = r * 0.34f * u * u;
                        px = cosf(th) * rad; py = sinf(th) * rad;
                    } else {                              // 고리 — 위에서 비스듬히 본다
                        const float th = rnd(s) * 6.2831853f;
                        const float rad = r * (0.60f + 0.36f * rnd(s * 3u + 1u));
                        px = cosf(th) * rad; py = sinf(th) * rad * 0.28f;
                    }
                    dl->AddCircleFilled(ImVec2(m.x + px, m.y + py), 1.25f, dot, 4);
                }
                break;
            }
        }

        dl->AddRectFilled(ImVec2(a.x, p.y + cardH), b,
                          sel ? IM_COL32(255, 176, 102, 36) : IM_COL32(255, 255, 255, 15),
                          12.0f, ImDrawFlags_RoundCornersBottom);
        dl->AddRect(a, b, sel ? kAccentLine : (hov ? IM_COL32(255,255,255,107) : kGlassLine), 12.0f, 0, 1.0f);
        const ImVec2 tsz = ImGui::CalcTextSize(shapes[i].name);
        dl->AddText(ImVec2(a.x + 11.0f, p.y + cardH + (34.0f - tsz.y) * 0.5f),
                    sel ? kAccentText : IM_COL32(207, 203, 220, 255), shapes[i].name);
        ImGui::PopID();

        if (hov) Tip(shapes[i].help);
        if (pressed) {
            app.brush.shapeKind = (ShapeKind)i;
            app.tool = Tool::AddShape;      // 이제 화면을 한 번 누르면 놓인다
            app.shapeDrawerOpen = false;
        }
    }

    // 마지막 칸 — 한 번에 놓을 개수
    ImGui::SameLine(0.0f, gap);
    {
        const ImVec2 p = ImGui::GetCursorScreenPos();
        ImGui::BeginGroup();
        ImGui::Dummy(ImVec2(cardW, 10.0f));
        int man = app.brush.shapeCount / 10000; if (man < 1) man = 1;
        const int cap = (app.cfg.particleCount / 10000) > 1 ? (app.cfg.particleCount / 10000) : 1;
        if (man > cap) man = cap;
        if (SliderRowInt("drawer_n", "한 번에", &man, 1, cap, "%d만", true, cardW))
            app.brush.shapeCount = man * 10000;
        ImGui::Spacing();
        SliderRow("drawer_r", "크기", &app.brush.shapeRadius, 0.02f, 0.35f, "%.2f", false, cardW);
        ImGui::EndGroup();
        (void)p;
    }

    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

void DrawSceneDrawer(App& app, int viewW, int viewH) {
    if (app.uiHidden || !app.drawerOpen) return;

    // 서랍이 열리면 화면 아래쪽을 더 짙게 덮는다 — 미리보기가 우주와 섞이지 않게.
    ImGui::GetBackgroundDrawList()->AddRectFilledMultiColor(
        ImVec2(0.0f, (float)viewH * 0.38f), ImVec2((float)viewW, (float)viewH),
        IM_COL32(6, 4, 10, 0),   IM_COL32(6, 4, 10, 0),
        IM_COL32(6, 4, 10, 240), IM_COL32(6, 4, 10, 240));

    const float cardH = 112.0f;
    const float panelH = cardH + 92.0f;
    const float y = (float)viewH - kBarGap - kBarH - 12.0f - panelH;

    ImGui::SetNextWindowPos(ImVec2(0.0f, y), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2((float)viewW, panelH), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.035f, 0.027f, 0.055f, 0.88f));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(kBarPad, 18.0f));
    ImGui::Begin("##drawer", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);

    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.545f, 0.525f, 0.612f, 1.0f));
    ImGui::TextUnformatted("장면 서랍");
    ImGui::PopStyleColor();
    ImGui::SameLine(0.0f, 12.0f);
    ImGui::TextDisabled("누르면 지금 우주를 버리고 새로 시작합니다");
    {
        const char* hint = "1-5 키 · Esc 닫기";
        const float w = ImGui::CalcTextSize(hint).x;
        ImGui::SameLine(ImGui::GetWindowWidth() - kBarPad - w);
        ImGui::TextDisabled("%s", hint);
    }
    ImGui::Spacing();

    // 카드를 가로로 고르게 편다.
    const float avail = (float)viewW - kBarPad * 2.0f;
    const float gap = 12.0f;
    const float cardW = (avail - gap * (kSceneCount - 1)) / (float)kSceneCount;

    for (int i = 0; i < kSceneCount; ++i) {
        if (i > 0) ImGui::SameLine(0.0f, gap);
        const bool sel = (app.cfg.preset == kScenes[i].p);
        ImGui::PushID(i);
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const bool pressed = ImGui::InvisibleButton("##card", ImVec2(cardW, cardH + 34.0f));
        const bool hov = ImGui::IsItemHovered();

        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 a = p, b(p.x + cardW, p.y + cardH + 34.0f);
        dl->AddRectFilled(a, ImVec2(b.x, p.y + cardH), IM_COL32(0, 0, 0, 255), 12.0f,
                          ImDrawFlags_RoundCornersTop);
        // 그 장면이 실제로 어떻게 깔리는지를 그대로 축소해 보여 준다.
        dl->PushClipRect(a, ImVec2(b.x, p.y + cardH), true);
        DrawScenePreview(dl, ImVec2(p.x + cardW * 0.5f, p.y + cardH * 0.5f),
                         cardW, cardH, i);
        dl->PopClipRect();
        dl->AddRectFilled(ImVec2(a.x, p.y + cardH), b,
                          sel ? IM_COL32(255, 176, 102, 36) : IM_COL32(255, 255, 255, 15),
                          12.0f, ImDrawFlags_RoundCornersBottom);
        dl->AddRect(a, b, sel ? kAccentLine : (hov ? IM_COL32(255,255,255,107) : kGlassLine), 12.0f, 0, 1.0f);

        const ImVec2 tsz = ImGui::CalcTextSize(kScenes[i].name);
        dl->AddText(ImVec2(a.x + 11.0f, p.y + cardH + (34.0f - tsz.y) * 0.5f),
                    sel ? kAccentText : IM_COL32(207, 203, 220, 255), kScenes[i].name);
        char num[4]; snprintf(num, sizeof(num), "%d", i + 1);
        dl->AddText(ImVec2(b.x - 18.0f, p.y + cardH + (34.0f - tsz.y) * 0.5f),
                    sel ? kAccentText : kInkGhost, num);
        ImGui::PopID();

        if (hov) Tip(kScenes[i].help);
        if (pressed) SwitchScene(app, kScenes[i].p);
    }

    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

void DrawBottomBar(App& app, int viewW, int viewH) {
    if (app.uiHidden) return;

    ImGui::SetNextWindowPos(ImVec2(kBarPad, (float)viewH - kBarGap - kBarH), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2((float)viewW - kBarPad * 2.0f, kBarH), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));   // 막대 자체는 배경이 없다
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(5, 0));
    ImGui::Begin("##bar", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);

    ImGui::SetCursorPosY((kBarH - 32.0f) * 0.5f);

    // ── 장면 칩 — 누르면 서랍이 오르내린다 ────────────────────────────────
    {
        const char* name = SceneName(app.cfg.preset);
        const ImVec2 tsz = ImGui::CalcTextSize(name);
        const float w = tsz.x + 34.0f, h = 32.0f;
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const bool pressed = ImGui::InvisibleButton("##scene", ImVec2(w, h));
        const bool hov = ImGui::IsItemHovered();

        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 b(p.x + w, p.y + h);
        if (app.drawerOpen) {
            // 서랍이 열려 있으면 칩이 꽉 찬 주황이 된다 — 지금 무엇이 열려 있는지 한눈에.
            dl->AddRectFilled(p, b, kAccent, 10.0f);
            dl->AddText(ImVec2(p.x + 13.0f, p.y + (h - tsz.y) * 0.5f), IM_COL32(42, 20, 0, 255), name);
            dl->AddText(ImVec2(b.x - 16.0f, p.y + (h - tsz.y) * 0.5f), IM_COL32(92, 50, 8, 255), "v");
        } else {
            dl->AddRectFilled(p, b, hov ? IM_COL32(255, 176, 102, 66) : kAccentSoft, 10.0f);
            dl->AddRect(p, b, kAccentLine, 10.0f);
            dl->AddText(ImVec2(p.x + 13.0f, p.y + (h - tsz.y) * 0.5f), kAccentText, name);
            dl->AddText(ImVec2(b.x - 16.0f, p.y + (h - tsz.y) * 0.5f), IM_COL32(201, 149, 96, 255), "^");
        }
        if (pressed) { app.drawerOpen = !app.drawerOpen; app.shapeDrawerOpen = false; }
        Tip("장면을 고릅니다. Tab 으로도 열립니다.");
    }

    Divider();

    // ── 도구 다섯 ─────────────────────────────────────────────────────────
    {
        // 화면 순서와 Tool 값의 순서가 다르다 — 자주 쓰는 「놓기」를 앞으로 뺐다.
        const Tool order[5] = { Tool::Camera, Tool::AddShape, Tool::Spray, Tool::Well, Tool::Erase };
        const char* tips[5] = {
            "화면 옮기기 — 끌어서 이동, 휠로 확대·축소",
            "놓기 — 고른 모양을 누른 자리에 뿌립니다",
            "뿌리기 — 그 자리 가스를 바깥으로 밉니다",
            "끌기 — 물질을 그쪽으로 당깁니다",
            "지우개 — 그 자리 알갱이를 지웁니다",
        };
        for (int i = 0; i < 5; ++i) {
            if (i > 0) ImGui::SameLine();
            const bool on = (app.tool == order[i]) || (i == 1 && app.shapeDrawerOpen);
            if (ToolButton(tips[i], i, on)) {
                if (i == 1) {
                    // 놓기는 바로 도구가 되지 않는다 — 무엇을 놓을지 먼저 고르게 서랍을 연다.
                    app.shapeDrawerOpen = !app.shapeDrawerOpen;
                    app.drawerOpen = false;
                } else {
                    app.tool = order[i];
                    app.shapeDrawerOpen = false;
                }
            }
            Tip(tips[i]);
        }
    }

    Divider();

    // ── 값 알약 ───────────────────────────────────────────────────────────
    {
        char v[32];
        float drag = 0.0f;
        snprintf(v, sizeof(v), "%.1f\xC3\x97", app.cfg.timeScale);   // × (곱셈 기호)
        // 빠르기만 곱셈이 아니라 덧셈으로 끈다. 표시가 `%.1f` 라 0.1 이 한 눈금인데,
        // 곱셈으로 하면 1.0 근처에서 한 픽셀이 0.008 밖에 못 움직여 눈금을 못 넘긴다.
        const int rs = Pill("speed", "빠르기", v, &drag);
        const ImVec2 aSpeed = ImGui::GetItemRectMin();
        if (rs == 1) ImGui::OpenPopup("##speedpop");
        else if (rs == 2) app.cfg.timeScale = Clampf(app.cfg.timeScale + drag * 0.02f, 0.1f, 10.0f);
        Tip("시간이 흐르는 속도입니다. 좌우로 끌어도 됩니다.");
        AnchorAbove(aSpeed);
        if (ImGui::BeginPopup("##speedpop")) {
            SliderRow("s", "빠르기", &app.cfg.timeScale, 0.1f, 10.0f, "%.1f\xC3\x97", true, 236.0f);
            ImGui::Spacing();
            if (ImGui::Button(app.running ? "멈춤" : "재생")) app.running = !app.running;
            ImGui::SameLine();
            if (ImGui::Button("처음부터")) { app.applyConfig(); app.sim.reset(); }
            ImGui::EndPopup();
        }

        // 「한 번에」 알약은 뺐다. 놓기 서랍이 모양과 개수를 함께 고르는 자리라, 막대에도
        // 같은 값을 두면 두 곳에서 같은 것을 만지게 된다 — 막대에 상주하는 것을 줄이는 것이
        // 이 화면 설계의 핵심이다.

        ImGui::SameLine();
        snprintf(v, sizeof(v), "%.1f", app.view.brightness);
        // 지금 쓰는 컬러맵을 알약 안에 띠로 보여 준다 — RenderField.cu 의 두 맵을
        // 다섯 점으로 훑은 값이다. 밝기를 만질 때 어느 밝기가 무슨 색인지 함께 보인다.
        static const ImU32 kAstro[5] = {
            IM_COL32(0, 0, 0, 255),      IM_COL32(23, 22, 73, 255),  IM_COL32(88, 56, 150, 255),
            IM_COL32(219, 136, 74, 255), IM_COL32(255, 255, 240, 255)
        };
        static const ImU32 kThermal[5] = {
            IM_COL32(0, 0, 0, 255),     IM_COL32(140, 0, 0, 255),    IM_COL32(255, 87, 0, 255),
            IM_COL32(255, 208, 41, 255), IM_COL32(255, 255, 245, 255)
        };
        drag = 0.0f;
        const int rb = Pill("bright", "밝기", v, &drag, false,
                            (app.look == App::Look::Density) ? kAstro : kThermal);
        const ImVec2 aBright = ImGui::GetItemRectMin();
        if (rb == 1) ImGui::OpenPopup("##brightpop");
        else if (rb == 2) {
            app.view.brightness = Clampf(app.view.brightness * expf(drag * 0.010f), 0.05f, 20.0f);
            RememberLook(app);
        }
        Tip("화면이 하얗게 타면 내리고 너무 어두우면 올립니다. 좌우로 끌어도 됩니다.");
        AnchorAbove(aBright);
        if (ImGui::BeginPopup("##brightpop")) {
            // 색은 밀도 하나로 고정이라 고를 것이 없다 — 밝기와 세기만 둔다.
            if (SliderRow("b", "밝기", &app.view.brightness, 0.05f, 20.0f, "%.2f", true, 252.0f))
                RememberLook(app);
            if (SliderRow("g", "희미한 것", &app.view.gamma, 0.4f, 4.0f, "%.2f", false, 252.0f))
                RememberLook(app);
            ImGui::EndPopup();
        }
    }

    // ── 오른쪽 끝 — 설정 · 저장 · 녹화 ────────────────────────────────────
    {
        const float right = ImGui::GetWindowWidth();
        const char* saveLabel = "한 장 저장";
        const char* recLabel = app.recording ? "정지" : "녹화";
        const float wSave = ImGui::CalcTextSize(saveLabel).x + 26.0f;
        const float wRec  = ImGui::CalcTextSize(recLabel).x + 40.0f;
        ImGui::SameLine(right - wSave - wRec - 36.0f - 12.0f);

        // 톱니 — 나머지 값 전부를 한가운데 큰 판으로 연다. 자주 만지지 않는 것들이라
        // 막대에 상주시키면 「평소엔 우주뿐」이 무너진다.
        if (ToolButton("settings", 4, app.settingsOpen)) app.settingsOpen = !app.settingsOpen;
        Tip("설정 — 중력과 시간, 우주의 경계, 보기와 색, 성능, 조작, 저장과 녹화");
        ImGui::SameLine();
        {
            const ImVec2 p = ImGui::GetCursorScreenPos();
            const bool pressed = ImGui::InvisibleButton("##save", ImVec2(wSave, 32.0f));
            const bool hov = ImGui::IsItemHovered();
            ImDrawList* dl = ImGui::GetWindowDrawList();
            if (hov) dl->AddRectFilled(p, ImVec2(p.x + wSave, p.y + 32.0f), IM_COL32(255,255,255,26), 9.0f);
            const ImVec2 t = ImGui::CalcTextSize(saveLabel);
            dl->AddText(ImVec2(p.x + 13.0f, p.y + (32.0f - t.y) * 0.5f), hov ? kInk : kInkDim, saveLabel);
            if (pressed) app.snapshotRequested = true;
            Tip("지금 화면을 captures 폴더에 그림으로 남깁니다.");
        }

        ImGui::SameLine();
        {
            const ImVec2 p = ImGui::GetCursorScreenPos();
            const bool pressed = ImGui::InvisibleButton("##rec", ImVec2(wRec, 32.0f));
            const bool hov = ImGui::IsItemHovered();
            ImDrawList* dl = ImGui::GetWindowDrawList();
            if (hov || app.recording)
                dl->AddRectFilled(p, ImVec2(p.x + wRec, p.y + 32.0f), IM_COL32(255, 90, 90, 46), 9.0f);
            dl->AddCircleFilled(ImVec2(p.x + 15.0f, p.y + 16.0f), 4.0f, kRec, 12);
            const ImVec2 t = ImGui::CalcTextSize(recLabel);
            dl->AddText(ImVec2(p.x + 26.0f, p.y + (32.0f - t.y) * 0.5f), kRecText, recLabel);
            if (pressed) {
                app.recording = !app.recording;
                if (app.recording) { app.recordedFrames = 0; app.frameCounter = 0; }
            }
            Tip(app.recording ? "녹화를 멈춥니다." : "정지할 때까지 매 장면을 그림으로 남깁니다.");
        }
    }

    // 녹화 중에는 막대 둘레가 붉게 물든다. 나머지 UI 는 그대로라
    // 녹화된 그림에는 이 표시가 들어가지 않는다.
    if (app.recording) {
        const ImVec2 a = ImGui::GetWindowPos();
        const ImVec2 b(a.x + ImGui::GetWindowWidth(), a.y + kBarH);
        ImGui::GetWindowDrawList()->AddRect(ImVec2(a.x - 6.0f, a.y - 6.0f), ImVec2(b.x + 6.0f, b.y + 6.0f),
                                            IM_COL32(255, 91, 91, 140), 12.0f, 0, 2.0f);
    }

    ImGui::End();
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor();
}
