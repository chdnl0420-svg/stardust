// 밀도 격자를 화면에 그린다 — Adapter 층.
// CUDA 커널이 격자를 샘플링해 화면 크기 RGBA 버퍼를 만들고, 그것을 GL 텍스처로 올려 사각형에 붙인다.
//
// 증분 1 은 CUDA↔GL interop 대신 호스트 경유 업로드를 쓴다(implement-note.md 「이탈 항목」).
// 화면 크기(예: 1600×900)만 옮기므로 격자가 4096² 여도 전송량이 약 5.8 MB 로 일정하다.
#pragma once

#include "app/App.h"

struct RenderField {
    void  init();
    void  shutdown();
    // 밀도 격자를 현재 뷰포트에 그린다. gridSize² 개의 float 을 담은 디바이스 포인터를 받는다.
    void  draw(const float* densityDevice, int gridSize,
               int viewW, int viewH, const ViewSettings& view,
               float zoom, float panX, float panY);

private:
    unsigned texId_ = 0;
    int      texW_ = 0, texH_ = 0;
    unsigned char* hostPixels_ = nullptr;   // 호스트 경유 버퍼
    void*    devPixels_ = nullptr;          // 디바이스 RGBA 버퍼
    size_t   devBytes_ = 0;
    void ensureSize(int w, int h);
};
