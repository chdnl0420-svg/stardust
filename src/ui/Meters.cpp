#include "ui/Meters.h"

#include "imgui.h"
#include <cmath>
#include <cstdio>

namespace {

// 하단 막대·설정과 같은 팔레트다.
const ImU32 kAccent    = IM_COL32(255, 176, 102, 255);
const ImU32 kInk       = IM_COL32(255, 255, 255, 255);
const ImU32 kInkDim    = IM_COL32(182, 178, 196, 255);
const ImU32 kInkGhost  = IM_COL32(107, 103, 121, 255);
const ImU32 kLine      = IM_COL32(255, 255, 255, 26);
const ImU32 kGood      = IM_COL32(140, 220, 160, 255);

constexpr int   kBins      = 48;     // 회전곡선을 몇 고리로 나눌지
constexpr float kMaxRadius = 0.45f;  // 판 한가운데에서 이 반지름까지 잰다
constexpr int   kFrameHist = 180;    // 프레임 시간을 몇 개까지 들고 있을지

// 재는 값은 프레임마다 새로 구하지 않는다.
//
// 회전곡선은 알갱이를 전부 훑는 리덕션이라 매 프레임 돌리면 그 자체가 프레임을 먹는다.
// 성능을 보려고 연 창이 성능을 깎으면 앞뒤가 안 맞으므로, 몇 프레임에 한 번만 잰다.
struct Cache {
    float rot[kBins] = {0};
    float rotMax = 1.0f;
    double kinetic = 0.0;
    double kineticFirst = 0.0;
    int    tick = 0;
    float  frames[kFrameHist] = {0};
    int    frameAt = 0;
    bool   primed = false;

    // 살아 있는 알갱이 수. 블랙홀이 삼키거나 지우개로 지우면 줄어드는데, 숫자 하나로는
    // 「지금 줄고 있다」가 안 보인다 — 그 기울기를 봐야 얼마나 빨리 사라지는지 안다.
    float  alive[kFrameHist] = {0};
    float  aliveMax = 1.0f;

    // 초당 프레임 수. 위의 「한 프레임에 걸린 시간」과 같은 것을 뒤집은 값이지만,
    // 읽는 결이 다르다 — 60 에서 얼마나 떨어졌는지는 이쪽이 한눈에 보인다.
    float  fps[kFrameHist] = {0};

    // 견줄 기준으로 잡아 둔 곡선. 「지금을 기준으로」를 누르면 그 순간의 회전곡선이
    // 여기 복사되고, 그 뒤로는 지금 곡선 뒤에 흐리게 함께 그려진다.
    // 설정 하나를 바꾸고 무엇이 달라지는지 보려면 기억이 아니라 눈으로 견줘야 한다.
    float  ref[kBins] = {0};
    bool   hasRef = false;
    char   refNote[64] = {0};
};
Cache g;

// 작은 꺾은선 그래프. 값 배열과 최댓값을 받아 그린다.
// ref 를 주면 그 곡선을 뒤에 흐리게 함께 그린다.
void Plot(const char* label, const float* v, int n, float vmax,
          const char* rightLabel, ImU32 color, float height = 78.0f,
          const float* ref = nullptr) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
    ImGui::TextUnformatted(label);
    ImGui::PopStyleColor();

    const float w = ImGui::GetContentRegionAvail().x;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    ImDrawList* dl = ImGui::GetWindowDrawList();

    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + height), IM_COL32(255, 255, 255, 10), 7.0f);
    // 가로 눈금 셋 — 없으면 곡선이 평평한지 기울었는지 눈으로 가늠하기 어렵다.
    for (int i = 1; i < 4; ++i) {
        const float y = p.y + height * (float)i / 4.0f;
        dl->AddLine(ImVec2(p.x, y), ImVec2(p.x + w, y), kLine, 1.0f);
    }

    if (n > 1 && vmax > 1e-9f) {
        const float dx = w / (float)(n - 1);
        // 기준 곡선을 먼저 깐다 — 뒤에 있어야 지금 곡선이 위로 읽힌다.
        if (ref) {
            for (int i = 0; i + 1 < n; ++i) {
                const float y0 = p.y + height * (1.0f - fminf(ref[i]     / vmax, 1.0f));
                const float y1 = p.y + height * (1.0f - fminf(ref[i + 1] / vmax, 1.0f));
                dl->AddLine(ImVec2(p.x + dx * i, y0), ImVec2(p.x + dx * (i + 1), y1),
                            IM_COL32(255, 255, 255, 71), 1.4f);
            }
        }
        for (int i = 0; i + 1 < n; ++i) {
            const float y0 = p.y + height * (1.0f - fminf(v[i]     / vmax, 1.0f));
            const float y1 = p.y + height * (1.0f - fminf(v[i + 1] / vmax, 1.0f));
            dl->AddLine(ImVec2(p.x + dx * i, y0), ImVec2(p.x + dx * (i + 1), y1), color, 1.8f);
        }
    }

    if (rightLabel) {
        const ImVec2 t = ImGui::CalcTextSize(rightLabel);
        dl->AddText(ImVec2(p.x + w - t.x - 8.0f, p.y + 6.0f), kInkGhost, rightLabel);
    }
    ImGui::Dummy(ImVec2(w, height + 10.0f));
}

void Row(const char* k, const char* v, ImU32 col = kInk) {
    const float w = ImGui::GetContentRegionAvail().x;
    const ImVec2 p = ImGui::GetCursorScreenPos();
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const ImVec2 ks = ImGui::CalcTextSize(k), vs = ImGui::CalcTextSize(v);
    dl->AddText(ImVec2(p.x, p.y), kInkDim, k);
    dl->AddText(ImVec2(p.x + w - vs.x, p.y), col, v);
    ImGui::Dummy(ImVec2(w, ks.y + 6.0f));
}

} // namespace

void DrawMeters(App& app, int viewW, int viewH) {
    if (!app.metersOpen) return;

    // 프레임 시간과 알갱이 수는 매 프레임 쌓는다 — 둘 다 싸고, 튀는 순간을 놓치면 볼 이유가 없다.
    g.frames[g.frameAt] = app.frameMs;
    g.alive[g.frameAt] = (float)app.sim.activeCount();
    g.fps[g.frameAt] = app.fps;
    g.frameAt = (g.frameAt + 1) % kFrameHist;

    // 무거운 측정은 열두 프레임에 한 번.
    if (++g.tick >= 12) {
        g.tick = 0;
        app.sim.measureRotationCurve(g.rot, kBins, kMaxRadius);
        float mx = 1e-6f;
        for (int i = 0; i < kBins; ++i) if (g.rot[i] > mx) mx = g.rot[i];
        // 세로 눈금을 매번 새로 맞추면 곡선이 늘 화면을 꽉 채워 변화가 안 보인다.
        // 천천히 따라가게 두어 「빨라졌다」가 눈에 남게 한다.
        g.rotMax = (g.rotMax <= 0.f) ? mx : (g.rotMax * 0.85f + mx * 0.15f);
        g.kinetic = app.sim.measureKineticEnergy();
        if (!g.primed) { g.kineticFirst = g.kinetic; g.primed = true; }
    }

    const float w = 380.0f;
    const float h = (float)viewH - 150.0f;
    ImGui::SetNextWindowPos(ImVec2((float)viewW - w - 22.0f, 60.0f));
    // 그래프가 셋(프레임 시간·초당 프레임·알갱이 수)이라 그만큼 자리가 든다.
    ImGui::SetNextWindowSize(ImVec2(w, h > 360.0f ? 560.0f : h));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(18, 16));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 14.0f);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.043f, 0.043f, 0.055f, 0.96f));
    ImGui::Begin("##meters", nullptr,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoCollapse);

    // 머리 — 이름과 닫기
    {
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 o = ImGui::GetWindowPos();
        dl->AddText(ImVec2(o.x + 18.0f, o.y + 16.0f), kInk, "재기");
        ImGui::SetCursorPos(ImVec2(w - 40.0f, 12.0f));
        if (ImGui::InvisibleButton("##mclose", ImVec2(26, 26))) app.metersOpen = false;
        const bool hov = ImGui::IsItemHovered();
        const ImVec2 c(o.x + w - 27.0f, o.y + 25.0f);
        const ImU32 xc = hov ? kInk : kInkGhost;
        dl->AddLine(ImVec2(c.x - 5, c.y - 5), ImVec2(c.x + 5, c.y + 5), xc, 1.5f);
        dl->AddLine(ImVec2(c.x + 5, c.y - 5), ImVec2(c.x - 5, c.y + 5), xc, 1.5f);
        ImGui::SetCursorPos(ImVec2(18.0f, 46.0f));
    }

    // ── 회전곡선 ─────────────────────────────────────────────────────────
    {
        char right[64];
        snprintf(right, sizeof(right), "최대 %.3f", g.rotMax);
        Plot("회전곡선 — 중심에서 바깥으로", g.rot, kBins, g.rotMax, right, kAccent,
             78.0f, g.hasRef ? g.ref : nullptr);

        // 견주기 — 지금 곡선을 붙잡아 두고, 설정을 바꾼 뒤 무엇이 달라지는지 겹쳐 본다.
        {
            const float bw = 150.0f, bh = 28.0f;
            const ImVec2 bp = ImGui::GetCursorScreenPos();
            ImDrawList* dl2 = ImGui::GetWindowDrawList();
            ImGui::PushID("ref");
            const bool pressed = ImGui::InvisibleButton("##b", ImVec2(bw, bh));
            const bool hov = ImGui::IsItemHovered();
            ImGui::PopID();
            dl2->AddRectFilled(bp, ImVec2(bp.x + bw, bp.y + bh),
                               hov ? IM_COL32(255, 255, 255, 33) : IM_COL32(255, 255, 255, 18), 7.0f);
            const char* lab = g.hasRef ? "기준 지우기" : "지금을 기준으로";
            const ImVec2 ls = ImGui::CalcTextSize(lab);
            dl2->AddText(ImVec2(bp.x + (bw - ls.x) * 0.5f, bp.y + (bh - ls.y) * 0.5f), kInk, lab);
            if (pressed) {
                if (g.hasRef) { g.hasRef = false; g.refNote[0] = 0; }
                else {
                    for (int i = 0; i < kBins; ++i) g.ref[i] = g.rot[i];
                    g.hasRef = true;
                    snprintf(g.refNote, sizeof(g.refNote), "기준 — 보이지 않는 무게 %s",
                             app.cfg.haloEnabled ? "켬" : "끔");
                }
            }
            if (g.hasRef) {
                const ImVec2 ns = ImGui::CalcTextSize(g.refNote);
                dl2->AddText(ImVec2(bp.x + bw + 12.0f, bp.y + (bh - ns.y) * 0.5f),
                             kInkGhost, g.refNote);
            }
            ImGui::Dummy(ImVec2(bw, bh + 8.0f));
        }

        // 곡선이 평평한지 기울었는지를 숫자 하나로 요약한다.
        // 바깥쪽 3분의 1 평균을 안쪽 3분의 1 평균으로 나눈 값이다.
        float inner = 0.f, outer = 0.f;
        int ni = 0, no = 0;
        for (int i = 0; i < kBins; ++i) {
            if (g.rot[i] <= 0.f) continue;
            if (i < kBins / 3)          { inner += g.rot[i]; ++ni; }
            else if (i >= kBins * 2 / 3) { outer += g.rot[i]; ++no; }
        }
        const float ratio = (ni > 0 && no > 0 && inner > 0.f)
                          ? (outer / no) / (inner / ni) : 0.f;
        char v[64];
        snprintf(v, sizeof(v), "%.2f", ratio);
        // 1 에 가까우면 평평하다 — 보이지 않는 무게가 붙잡고 있다는 뜻이다.
        Row("바깥/안쪽 속도비", v, (ratio > 0.75f) ? kGood : kInk);
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.42f, 0.40f, 0.48f, 1.0f));
        ImGui::TextWrapped(app.cfg.haloEnabled
            ? "1 에 가까우면 회전곡선이 평평하다 \xE2\x80\x94 보이지 않는 무게가 붙잡고 있다."
            : "보이지 않는 무게를 끄면 바깥이 느려져 이 값이 내려간다.");
        ImGui::PopStyleColor();
    }

    ImGui::Dummy(ImVec2(1, 10));
    {
        const ImVec2 p = ImGui::GetCursorScreenPos();
        ImGui::GetWindowDrawList()->AddLine(
            ImVec2(p.x, p.y), ImVec2(p.x + ImGui::GetContentRegionAvail().x, p.y), kLine, 1.0f);
        ImGui::Dummy(ImVec2(1, 10));
    }

    // ── 프레임 시간 ──────────────────────────────────────────────────────
    {
        // 고리버퍼를 시간 순서로 펴서 넘긴다.
        float ordered[kFrameHist];
        for (int i = 0; i < kFrameHist; ++i)
            ordered[i] = g.frames[(g.frameAt + i) % kFrameHist];
        float mx = 16.7f;                       // 60 프레임 선은 늘 보이게 둔다
        for (int i = 0; i < kFrameHist; ++i) if (ordered[i] > mx) mx = ordered[i];

        char right[64];
        snprintf(right, sizeof(right), "최대 %.1f ms", mx);
        Plot("한 프레임에 걸린 시간", ordered, kFrameHist, mx, right,
             (app.frameMs > 24.0f) ? IM_COL32(255, 140, 120, 255) : kGood, 62.0f);

        char v[80];
        snprintf(v, sizeof(v), "%.1f FPS \xC2\xB7 %.1f ms", app.fps, app.frameMs);
        Row("지금", v);
        if (app.guardCappedTo > 0) {
            snprintf(v, sizeof(v), "%d 개로 낮춤", app.guardCappedTo);
            Row("버거워서", v, kAccent);
        }
        if (app.guardHaltedMs > 0.0f) {
            // 타임아웃 직전에 스스로 멈춘 적이 있다. 왜 멈췄는지 모르면 사용자는 앱이
            // 죽은 줄 안다 — 그 자리를 여기 남긴다.
            snprintf(v, sizeof(v), "한 스텝 %.0f ms \xE2\x80\x94 멈춤", app.guardHaltedMs);
            Row("위험해서", v, IM_COL32(255, 140, 120, 255));
        }
    }

    ImGui::Dummy(ImVec2(1, 8));

    // ── 초당 프레임 수 ──────────────────────────────────────────────────
    {
        float ordered[kFrameHist];
        for (int i = 0; i < kFrameHist; ++i)
            ordered[i] = g.fps[(g.frameAt + i) % kFrameHist];
        // 세로 눈금을 60 에 고정한다. 지금 값에 맞춰 늘였다 줄였다 하면 60 이 어디인지
        // 알 수 없어, 떨어진 것인지 원래 그런 것인지 구분되지 않는다.
        float mx = 60.0f;
        for (int i = 0; i < kFrameHist; ++i) if (ordered[i] > mx) mx = ordered[i];

        char right[64];
        snprintf(right, sizeof(right), "%.0f FPS", app.fps);
        Plot("초당 프레임", ordered, kFrameHist, mx, right,
             (app.fps >= 55.0f) ? kGood : (app.fps >= 30.0f) ? kAccent
                                                             : IM_COL32(255, 140, 120, 255),
             62.0f);
    }

    ImGui::Dummy(ImVec2(1, 8));

    // ── 살아 있는 알갱이 수 ──────────────────────────────────────────────
    {
        float ordered[kFrameHist];
        for (int i = 0; i < kFrameHist; ++i)
            ordered[i] = g.alive[(g.frameAt + i) % kFrameHist];
        // 세로 눈금은 설정한 최대 개수로 고정한다. 지금 값에 맞춰 늘였다 줄였다 하면
        // 「줄어들고 있다」가 그래프에서 사라진다 — 그것을 보려고 그리는 그래프다.
        const float cap = (float)(app.cfg.particleCount > 0 ? app.cfg.particleCount : 1);
        g.aliveMax = cap;

        char right[80];
        const int now = app.sim.activeCount();
        snprintf(right, sizeof(right), "%d / %d", now, app.cfg.particleCount);
        Plot("살아 있는 알갱이", ordered, kFrameHist, g.aliveMax, right,
             (now < app.cfg.particleCount) ? kAccent : kGood, 62.0f);

        char v[80];
        const int gone = app.cfg.particleCount - now;
        if (gone > 0) {
            snprintf(v, sizeof(v), "%d 개 (%.1f%%)", gone, 100.0 * gone / cap);
            Row("사라진 것", v, kAccent);
        }
        snprintf(v, sizeof(v), "%d\xC2\xB3", app.cfg.gridSize);
        Row("격자", v);
    }

    ImGui::Dummy(ImVec2(1, 10));
    {
        const ImVec2 p = ImGui::GetCursorScreenPos();
        ImGui::GetWindowDrawList()->AddLine(
            ImVec2(p.x, p.y), ImVec2(p.x + ImGui::GetContentRegionAvail().x, p.y), kLine, 1.0f);
        ImGui::Dummy(ImVec2(1, 10));
    }

    // ── 에너지 ───────────────────────────────────────────────────────────
    {
        char v[80];
        snprintf(v, sizeof(v), "%.4g", g.kinetic);
        Row("운동에너지", v);
        // 처음 대비 몇 배인지. 중력으로 모이면 늘고, 계산이 새면 튄다.
        const double rel = (g.kineticFirst > 1e-12) ? (g.kinetic / g.kineticFirst) : 0.0;
        snprintf(v, sizeof(v), "%.2f 배", rel);
        Row("판을 깔았을 때 대비", v);
        snprintf(v, sizeof(v), "%.7f", app.sim.timings().dtUsed);
        Row("한 스텝의 시간", v);
        snprintf(v, sizeof(v), "%.3f", app.sim.timings().maxSpeed);
        Row("가장 빠른 알갱이", v);
    }

    ImGui::End();
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
}
