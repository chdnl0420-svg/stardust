// 최소 PNG 저장기 — 외부 라이브러리 없이 무압축(stored) PNG 를 쓴다.
//
// 왜 무압축인가: 압축 라이브러리를 앱에 들이지 않기로 했다(design.md O4).
// 파일이 커지지만(1600×900 기준 약 5.8 MB) 저장은 사용자가 누를 때만 일어나고,
// 압축이 필요하면 외부 도구로 다시 말면 된다.
#pragma once

#include <string>

// RGBA8 픽셀(위에서 아래 순서)을 PNG 로 저장한다. 성공하면 true.
bool WritePngRGBA(const std::string& path, const unsigned char* rgba, int width, int height);

// 같은 픽셀을 JPG 로 저장한다. 무압축 PNG 가 한 장에 6 MB 가까이 되므로,
// 여러 장을 남길 때 쓰라고 둔다. 인코더는 윈도우가 이미 갖고 있는 것(GDI+)을 빌려 쓴다 —
// 이 하나 때문에 압축 라이브러리를 앱에 들이지 않는다.
// quality 는 1~100. 성공하면 true.
bool WriteJpgRGBA(const std::string& path, const unsigned char* rgba, int width, int height,
                  int quality = 92);
