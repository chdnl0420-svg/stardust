#include "app/App.h"

void App::init() {
    // 기본값은 설계 F1 — 격자 2048², 고립 경계(은하 시나리오), 나선팔 프리셋.
    cfg.particleCount = 1000000;
    cfg.gridSize      = 2048;
    cfg.preset        = Preset::SpiralDisk;
    cfg.boundary      = Boundary::Isolated;
    sim.init(cfg);
}

void App::applyConfig() {
    // 재할당이 필요한지는 코어가 판단한다. 여기서 미리 비교하면 판정이 두 곳으로 갈린다.
    sim.reconfigure(cfg);
}

void App::tick() {
    if (running || stepOnce) {
        sim.step();
        stepOnce = false;
    }
}

void ApplyPresetDefaults(SimConfig& cfg, Preset preset) {
    cfg.preset = preset;
    // 경계 — 은하 장면은 텅 빈 우주에 홀로 떠 있어야 하고(고립),
    //        우주 구조 형성은 반대편으로 이어지는 우주가 표준이다(주기).
    cfg.boundary = (preset == Preset::CosmicWeb) ? Boundary::Periodic : Boundary::Isolated;

    // 압력 — 충격파는 가스가 부딪혀 서는 현상이라 압력이 있어야 나온다.
    //        나선팔·조석꼬리·구조형성은 무압력 중력계에서 나오는 현상이라 끄는 쪽이 선명하다
    //        (프로토타입 검증에서 확인 — proto/cuda/x5.cu 의 scene 별 pressure 설정).
    cfg.pressureEnabled = (preset == Preset::HeadOnShock);

    // 팽창 — 주기 경계에서만 물리적 의미가 있고, 켠 상태와 끈 상태를 비교하는 것이 목적이라
    //        프리셋 전환 시에는 항상 꺼 두고 사용자가 직접 켜게 한다.
    cfg.expansionEnabled = false;
}
