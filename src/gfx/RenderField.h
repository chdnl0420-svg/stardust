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
    void ensureSize(int w, int h);
};
