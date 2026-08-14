// 설정 창 — View 층.
//
// 화면 한가운데에 뜨는 큰 판이다. 값이 서른 개가 넘어 막대 옆 작은 팝업에는 담기지 않고,
// 무엇보다 **한 자리에 모여 있어야** 무엇을 만질 수 있는지 알 수 있다.
//
// 왼쪽에 여섯 갈래를 세우고 오른쪽에 그 갈래의 값만 보인다. 바꾸면 곧바로 적용되고
// 확인 버튼은 없다 — 다만 알갱이 수·격자처럼 판을 다시 깔아야 하는 것만 아래의
// 「이 설정으로 다시 시작」이 맡는다.
//
// 물리 계산은 하지 않는다. app 의 값을 만질 뿐이고 코어로 넘기는 것은 App::tick 이 한다.
#include "ui/Settings.h"
#include "app/Version.h"

#include "imgui.h"
#include <cmath>
#include <cstdio>
#include <string>

namespace {

// 하단 막대(ui/Board.cpp)와 같은 팔레트다. 두 곳이 서로 다른 색을 쓰면
// 같은 앱이 아닌 것처럼 보인다.
const ImU32 kAccent     = IM_COL32(255, 176, 102, 255);
const ImU32 kAccentText = IM_COL32(255, 196, 138, 255);
const ImU32 kInk        = IM_COL32(255, 255, 255, 255);
const ImU32 kInkDim     = IM_COL32(182, 178, 196, 255);
const ImU32 kInkFaint   = IM_COL32(154, 149, 171, 255);
const ImU32 kInkGhost   = IM_COL32(107, 103, 121, 255);
const ImU32 kPanel      = IM_COL32(14, 13, 18, 250);
const ImU32 kPanelLine  = IM_COL32(255, 255, 255, 26);
const ImU32 kFill       = IM_COL32(255, 255, 255, 18);
const ImU32 kFillHot    = IM_COL32(255, 255, 255, 33);
const ImU32 kTrack      = IM_COL32(255, 255, 255, 33);

constexpr float kPanelW   = 900.0f;
constexpr float kPanelH   = 610.0f;
constexpr float kSideW    = 222.0f;   // 왼쪽 갈래 목록 폭
constexpr float kHeadH    = 58.0f;
constexpr float kFootH    = 68.0f;
constexpr float kRowGap   = 13.0f;

float Clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

// 갈래 이름. 순서가 곧 app.settingsTab 의 번호다.
const char* kTabs[6] = {
    "중력과 시간", "우주의 경계", "보기와 색", "성능", "조작과 단축키", "저장과 녹화"
};

// 값 묶음의 이름표. 본문보다 작고 흐리게 둬서 훑을 때 걸리기만 하고 읽히지는 않게 한다.
void GroupLabel(const char* text) {
    ImGui::Dummy(ImVec2(1.0f, 6.0f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(1.0f, 2.0f));
}

// 오른쪽에 붙는 흐린 한 줄 설명.
void SideNote(const char* text) {
    ImGui::SameLine();
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

// 줄 밑에 붙는 흐린 설명.
void UnderNote(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(1.0f, 2.0f));
}

void Line() {
    ImGui::Dummy(ImVec2(1.0f, 8.0f));
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float w = ImGui::GetContentRegionAvail().x;
    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y), kPanelLine, 1.0f);
    ImGui::Dummy(ImVec2(1.0f, 8.0f));
}

// ── 조절기 한 줄 ─────────────────────────────────────────────────────────
//
// 이름 · 트랙 · 값이 한 줄에 나란히 선다. 이름과 값의 자리를 고정폭으로 잡아
// 여러 줄이 이어질 때 값들이 세로로 맞아떨어지게 한다 — 어긋나면 표가 아니라 목록이 된다.
//
// 위치는 0~1 로만 주고받으므로 선형이든 로그든 정수든 같은 그림을 쓴다.
// enabled 가 false 면 흐리게 그리고 끌리지 않는다.
// 시안에는 있으나 아직 만들지 않은 값들이 그렇다 — 자리를 지우면 무엇이 빠졌는지 알 수 없고,
// 만질 수 있게 두면 만졌는데 아무 일도 안 일어난다. 둘 다 아닌 자리가 「보이지만 못 만짐」이다.
bool Track(const char* id, const char* label, const char* valueText, float* t,
           bool enabled = true, float labelW = 146.0f, float valueW = 88.0f) {
    ImGui::PushID(id);
    const float total = ImGui::GetContentRegionAvail().x;
    const float trackW = total - labelW - valueW - 20.0f;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float rowH = 26.0f;

    ImGui::InvisibleButton("##hit", ImVec2(total, rowH));
    const bool act = ImGui::IsItemActive() && enabled;
    const bool hov = ImGui::IsItemHovered() && enabled;

    bool changed = false;
    if (act) {
        const float x0 = p.x + labelW;
        const float nt = Clampf((ImGui::GetIO().MousePos.x - x0) / trackW, 0.0f, 1.0f);
        if (nt != *t) { *t = nt; changed = true; }
    }

    ImDrawList* dl = ImGui::GetWindowDrawList();
    const float cy = p.y + rowH * 0.5f;
    const ImVec2 lsz = ImGui::CalcTextSize(label);
    const ImVec2 vsz = ImGui::CalcTextSize(valueText);
    dl->AddText(ImVec2(p.x, cy - lsz.y * 0.5f), enabled ? kInkDim : kInkGhost, label);

    const float x0 = p.x + labelW, x1 = x0 + trackW;
    const float gx = x0 + trackW * Clampf(*t, 0.0f, 1.0f);
    dl->AddLine(ImVec2(x0, cy), ImVec2(x1, cy), kTrack, 3.0f);
    if (enabled) {
        dl->AddLine(ImVec2(x0, cy), ImVec2(gx, cy), kAccent, 3.0f);
        dl->AddCircleFilled(ImVec2(gx, cy), (hov || act) ? 7.5f : 6.0f, kInk);
    } else {
        dl->AddLine(ImVec2(x0, cy), ImVec2(gx, cy), IM_COL32(255, 255, 255, 46), 3.0f);
        dl->AddCircleFilled(ImVec2(gx, cy), 6.0f, IM_COL32(255, 255, 255, 71));
    }

    dl->AddText(ImVec2(p.x + total - vsz.x, cy - vsz.y * 0.5f), enabled ? kInk : kInkGhost, valueText);
    ImGui::PopID();
    return changed;
}

bool SliderLine(const char* id, const char* label, float* v, float lo, float hi,
                const char* fmt, bool log = false, bool enabled = true) {
    char val[48]; snprintf(val, sizeof(val), fmt, *v);
    const float c = Clampf(*v, lo, hi);
    float t = log ? (logf(c / lo) / logf(hi / lo)) : ((c - lo) / (hi - lo));
    const bool moved = Track(id, label, val, &t, enabled);
    // 만지지 않았으면 되돌려 쓰지 않는다 — 왕복 변환만으로 값이 깎이는 것을 막는다.
    if (moved) *v = log ? lo * expf(logf(hi / lo) * t) : lo + (hi - lo) * t;
    return moved;
}

bool SliderLineInt(const char* id, const char* label, int* v, int lo, int hi,
                   const char* fmt, bool log = false, bool enabled = true) {
    char val[48]; snprintf(val, sizeof(val), fmt, *v);
    const float flo = (float)lo, fhi = (float)hi;
    const float c = Clampf((float)*v, flo, fhi);
    float t = (hi <= lo) ? 0.0f
            : (log ? (logf(c / flo) / logf(fhi / flo)) : ((c - flo) / (fhi - flo)));
    const bool moved = Track(id, label, val, &t, enabled);
    if (moved) {
        const float nv = log ? flo * expf(logf(fhi / flo) * t) : flo + (fhi - flo) * t;
        *v = (int)(nv + 0.5f);
        if (*v < lo) *v = lo;
        if (*v > hi) *v = hi;
    }
    return moved;
}

// ── 붙어 있는 고르기 ─────────────────────────────────────────────────────
//
// 서로 배타적인 몇 가지를 나란히 붙여 놓는다. 라디오 버튼보다 자리를 덜 먹고,
// 무엇이 후보인지 한눈에 보인다. 못 고르는 것은 흐리게 두고 눌러도 안 바뀐다.
bool Segmented(const char* id, const char* const* names, int n, int* sel,
               const bool* enabled = nullptr, float labelW = 146.0f,
               const char* label = nullptr) {
    ImGui::PushID(id);
    const ImVec2 p = ImGui::GetCursorScreenPos();
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const float h = 30.0f;

    if (label) {
        const ImVec2 lsz = ImGui::CalcTextSize(label);
        dl->AddText(ImVec2(p.x, p.y + (h - lsz.y) * 0.5f), kInkDim, label);
    }

    float x = p.x + (label ? labelW : 0.0f);
    bool changed = false;
    for (int i = 0; i < n; ++i) {
        const float w = ImGui::CalcTextSize(names[i]).x + 26.0f;
        const bool on = (*sel == i);
        const bool can = (!enabled || enabled[i]);

        ImGui::SetCursorScreenPos(ImVec2(x, p.y));
        ImGui::PushID(i);
        if (ImGui::InvisibleButton("##seg", ImVec2(w, h)) && can && !on) { *sel = i; changed = true; }
        const bool hov = ImGui::IsItemHovered() && can;
        ImGui::PopID();

        const ImU32 bg = on ? IM_COL32(255, 255, 255, 33) : (hov ? kFill : IM_COL32(255, 255, 255, 10));
        dl->AddRectFilled(ImVec2(x, p.y), ImVec2(x + w, p.y + h), bg, 7.0f);
        if (on) dl->AddRect(ImVec2(x, p.y), ImVec2(x + w, p.y + h), IM_COL32(255, 255, 255, 46), 7.0f);
        const ImVec2 tsz = ImGui::CalcTextSize(names[i]);
        dl->AddText(ImVec2(x + (w - tsz.x) * 0.5f, p.y + (h - tsz.y) * 0.5f),
                    !can ? kInkGhost : (on ? kInk : kInkFaint), names[i]);
        x += w + 5.0f;
    }
    ImGui::SetCursorScreenPos(ImVec2(p.x, p.y + h + 3.0f));
    ImGui::Dummy(ImVec2(1.0f, 1.0f));
    ImGui::PopID();
    return changed;
}

// ── 켬/끔 카드 ───────────────────────────────────────────────────────────
//
// 제목 아래 한 줄로 「켜면 무엇이 달라지는가」를 적는다. 이름만으로 알 수 있는 것은
// desc 를 비워 한 줄로 둔다. 오른쪽 스위치는 켜면 주황으로 차오른다.
bool Toggle(const char* id, const char* title, const char* desc, bool* v, bool enabled = true) {
    ImGui::PushID(id);
    const float w = ImGui::GetContentRegionAvail().x;
    const float h = desc ? 54.0f : 40.0f;
    const ImVec2 p = ImGui::GetCursorScreenPos();

    const bool pressed = ImGui::InvisibleButton("##hit", ImVec2(w, h)) && enabled;
    if (pressed) *v = !*v;
    const bool hov = ImGui::IsItemHovered() && enabled;

    ImDrawList* dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), hov ? kFillHot : kFill, 9.0f);

    const ImVec2 tsz = ImGui::CalcTextSize(title);
    if (desc) {
        dl->AddText(ImVec2(p.x + 15.0f, p.y + 11.0f), enabled ? kInk : kInkGhost, title);
        dl->AddText(ImVec2(p.x + 15.0f, p.y + 11.0f + tsz.y + 3.0f), kInkGhost, desc);
    } else {
        dl->AddText(ImVec2(p.x + 15.0f, p.y + (h - tsz.y) * 0.5f), enabled ? kInk : kInkGhost, title);
    }

    // 스위치 — 지름만 한 알약 안에서 동그라미가 좌우로 옮겨 간다.
    const float sw = 42.0f, sh = 22.0f;
    const ImVec2 s0(p.x + w - sw - 15.0f, p.y + (h - sh) * 0.5f);
    const ImVec2 s1(s0.x + sw, s0.y + sh);
    dl->AddRectFilled(s0, s1, (*v && enabled) ? kAccent : IM_COL32(255, 255, 255, 33), sh * 0.5f);
    const float kx = *v ? (s1.x - sh * 0.5f - 2.0f) : (s0.x + sh * 0.5f + 2.0f);
    dl->AddCircleFilled(ImVec2(kx, s0.y + sh * 0.5f), sh * 0.5f - 3.0f,
                        (*v && enabled) ? IM_COL32(40, 26, 12, 255) : IM_COL32(255, 255, 255, 128));

    ImGui::Dummy(ImVec2(1.0f, kRowGap - 4.0f));
    ImGui::PopID();
    return pressed;
}

// 채운 버튼 / 테두리 버튼.
bool Btn(const char* id, const char* label, bool filled, float w = 0.0f, bool enabled = true) {
    ImGui::PushID(id);
    const ImVec2 tsz = ImGui::CalcTextSize(label);
    const float bw = (w > 0.0f) ? w : tsz.x + 34.0f;
    const float bh = 36.0f;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const bool pressed = ImGui::InvisibleButton("##b", ImVec2(bw, bh)) && enabled;
    const bool hov = ImGui::IsItemHovered() && enabled;
    ImDrawList* dl = ImGui::GetWindowDrawList();
    if (!enabled) {
        dl->AddRectFilled(p, ImVec2(p.x + bw, p.y + bh), IM_COL32(255, 255, 255, 10), 9.0f);
        dl->AddRect(p, ImVec2(p.x + bw, p.y + bh), IM_COL32(255, 255, 255, 15), 9.0f);
        dl->AddText(ImVec2(p.x + (bw - tsz.x) * 0.5f, p.y + (bh - tsz.y) * 0.5f), kInkGhost, label);
    } else if (filled) {
        dl->AddRectFilled(p, ImVec2(p.x + bw, p.y + bh),
                          hov ? IM_COL32(255, 196, 138, 255) : kAccent, 9.0f);
        dl->AddText(ImVec2(p.x + (bw - tsz.x) * 0.5f, p.y + (bh - tsz.y) * 0.5f),
                    IM_COL32(30, 20, 8, 255), label);
    } else {
        dl->AddRectFilled(p, ImVec2(p.x + bw, p.y + bh), hov ? kFillHot : kFill, 9.0f);
        dl->AddRect(p, ImVec2(p.x + bw, p.y + bh), kPanelLine, 9.0f);
        dl->AddText(ImVec2(p.x + (bw - tsz.x) * 0.5f, p.y + (bh - tsz.y) * 0.5f), kInk, label);
    }
    ImGui::PopID();
    return pressed;
}

// 색 배열 하나를 띠로 보여 주는 고르기 카드. 이름만 늘어놓으면 무슨 색인지 모른다.
bool ColorCard(const char* id, const char* label, const ImU32* stops, bool on, const char* badge) {
    ImGui::PushID(id);
    const float w = ImGui::GetContentRegionAvail().x;
    const float h = 40.0f;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const bool pressed = ImGui::InvisibleButton("##c", ImVec2(w, h));
    const bool hov = ImGui::IsItemHovered();

    ImDrawList* dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h),
                      on ? IM_COL32(255, 176, 102, 26) : (hov ? kFillHot : kFill), 9.0f);
    if (on) dl->AddRect(p, ImVec2(p.x + w, p.y + h), IM_COL32(255, 176, 102, 128), 9.0f);

    const ImVec2 a(p.x + 12.0f, p.y + 12.0f), b(a.x + 108.0f, p.y + h - 12.0f);
    const float step = (b.x - a.x) * 0.25f;
    for (int i = 0; i < 4; ++i)
        dl->AddRectFilledMultiColor(ImVec2(a.x + step * i, a.y), ImVec2(a.x + step * (i + 1), b.y),
                                    stops[i], stops[i + 1], stops[i + 1], stops[i]);
    dl->AddRect(a, b, IM_COL32(255, 255, 255, 41), 3.0f);

    const ImVec2 tsz = ImGui::CalcTextSize(label);
    dl->AddText(ImVec2(b.x + 16.0f, p.y + (h - tsz.y) * 0.5f), on ? kAccentText : kInk, label);
    if (badge) {
        const ImVec2 bsz = ImGui::CalcTextSize(badge);
        dl->AddText(ImVec2(p.x + w - bsz.x - 14.0f, p.y + (h - bsz.y) * 0.5f), kInkGhost, badge);
    }
    ImGui::Dummy(ImVec2(1.0f, 7.0f));
    ImGui::PopID();
    return pressed;
}

// 단축키 표 한 칸.
void KeyCell(const char* key, const char* what, float colW) {
    const ImVec2 p = ImGui::GetCursorScreenPos();
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const ImVec2 ksz = ImGui::CalcTextSize(key);
    const float kw = ksz.x + 16.0f, kh = 22.0f;
    dl->AddRectFilled(ImVec2(p.x, p.y + 2.0f), ImVec2(p.x + kw, p.y + 2.0f + kh),
                      IM_COL32(255, 255, 255, 20), 5.0f);
    dl->AddRect(ImVec2(p.x, p.y + 2.0f), ImVec2(p.x + kw, p.y + 2.0f + kh), kPanelLine, 5.0f);
    dl->AddText(ImVec2(p.x + 8.0f, p.y + 2.0f + (kh - ksz.y) * 0.5f), kAccentText, key);
    dl->AddText(ImVec2(p.x + kw + 12.0f, p.y + 2.0f + (kh - ksz.y) * 0.5f), kInkDim, what);
    ImGui::Dummy(ImVec2(colW, kh + 8.0f));
}

// ── 갈래별 내용 ──────────────────────────────────────────────────────────

void TabGravity(App& app) {
    GroupLabel("중력");
    SliderLine("g", "중력 세기 G", &app.cfg.gravity, 0.05f, 4.0f, "%.2f");
    SliderLine("soft", "뭉침 방지 거리", &app.cfg.softeningCells, 0.5f, 8.0f, "%.1f 칸");

    Line();
    GroupLabel("시간 나아가기");
    SliderLine("dt", "한 칸의 크기", &app.cfg.timeScale, 0.1f, 10.0f, "%.3f", true);
    UnderNote("한 스텝이 너무 크면 알갱이가 튀므로, 위험한 값은 자동으로 잘린다.");

    Line();
    GroupLabel("알갱이끼리");
    // 알갱이가 너무 많으면 판에 움직일 자리가 없어 접촉이 스스로 꺼진다.
    // 켤 수 없는 상태를 감추면 「켰는데 아무 일도 안 일어난다」가 되므로 이유를 적는다.
    const bool fits = ContactFitsCount(app.cfg.particleCount, app.cfg.gridSize);
    if (Toggle("contact", "서로 통과하지 못하게 하기",
               "겹치면 밀어내고 부딪히면 에너지를 잃는다 \xE2\x80\x94 모여서 덩어리가 된다",
               &app.cfg.contactEnabled, fits))
        ApplyAutoGrid(app.cfg);
    if (!fits) UnderNote("알갱이가 너무 많아 지금은 켤 수 없다 \xE2\x80\x94 상한을 낮추면 켜진다.");

    Toggle("halo", "보이지 않는 무게",
           "은하 질량의 80~90% 를 차지하는 암흑물질 \xE2\x80\x94 원반을 감싸 나선팔을 자라게 한다",
           &app.cfg.haloEnabled);
}

void TabBounds(App& app) {
    GroupLabel("판 바깥");
    int edge = (app.cfg.boundary == Boundary::Isolated) ? 0 : 1;
    const char* edges[2] = { "판 끝에서 멈춤", "반대편에서 나옴" };
    if (Segmented("edge", edges, 2, &edge, nullptr, 146.0f, "밖으로 나가면")) {
        if (!app.needsRestart) {
            app.preRestartCount = app.cfg.particleCount;
            app.preRestartGrid  = app.cfg.gridSize;
        }
        app.cfg.boundary = (edge == 0) ? Boundary::Isolated : Boundary::Periodic;
        app.needsRestart = true;
    }
    UnderNote("\"반대편에서 나옴\"은 우주 거미줄처럼 끝없이 이어진 우주를 볼 때 쓴다.");

    Line();
    Toggle("com", "무게중심을 화면 가운데에 붙여두기",
           "은하가 화면 밖으로 흘러가지 않는다", &app.ui.keepCenterOfMass);
}

void TabLook(App& app) {
    // 색은 밀도 하나로 굳혔다.
    //
    // 온도는 상태방정식과 충격 가열이 있어야 뜻이 있는데 그 계산을 하지 않았고, 속도는
    // 점으로 그릴 때만 값이 있었다. 둘 다 「고를 수는 있지만 무엇을 보는지 알 수 없는」
    // 항목이었다 — 고를 것이 하나뿐이면 고르는 자리도 필요 없다.
    static const ImU32 astro[5] = {
        IM_COL32(0, 0, 0, 255), IM_COL32(23, 22, 73, 255), IM_COL32(88, 56, 150, 255),
        IM_COL32(219, 136, 74, 255), IM_COL32(255, 255, 240, 255)
    };
    GroupLabel("색");
    {
        // 지금 쓰는 색 배열을 띠로만 보여 준다. 고르는 것이 아니라 알려 주는 자리다.
        const float w = ImGui::GetContentRegionAvail().x;
        const ImVec2 p = ImGui::GetCursorScreenPos();
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 a(p.x, p.y + 6.0f), b(a.x + 150.0f, p.y + 26.0f);
        const float step = (b.x - a.x) * 0.25f;
        for (int i = 0; i < 4; ++i)
            dl->AddRectFilledMultiColor(ImVec2(a.x + step * i, a.y), ImVec2(a.x + step * (i + 1), b.y),
                                        astro[i], astro[i + 1], astro[i + 1], astro[i]);
        dl->AddRect(a, b, IM_COL32(255, 255, 255, 41), 3.0f);
        const char* lab = "성기면 짙은 남색, 빽빽하면 흰빛";
        const ImVec2 tsz = ImGui::CalcTextSize(lab);
        dl->AddText(ImVec2(b.x + 16.0f, (a.y + b.y) * 0.5f - tsz.y * 0.5f), kInkGhost, lab);
        ImGui::Dummy(ImVec2(w, 34.0f));
    }

    Line();
    SliderLine("psize", "알갱이 크기", &app.ui.pointSizePx, 0.5f, 6.0f, "%.1f px");
    UnderNote("확대할수록 이 크기에서 더 커지고 또렷해진다.");

    int bg = app.ui.background;
    const char* bgs[2] = { "순수 검정", "아주 옅은 보라" };
    if (Segmented("bg", bgs, 2, &bg, nullptr, 146.0f, "배경")) app.ui.background = bg;

    Line();
    Toggle("grid", "계산 격자 겹쳐 보기", nullptr, &app.ui.showGridOverlay);
    Toggle("horizon", "블랙홀 경계 그리기",
           "지평선\xC2\xB7광자 구면\xC2\xB7최소 안정 궤도를 원으로 얹는다", &app.showHorizon);
}

void TabPerf(App& app) {
    // 지금 상태를 한 카드에 모아 맨 위에 둔다 — 아래 값들을 만지는 이유가 여기 있다.
    {
        const float w = ImGui::GetContentRegionAvail().x;
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const float h = 46.0f;
        ImDrawList* dl = ImGui::GetWindowDrawList();
        dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), IM_COL32(255, 255, 255, 13), 9.0f);
        dl->AddRect(p, ImVec2(p.x + w, p.y + h), kPanelLine, 9.0f);

        char big[32], rest[96];
        snprintf(big, sizeof(big), "%.1f", app.fps);
        snprintf(rest, sizeof(rest), "FPS \xC2\xB7 %.1f ms", app.frameMs);
        const ImVec2 bsz = ImGui::CalcTextSize(big);
        // 60 프레임을 넘기면 초록, 30 아래로 떨어지면 주황.
        const ImU32 col = (app.fps >= 55.0f) ? IM_COL32(140, 220, 160, 255)
                        : (app.fps >= 30.0f) ? kAccent : IM_COL32(255, 120, 120, 255);
        dl->AddText(ImVec2(p.x + 16.0f, p.y + (h - bsz.y) * 0.5f), col, big);
        dl->AddText(ImVec2(p.x + 16.0f + bsz.x + 8.0f, p.y + (h - bsz.y) * 0.5f), kInkDim, rest);

        char right[96];
        snprintf(right, sizeof(right), "%d 알 \xC2\xB7 %d\xC2\xB2 격자",
                 app.cfg.particleCount, app.cfg.gridSize);
        const ImVec2 rsz = ImGui::CalcTextSize(right);
        dl->AddText(ImVec2(p.x + w - rsz.x - 16.0f, p.y + (h - rsz.y) * 0.5f), kInkFaint, right);
        ImGui::Dummy(ImVec2(1.0f, h + 10.0f));
    }

    int maxMan = app.cfg.particleCount / 10000; if (maxMan < 1) maxMan = 1;
    int hardMan = app.hardMaxParticles / 10000; if (hardMan < 1) hardMan = 1;
    if (maxMan > hardMan) maxMan = hardMan;
    if (SliderLineInt("cap", "알갱이 상한", &maxMan, 1, hardMan, "%d만", true)) {
        // 만지기 전 값을 한 번만 담아 둔다 — 「그대로 두기」가 여기로 되돌린다.
        if (!app.needsRestart) {
            app.preRestartCount = app.cfg.particleCount;
            app.preRestartGrid  = app.cfg.gridSize;
        }
        app.cfg.particleCount = maxMan * 10000;
        ApplyAutoGrid(app.cfg);
        app.needsRestart = true;
    }
    char note[128];
    snprintf(note, sizeof(note), "이 카드는 %d만까지 올릴 수 있다 \xE2\x80\x94 올리면 다시 시작해야 한다.", hardMan);
    UnderNote(note);

    // 3D 라 한 변을 하나 올릴 때마다 칸이 여덟 배가 된다. 고를 수 있는 값이 훨씬 낮다.
    int g = (app.cfg.gridSize <= 64) ? 0 : (app.cfg.gridSize <= 128) ? 1 : 2;
    const char* grids[3] = { "64\xC2\xB3", "128\xC2\xB3", "256\xC2\xB3" };
    const int gcap = Sim::maxGridSize(app.cfg.boundary);
    const bool canGrid[3] = { true, gcap >= 128, gcap >= 256 };
    if (Segmented("grid", grids, 3, &g, canGrid, 146.0f, "계산 격자")) {
        if (!app.needsRestart) {
            app.preRestartCount = app.cfg.particleCount;
            app.preRestartGrid  = app.cfg.gridSize;
        }
        app.cfg.gridSize = (g == 0) ? 64 : (g == 1) ? 128 : 256;
        app.needsRestart = true;
    }
    ImGui::SameLine();
    SideNote("한 변이다 — 하나 올리면 칸이 여덟 배");

    int cap = app.ui.frameCap;
    const char* caps[3] = { "화면에 맞춤", "60", "무제한" };
    if (Segmented("fcap", caps, 3, &cap, nullptr, 146.0f, "프레임 상한")) app.ui.frameCap = cap;

    Line();
    Toggle("half", "버거우면 절반 해상도로 그리기",
           "움직일 때만 흐려지고 멈추면 선명해진다", &app.ui.halfResWhenBusy);
    Toggle("pause", "창이 뒤에 있으면 멈추기",
           "끄면 다른 창을 보는 동안에도 우주가 계속 흐른다", &app.ui.pauseWhenHidden);
}

void TabInput(App& app) {
    SliderLine("drag", "끌기 민감도", &app.ui.dragSensitivity, 0.2f, 3.0f, "%.1f");
    SliderLine("wheel", "휠 확대 속도", &app.ui.wheelZoomSpeed, 0.2f, 2.0f, "%.1f");

    Line();
    Toggle("winv", "휠 방향 뒤집기", nullptr, &app.ui.wheelInverted);

    Line();
    GroupLabel("단축키");
    const float colW = ImGui::GetContentRegionAvail().x * 0.5f - 6.0f;
    struct KeyRow { const char* k; const char* w; };
    static const KeyRow rows[6][2] = {
        {{"Space", "멈춤 / 재개"},     {"Tab", "장면 서랍"}},
        {{"1-5",   "장면 바로 고르기"}, {"Q W E R T", "도구 다섯"}},
        {{"[ ]",   "빠르기 내리기 / 올리기"}, {"P", "한 장 저장"}},
        {{"Ctrl R","녹화 시작 / 멈춤"}, {"H", "막대까지 숨기기"}},
        {{"Esc",   "설정 닫기"},        {"S", "설정 열기"}},
        {{"", ""}, {"", ""}},
    };
    for (int i = 0; i < 5; ++i) {
        KeyCell(rows[i][0].k, rows[i][0].w, colW);
        ImGui::SameLine();
        KeyCell(rows[i][1].k, rows[i][1].w, colW);
    }
}

void TabSave(App& app) {
    GroupLabel("저장 폴더");
    {
        const float w = ImGui::GetContentRegionAvail().x - 92.0f;
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const float h = 34.0f;
        ImDrawList* dl = ImGui::GetWindowDrawList();
        dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), IM_COL32(255, 255, 255, 13), 8.0f);
        dl->AddRect(p, ImVec2(p.x + w, p.y + h), kPanelLine, 8.0f);
        const char* path = app.ui.saveFolder.empty() ? "(실행 파일 옆)" : app.ui.saveFolder.c_str();
        const ImVec2 tsz = ImGui::CalcTextSize(path);
        dl->AddText(ImVec2(p.x + 12.0f, p.y + (h - tsz.y) * 0.5f), kInkDim, path);
        ImGui::Dummy(ImVec2(w + 8.0f, h));
        ImGui::SameLine();
        if (Btn("browse", "찾기", false, 78.0f)) app.pickSaveFolder = true;
    }

    ImGui::Dummy(ImVec2(1.0f, 8.0f));
    int fmt = app.ui.imageFormat;
    const char* fmts[2] = { "PNG", "JPG" };
    if (Segmented("ifmt", fmts, 2, &fmt, nullptr, 146.0f, "이미지")) app.ui.imageFormat = fmt;

    Line();
    // 녹화는 화면을 한 장씩 PNG 로 남긴다. 이어 붙이는 것은 밖의 도구가 한다.
    int rfps = app.ui.recordFps;
    const char* fpss[2] = { "60", "30" };
    if (Segmented("rfps", fpss, 2, &rfps, nullptr, 146.0f, "초당 장수")) {
        app.ui.recordFps = rfps;
        app.recordEvery = (rfps == 0) ? 1 : 2;
    }

    ImGui::Dummy(ImVec2(1.0f, 6.0f));
    Toggle("noui", "녹화에 UI 넣지 않기", "막대와 판은 영상에 찍히지 않는다", &app.ui.recordWithoutUi);
    Toggle("shutter", "저장할 때 딸깍 소리", nullptr, &app.ui.shutterSound);
}

} // namespace

void DrawSettings(App& app, int viewW, int viewH) {
    if (!app.settingsOpen) return;

    // 뒤를 어둡게 깐다. 설정이 떠 있는 동안은 우주가 배경이 된다.
    ImGui::GetBackgroundDrawList()->AddRectFilled(
        ImVec2(0, 0), ImVec2((float)viewW, (float)viewH), IM_COL32(0, 0, 0, 150));

    const float w = (kPanelW < viewW - 40.0f) ? kPanelW : (float)viewW - 40.0f;
    const float h = (kPanelH < viewH - 40.0f) ? kPanelH : (float)viewH - 40.0f;
    const ImVec2 pos((viewW - w) * 0.5f, (viewH - h) * 0.5f);

    ImGui::SetNextWindowPos(pos);
    ImGui::SetNextWindowSize(ImVec2(w, h));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16.0f);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.055f, 0.051f, 0.070f, 0.985f));
    ImGui::Begin("##settings", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoScrollWithMouse | ImGuiWindowFlags_NoCollapse);

    ImDrawList* dl = ImGui::GetWindowDrawList();
    const ImVec2 o = ImGui::GetWindowPos();

    // ── 머리 ─────────────────────────────────────────────────────────────
    dl->AddLine(ImVec2(o.x, o.y + kHeadH), ImVec2(o.x + w, o.y + kHeadH), kPanelLine, 1.0f);
    dl->AddCircle(ImVec2(o.x + 34.0f, o.y + kHeadH * 0.5f), 9.0f, kAccent, 0, 1.6f);
    dl->AddCircleFilled(ImVec2(o.x + 34.0f, o.y + kHeadH * 0.5f), 3.0f, kAccent);
    dl->AddText(ImVec2(o.x + 54.0f, o.y + kHeadH * 0.5f - 8.0f), kInk, "설정");
    {
        const char* esc = "Esc 닫기";
        const ImVec2 esz = ImGui::CalcTextSize(esc);
        dl->AddText(ImVec2(o.x + w - esz.x - 56.0f, o.y + kHeadH * 0.5f - esz.y * 0.5f), kInkGhost, esc);
        ImGui::SetCursorPos(ImVec2(w - 44.0f, kHeadH * 0.5f - 14.0f));
        if (ImGui::InvisibleButton("##close", ImVec2(28, 28))) app.settingsOpen = false;
        const bool hov = ImGui::IsItemHovered();
        const ImVec2 c(o.x + w - 30.0f, o.y + kHeadH * 0.5f);
        const ImU32 xc = hov ? kInk : kInkFaint;
        dl->AddLine(ImVec2(c.x - 6, c.y - 6), ImVec2(c.x + 6, c.y + 6), xc, 1.6f);
        dl->AddLine(ImVec2(c.x + 6, c.y - 6), ImVec2(c.x - 6, c.y + 6), xc, 1.6f);
    }

    // ── 왼쪽 갈래 ────────────────────────────────────────────────────────
    dl->AddLine(ImVec2(o.x + kSideW, o.y + kHeadH), ImVec2(o.x + kSideW, o.y + h), kPanelLine, 1.0f);
    for (int i = 0; i < 6; ++i) {
        const float ty = kHeadH + 16.0f + i * 46.0f;
        ImGui::SetCursorPos(ImVec2(12.0f, ty));
        ImGui::PushID(i);
        if (ImGui::InvisibleButton("##tab", ImVec2(kSideW - 24.0f, 40.0f))) app.settingsTab = i;
        const bool hov = ImGui::IsItemHovered();
        ImGui::PopID();

        const bool on = (app.settingsTab == i);
        const ImVec2 a(o.x + 12.0f, o.y + ty), b(a.x + kSideW - 24.0f, a.y + 40.0f);
        if (on || hov)
            dl->AddRectFilled(a, b, on ? IM_COL32(255, 176, 102, 26) : kFill, 9.0f);
        if (on) {
            dl->AddRect(a, b, IM_COL32(255, 176, 102, 92), 9.0f);
            // 왼쪽 끝의 짧은 막대 — 지금 어디를 보고 있는지가 눈에 먼저 걸린다.
            dl->AddRectFilled(ImVec2(a.x + 2.0f, a.y + 9.0f), ImVec2(a.x + 5.0f, b.y - 9.0f),
                              kAccent, 2.0f);
        }
        const ImVec2 tsz = ImGui::CalcTextSize(kTabs[i]);
        dl->AddText(ImVec2(a.x + 18.0f, a.y + (40.0f - tsz.y) * 0.5f),
                    on ? kAccentText : kInkDim, kTabs[i]);
    }

    // 왼쪽 아래 — 이 그림을 그리고 있는 카드와 지금 버전.
    {
        const char* dev = app.deviceName.empty() ? "그래픽카드" : app.deviceName.c_str();
        dl->AddText(ImVec2(o.x + 24.0f, o.y + h - 76.0f), kInkGhost, dev);
        char drv[64];
        snprintf(drv, sizeof(drv), "드라이버 %s",
                 app.driverVersion.empty() ? "-" : app.driverVersion.c_str());
        dl->AddText(ImVec2(o.x + 24.0f, o.y + h - 58.0f), kInkGhost, drv);

        // 새 버전은 스스로 받아 갈아 끼우므로(main.cpp) 여기서는 알리기만 한다.
        const UpdateInfo up = app.updater.status();
        char ver[96];
        if (!app.updateError.empty())      snprintf(ver, sizeof(ver), "업데이트 실패");
        else if (app.updateBusy)           snprintf(ver, sizeof(ver), "새 버전 받는 중\xE2\x80\xA6");
        else if (up.available)             snprintf(ver, sizeof(ver), "새 버전 %s", up.latest.c_str());
        else                               snprintf(ver, sizeof(ver), "Stardust %s", STARDUST_VERSION);
        dl->AddText(ImVec2(o.x + 24.0f, o.y + h - 40.0f),
                    up.available ? kAccentText : kInkGhost, ver);
    }

    // ── 오른쪽 내용 ──────────────────────────────────────────────────────
    ImGui::SetCursorPos(ImVec2(kSideW + 28.0f, kHeadH + 18.0f));
    ImGui::BeginChild("##body", ImVec2(w - kSideW - 56.0f, h - kHeadH - kFootH - 26.0f),
                      false, ImGuiWindowFlags_NoBackground);
    switch (app.settingsTab) {
        case 0: TabGravity(app); break;
        case 1: TabBounds(app);  break;
        case 2: TabLook(app);    break;
        case 3: TabPerf(app);    break;
        case 4: TabInput(app);   break;
        default: TabSave(app);   break;
    }
    ImGui::EndChild();

    // ── 발 ───────────────────────────────────────────────────────────────
    dl->AddLine(ImVec2(o.x + kSideW, o.y + h - kFootH), ImVec2(o.x + w, o.y + h - kFootH),
                kPanelLine, 1.0f);
    ImGui::SetCursorPos(ImVec2(kSideW + 28.0f, h - kFootH + 16.0f));
    if (Btn("reset", "기본값으로", false, 128.0f)) app.resetSettingsRequested = true;
    ImGui::SameLine();
    {
        const char* hint = "바꾸면 바로 적용된다 \xE2\x80\x94 확인 버튼은 없다";
        const ImVec2 hsz = ImGui::CalcTextSize(hint);
        const ImVec2 p = ImGui::GetCursorScreenPos();
        dl->AddText(ImVec2(p.x + 12.0f, p.y + (36.0f - hsz.y) * 0.5f), kInkGhost, hint);
    }
    ImGui::SetCursorPos(ImVec2(w - 148.0f, h - kFootH + 16.0f));
    if (Btn("apply", "적용", true, 128.0f)) {
        // 대부분은 이미 반영돼 있다. 판을 다시 깔아야 하는 것을 만졌을 때만 물어본다 —
        // 다시 깔면 지금까지 흘러온 우주가 사라지므로 말없이 해서는 안 된다.
        if (app.needsRestart) app.restartAskOpen = true;
        else app.settingsOpen = false;
    }

    ImGui::End();
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);

    // ── 다시 시작할지 묻는 판 ────────────────────────────────────────────
    if (app.restartAskOpen) {
        ImGui::GetForegroundDrawList()->AddRectFilled(
            ImVec2(0, 0), ImVec2((float)viewW, (float)viewH), IM_COL32(0, 0, 0, 130));

        const float dw = 460.0f, dh = 190.0f;
        ImGui::SetNextWindowPos(ImVec2((viewW - dw) * 0.5f, (viewH - dh) * 0.5f));
        ImGui::SetNextWindowSize(ImVec2(dw, dh));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24, 22));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16.0f);
        ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.075f, 0.070f, 0.092f, 0.99f));
        ImGui::Begin("##restartask", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                     ImGuiWindowFlags_NoCollapse);

        ImGui::TextUnformatted("판을 다시 깔아야 반영됩니다");
        ImGui::Dummy(ImVec2(1, 6));
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
        ImGui::TextWrapped("알갱이 수\xC2\xB7격자\xC2\xB7경계는 판을 새로 깔아야 바뀝니다. "
                           "지금까지 흘러온 우주는 사라집니다.");
        ImGui::PopStyleColor();

        ImGui::SetCursorPos(ImVec2(24.0f, dh - 58.0f));
        if (Btn("keep", "그대로 두기", false, 150.0f)) {
            // 만지기 전 값으로 되돌린다 — 안 그러면 화면의 숫자와 실제가 어긋난 채로 남는다.
            if (app.preRestartCount > 0) app.cfg.particleCount = app.preRestartCount;
            if (app.preRestartGrid  > 0) app.cfg.gridSize      = app.preRestartGrid;
            app.needsRestart = false;
            app.restartAskOpen = false;
        }
        ImGui::SetCursorPos(ImVec2(dw - 24.0f - 190.0f, dh - 58.0f));
        if (Btn("doit", "다시 깔고 적용", true, 190.0f)) {
            app.applyConfig();
            app.sim.reset();
            app.needsRestart = false;
            app.restartAskOpen = false;
            app.settingsOpen = false;
        }

        ImGui::End();
        ImGui::PopStyleColor();
        ImGui::PopStyleVar(2);
    }
}
