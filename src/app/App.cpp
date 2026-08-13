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
