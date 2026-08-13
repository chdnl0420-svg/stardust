// 설정 보드 — View 층. 시안(design-mockup.html)의 9섹션을 그대로 놓는다.
// 물리 계산을 하지 않는다. 값을 만지고 App::applyConfig() 를 통해 코어에 넘길 뿐이다.
#pragma once

#include "app/App.h"

// 보드를 그린다. 값이 바뀌어 코어 재설정이 필요하면 true 를 돌려준다.
bool DrawBoard(App& app, bool& boardOpen);

// 하단 도구 툴바. 증분 1 에서는 카메라만 동작하고 나머지는 자리만 잡는다.
void DrawToolbar(App& app, int viewW, int viewH);
