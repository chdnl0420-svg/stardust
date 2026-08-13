// 좌상단 오버레이 — View 층. 읽기만 하고 아무것도 바꾸지 않는다.
#pragma once

#include "app/App.h"

void DrawHud(const App& app);

// 블랙홀 장면에서 지평선·광자 구면·최소 안정 궤도를 화면에 겹쳐 그린다.
// 다른 장면에서는 아무것도 그리지 않는다.
void DrawBlackHoleRings(const App& app, int viewW, int viewH);

// 가스가 뭉쳐 만들어진 천체를 등급별 색으로 겹쳐 그린다.
// 천체 만들기가 꺼진 장면에서는 아무것도 그리지 않는다.
void DrawBodies(const App& app, int viewW, int viewH);
