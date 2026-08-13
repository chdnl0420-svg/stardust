// 최소 PNG 저장기 — 외부 라이브러리 없이 무압축(stored) PNG 를 쓴다.
//
// 왜 무압축인가: 압축 라이브러리를 앱에 들이지 않기로 했다(design.md O4).
// 파일이 커지지만(1600×900 기준 약 5.8 MB) 저장은 사용자가 누를 때만 일어나고,
// 압축이 필요하면 외부 도구로 다시 말면 된다.
#pragma once

#include <string>

// RGBA8 픽셀(위에서 아래 순서)을 PNG 로 저장한다. 성공하면 true.
bool WritePngRGBA(const std::string& path, const unsigned char* rgba, int width, int height);
