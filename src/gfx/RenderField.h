// 화면 그리기 — Adapter 층.
//
// 두 가지 방식을 지원한다.
//   밀도 필드 : 격자 값을 화면 픽셀로 샘플링해 색을 입힌다. 멀리서 볼 때 구조가 잘 보인다.
//   파티클 점 : 파티클 하나하나를 화면에 더한다. 알갱이 느낌이 살고 줌인했을 때 좋다.
//
// 증분 1 은 CUDA↔GL interop 대신 호스트 경유 업로드를 쓴다(implement-note.md 「이탈 항목」).
// 화면 크기(예: 1600×900)만 옮기므로 격자가 4096² 여도 전송량이 약 5.8 MB 로 일정하다.
#pragma once

#include "app/App.h"

struct RenderField {
    void  init();
    void  shutdown();
    // 현재 설정에 맞춰 한 프레임을 그린다.
    void  draw(App& app, int viewW, int viewH);

private:
    unsigned texId_ = 0;
    int      texW_ = 0, texH_ = 0;      // 이번 프레임에 실제로 그리는 크기
    // 버퍼를 잡아 둔 크기. 이보다 작게 그릴 때는 다시 잡지 않고 앞부분만 쓴다 —
    // 매 프레임 잡았다 놓으면 드라이버가 무너진다(RenderField.cu 의 ensureSize 참조).
    int      allocW_ = 0, allocH_ = 0;
    // 지금 절반으로 그리는 중인가, 그리고 몇 프레임 더 그대로 둘 것인가.
    // 문턱 근처에서 매 프레임 뒤집히는 것을 막는다.
    bool     half_ = false;
    int      halfHold_ = 0;
    // 텍스처 저장소를 실제로 잡아 둔 크기. 이 크기가 그대로면 저장소를 다시 만들지 않고
    // 내용만 덮어쓴다(glTexSubImage2D) — 매 프레임 다시 만들면 드라이버가 무너진다.
    int      texAllocW_ = 0, texAllocH_ = 0;
    unsigned char* hostPixels_ = nullptr;   // 호스트 경유 버퍼
    void*    devPixels_ = nullptr;          // 디바이스 RGBA 버퍼
    void*    devAccum_  = nullptr;          // 점 렌더 누적 버퍼(float3)
    size_t   devBytes_ = 0;
    // 앞 프레임의 격자를 남겨 두고 섞는다 — 알갱이가 칸 경계를 넘나들 때 그 자리가
    // 켜졌다 꺼졌다 하는 것을 눌러 준다. 멈춰 세우고 두 프레임을 견주면 픽셀이 하나도
    // 다르지 않으니(실측 0.00%) 떨림은 그리기가 아니라 움직임에서 온다.
    void*    devSmooth_ = nullptr;
    // 온도 합 격자도 **같이** 섞는다. 색이 `온도합 ÷ 밝기` 라, 분모만 섞고 분자를 안 섞으면
    // 두 값이 다른 시각을 가리켜 움직이는 자리마다 색이 튄다.
    void*    devSmoothT_ = nullptr;
    // **성운·먼지가 읽는 격자도 같이 섞는다.** 밝기 격자만 섞고 이쪽을 안 섞으면,
    // 알갱이가 칸 경계를 넘나들 때마다 그 칸의 성운 밝기와 먼지 두께가 통째로 뛰어
    // **네모난 자리가 번쩍인다** — 2026-08-17 에 사용자가 그것을 보고 알렸다.
    // (성운·먼지용 평활 격자 셋을 지웠다 — 2026-08-18. 성운을 걷어내며 함께.)
    int      smoothCells_ = 0;              // 잡아 둔 칸 수(줄어들 때는 다시 잡지 않는다)
    bool     smoothPrimed_ = false;         // 첫 프레임은 섞을 앞 그림이 없다
    // 밝기 기준 — 값이 있는 칸의 평균. 뭉치면 판 대부분이 비므로 「알갱이 수 ÷ 칸 수」로는
    // 화면이 새까매진다. 매 프레임 재되 급변하지 않게 천천히 따라가게 한다.
    void*    devStat_ = nullptr;            // float 합 + int 개수
    float    liveMean_ = 0.0f;
    int      statTick_ = 0;                 // 몇 프레임에 한 번만 잰다(아래 참조)
    // (`drawTick_` 를 지웠다 — 2026-08-18. 펄서 깜빡임이 쓰던 시계였는데 펄서를 08-17 에
    //  뺀 뒤 증가만 하고 읽는 곳이 없었다.)
    void ensureSize(int w, int h);
};
