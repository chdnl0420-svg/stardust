// 설정 창 — View 층.
//
// 화면 한가운데에 뜨는 큰 판. 왼쪽 여섯 갈래 · 오른쪽 그 갈래의 값.
// 하단 막대(Board)보다 **나중에** 불러야 한다 — 열려 있는 동안 막대 위에 얹혀야 한다.
#pragma once

#include "app/App.h"

void DrawSettings(App& app, int viewW, int viewH);
