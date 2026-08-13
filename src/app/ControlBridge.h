// 외부에서 앱을 조종하는 제어 채널 — Adapter 층.
//
// 왜 파일로 주고받나: 창이 있는 앱을 자동으로 검증하려면 "설정을 바꾸고 상태를 읽는" 통로가
// 필요한데, 소켓을 열면 방화벽·포트 충돌·권한 문제가 붙는다. 파일은 그런 게 없고
// 붙었다 떨어져도 상태가 남는다.
//
// 규약 (한 줄에 key=value):
//   MCP 서버가 <dir>\cmd.txt 를 쓴다  ->  앱이 읽고 즉시 지운다  ->  처리 후 <dir>\resp.txt 를 쓴다
//   서버는 resp.txt 가 생길 때까지 기다렸다 읽고 지운다.
//
// 명령:
//   cmd=status                                   현재 상태를 돌려준다
//   cmd=set  particleCount=.. gridSize=.. gravity=.. pressure=0|1 ...
//   cmd=preset  preset=spiral|tidal|shock|web|empty
//   cmd=run  running=0|1
//   cmd=step  count=N                            멈춘 상태에서 N 스텝 진행
//   cmd=reset
//   cmd=screenshot  path=<절대경로.raw>          화면을 RGBA raw 로 저장(헤더 뒤 픽셀)
//   cmd=quit
#pragma once

#include <string>
#include "app/App.h"

class ControlBridge {
public:
    // 제어 디렉터리를 만든다. 인자가 비면 %TEMP%\nbody-mcp 를 쓴다.
    void init(const std::string& dirOverride = std::string());

    // 매 프레임 호출한다. 화면을 다 그린 뒤(버퍼 교체 전)에 불러야
    // screenshot 명령이 지금 프레임을 집는다. 종료 명령을 받으면 true.
    bool poll(App& app, int viewW, int viewH);

    const std::string& dir() const { return dir_; }

private:
    std::string dir_, cmdPath_, respPath_;
    bool ready_ = false;

    // 멈춘 상태에서 N 스텝을 진행하라는 요청. 프레임마다 하나씩 소비한다.
    int  pendingSteps_ = 0;

    void writeResponse(const std::string& body) const;
    std::string statusBody(const App& app) const;
    bool saveScreenshot(const std::string& path, int w, int h) const;
};
