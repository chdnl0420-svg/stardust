// 자동 업데이트 — Adapter 층.
//
// 배포 저장소의 최신 릴리스를 확인하고, 새 버전이 있으면 실행 파일만 받아 갈아 끼운다.
// 라이브러리(cufft64_12.dll)는 244 MB 라 매번 받을 수 없어 설치할 때 한 번만 깔고,
// 여기서는 1.2 MB 짜리 실행 파일만 다룬다. 그 라이브러리가 바뀌는 CUDA 판올림 때는
// 릴리스 노트로 알리고 새로 설치받게 한다.
//
// 받아 온 것을 바로 실행하는 기능이라, 받는 곳을 못 박아 둔다(Version.h 의 저장소 주소).
// 주소를 설정 파일이나 명령으로 바꿀 수 있게 두면 그 자리가 곧 아무 프로그램이나
// 내려받아 실행시키는 통로가 된다.
#pragma once

#include <string>
#include <mutex>

struct UpdateInfo {
    bool        available = false;   // 나보다 새 버전이 저장소에 있는가
    bool        checked   = false;   // 확인을 끝냈는가(네트워크 실패도 끝난 것으로 본다)
    std::string latest;              // 저장소의 최신 버전 (예: "0.2.0")
    std::string downloadUrl;         // 새 실행 파일의 주소
    std::string notes;               // 릴리스 설명 첫 줄
    std::string error;               // 확인이 실패한 이유(비어 있으면 성공)
};

class Updater {
public:
    // 백그라운드로 최신 릴리스를 확인한다. 창이 뜨는 것을 네트워크가 막지 않게 스레드로 돈다.
    void startCheck();
    // 지금까지의 확인 결과. 확인이 끝나기 전에는 checked=false 다.
    UpdateInfo status() const;

    // 새 실행 파일을 받아 갈아 끼우고 앱을 다시 띄운다. 성공하면 이 함수 뒤에 앱을 끝내야 한다.
    //
    // 윈도우는 돌고 있는 실행 파일을 덮어쓰지 못한다. 그래서 새 파일을 옆에 받아 두고,
    // 앱이 끝나기를 기다렸다가 바꿔치기하고 다시 띄우는 작은 스크립트를 만들어 넘긴다.
    bool applyUpdate(std::string& err);

    // 업데이트를 적용해 앱을 끝내야 하는가(applyUpdate 가 성공한 뒤 세워진다).
    bool wantsRestart() const { return restart_; }

private:
    // 확인은 다른 스레드에서 채우고 화면은 매 프레임 읽는다 — 그 사이를 잠금으로 막는다.
    mutable std::mutex mu_;
    UpdateInfo info_;
    bool restart_ = false;
};
