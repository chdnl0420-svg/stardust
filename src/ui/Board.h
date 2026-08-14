// 화면 위에 얹는 조작부 — View 층.
//
// 상주하는 것은 아래 44px 막대 하나뿐이다. 장면은 막대의 칩을 눌러 여는 서랍에서 고르고,
// 자주 만지지 않는 값은 막대 오른쪽 톱니에서 연다. 기본 상태는 우주뿐이라
// 스크린샷과 녹화가 그대로 그림이 된다.
//
// 물리 계산은 하지 않는다. app.cfg 값을 만질 뿐이고, 코어로 넘기는 것은 App::tick 이 매 프레임 한다.
#pragma once

#include "app/App.h"

// 화면 아래쪽을 어둡게 깔아 막대의 글자가 우주 위에서도 읽히게 한다.
// 막대보다 **먼저** 불러야 한다 — 나중에 부르면 막대를 덮는다.
void DrawBottomScrim(const App& app, int viewW, int viewH);

// 장면 서랍. 열려 있을 때만 그린다. 막대 위에 얹힌다.
void DrawSceneDrawer(App& app, int viewW, int viewH);

// 놓기 서랍 — 무엇을 놓을지 고른다. 고르면 한 번만 놓이고 도구가 화면 옮기기로 돌아간다.
void DrawShapeDrawer(App& app, int viewW, int viewH);

// 하단 막대 — 장면 칩 · 도구 · 값 알약 · 녹화.
void DrawBottomBar(App& app, int viewW, int viewH);

// 서랍의 i 번째 장면으로 갈아탄다(0~6). 숫자키가 이걸 부른다.
void SwitchSceneByIndex(App& app, int index);
