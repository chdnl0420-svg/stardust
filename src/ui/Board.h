// 설정 보드 — View 층. 시안(design-mockup.html)의 9섹션을 그대로 놓는다.
// 물리 계산을 하지 않는다. app.cfg 값을 만질 뿐이고, 코어로 넘기는 것은 App::tick 이 매 프레임 한다.
#pragma once

#include "app/App.h"

// 보드를 그린다.
// 전에는 "코어 재설정이 필요하면 true" 를 돌려줬는데, 위젯마다 그 표시를 손으로 켜야 해서
// 17군데가 빠져 있었다(round-06 리뷰 P1 #1). 지금은 App::tick 이 매 프레임 코어에 동기화하므로
// 보드는 값만 만지고 돌려줄 것이 없다.
void DrawBoard(App& app, bool& boardOpen);

// 하단 도구 툴바. 증분 1 에서는 카메라만 동작하고 나머지는 자리만 잡는다.
void DrawToolbar(App& app, int viewW, int viewH);
