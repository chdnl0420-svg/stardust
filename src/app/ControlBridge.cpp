#include "app/ControlBridge.h"

#include <windows.h>
#include <GL/gl.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <vector>

namespace {

// "key=value" 줄들을 맵으로 읽는다. JSON 파서를 들이지 않으려고 형식을 단순하게 정했다.
std::map<std::string, std::string> parseKV(const std::string& text) {
    std::map<std::string, std::string> kv;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t eq = line.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        kv[line.substr(0, eq)] = line.substr(eq + 1);
    }
    return kv;
}

bool readWholeFile(const std::string& path, std::string& out) {
    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(n > 0 ? (size_t)n : 0);
    if (n > 0) fread(&out[0], 1, (size_t)n, f);
    fclose(f);
    return true;
}

int   getInt(const std::map<std::string, std::string>& kv, const char* k, int d) {
    auto it = kv.find(k); return (it == kv.end()) ? d : atoi(it->second.c_str());
}
float getFloat(const std::map<std::string, std::string>& kv, const char* k, float d) {
    auto it = kv.find(k); return (it == kv.end()) ? d : (float)atof(it->second.c_str());
}
bool  has(const std::map<std::string, std::string>& kv, const char* k) {
    return kv.find(k) != kv.end();
}

const char* presetSlug(Preset p) {
    switch (p) {
        case Preset::SpiralDisk:  return "spiral";
        case Preset::TidalPair:   return "tidal";
        case Preset::HeadOnShock: return "shock";
        case Preset::CosmicWeb:   return "web";
        default:                  return "empty";
    }
}

bool parsePreset(const std::string& s, Preset& out) {
    if (s == "spiral") { out = Preset::SpiralDisk;  return true; }
    if (s == "tidal")  { out = Preset::TidalPair;   return true; }
    if (s == "shock")  { out = Preset::HeadOnShock; return true; }
    if (s == "web")    { out = Preset::CosmicWeb;   return true; }
    if (s == "empty")  { out = Preset::Empty;       return true; }
    return false;
}

} // namespace

void ControlBridge::init(const std::string& dirOverride) {
    if (!dirOverride.empty()) {
        dir_ = dirOverride;
    } else {
        char buf[MAX_PATH]{};
        DWORD n = GetTempPathA(MAX_PATH, buf);
        dir_ = std::string(buf, n) + "nbody-mcp";
    }
    CreateDirectoryA(dir_.c_str(), nullptr);
    cmdPath_  = dir_ + "\\cmd.txt";
    respPath_ = dir_ + "\\resp.txt";
    // 앞선 실행이 남긴 찌꺼기를 지운다. 안 지우면 뜨자마자 옛 명령을 실행한다.
    DeleteFileA(cmdPath_.c_str());
    DeleteFileA(respPath_.c_str());

    // 서버가 디렉터리를 찾을 수 있게 표식을 남긴다.
    std::string ready = dir_ + "\\ready.txt";
    FILE* f = nullptr;
    if (fopen_s(&f, ready.c_str(), "wb") == 0 && f) {
        fprintf(f, "pid=%lu\n", GetCurrentProcessId());
        fclose(f);
    }
    ready_ = true;
}

void ControlBridge::writeResponse(const std::string& body) const {
    // 임시 이름으로 다 쓴 뒤 옮긴다 — 서버가 반쯤 쓰인 파일을 읽는 것을 막는다.
    std::string tmp = respPath_ + ".tmp";
    FILE* f = nullptr;
    if (fopen_s(&f, tmp.c_str(), "wb") != 0 || !f) return;
    fwrite(body.data(), 1, body.size(), f);
    fclose(f);
    MoveFileExA(tmp.c_str(), respPath_.c_str(), MOVEFILE_REPLACE_EXISTING);
}

std::string ControlBridge::statusBody(const App& app) const {
    Sim& sim = const_cast<Sim&>(app.sim);
    SimTimings t = app.sim.timings();

    // 세 측정은 반드시 이 순서로, 인자 안이 아니라 여기서 부른다.
    // measureTotalGridMass 가 현재 파티클 위치로 밀도 격자를 다시 채우고, 나머지 둘이 그 결과를 읽는다.
    // C++ 는 함수 인자의 평가 순서를 정해두지 않아, snprintf 인자 안에서 부르면
    // 격자 갱신이 마지막에 실행돼 최대밀도·점유셀이 이전 프레임 값을 읽는다(실측으로 확인).
    const double totalMass     = sim.measureTotalGridMass();
    const double maxDensity    = sim.measureMaxDensity();
    const int    occupiedCells = sim.measureOccupiedCells();

    char buf[1400];
    snprintf(buf, sizeof(buf),
        "ok=1\n"
        "fps=%.2f\nframeMs=%.3f\n"
        "particleCount=%d\ngridSize=%d\n"
        "boundary=%s\nlaw=%s\npreset=%s\n"
        "gravity=%.4f\nsofteningCells=%.3f\ntimeScale=%.3f\nsortInterval=%d\n"
        "pressure=%d\npressureK=%.4f\ngamma=%.3f\n"
        "temperature=%d\ncooling=%d\nstarFormation=%d\nexpansion=%d\n"
        "running=%d\nsimTime=%.5f\n"
        "stepMs=%.4f\nscatterMs=%.4f\npoissonMs=%.4f\ngatherMs=%.4f\ngasMs=%.4f\n"
        "substeps=%d\ndtUsed=%.6f\nmaxSpeed=%.4f\n"
        "totalMass=%.1f\nmaxDensity=%.2f\noccupiedCells=%d\n"
        "vramFreeMB=%.0f\n",
        app.fps, app.frameMs,
        app.sim.particleCount(), app.sim.gridSize(),
        app.cfg.boundary == Boundary::Isolated ? "isolated" : "periodic",
        app.cfg.law == GravityLaw::InverseSquare ? "inverse_square" : "inverse_r",
        presetSlug(app.cfg.preset),
        app.cfg.gravity, app.cfg.softeningCells, app.cfg.timeScale, app.cfg.sortInterval,
        app.cfg.pressureEnabled ? 1 : 0, app.cfg.pressureK, app.cfg.gamma,
        app.cfg.temperatureEnabled ? 1 : 0, app.cfg.coolingEnabled ? 1 : 0,
        app.cfg.starFormationEnabled ? 1 : 0, app.cfg.expansionEnabled ? 1 : 0,
        app.running ? 1 : 0, app.sim.simTime(),
        t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs, t.gasMs,
        t.substeps, t.dtUsed, t.maxSpeed,
        totalMass, maxDensity, occupiedCells,
        Sim::deviceFreeBytes() / 1048576.0);
    return buf;
}

// 화면을 RGBA raw 로 저장한다. PNG 인코더를 앱에 넣지 않으려고 변환은 MCP 서버에 맡긴다
// (Node 는 zlib 이 내장이라 PNG 를 만들기 쉽다). 헤더는 "NBRAW1 <w> <h>\n" 한 줄.
bool ControlBridge::saveScreenshot(const std::string& path, int w, int h) const {
    if (w <= 0 || h <= 0) return false;
    std::vector<unsigned char> px((size_t)w * h * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadBuffer(GL_BACK);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());

    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) return false;
    char head[64];
    int hn = snprintf(head, sizeof(head), "NBRAW1 %d %d\n", w, h);
    fwrite(head, 1, (size_t)hn, f);
    // OpenGL 은 아래에서 위로 읽으므로 줄 순서를 뒤집어 저장한다(위가 먼저).
    for (int y = h - 1; y >= 0; --y)
        fwrite(px.data() + (size_t)y * w * 4, 1, (size_t)w * 4, f);
    fclose(f);
    return true;
}

bool ControlBridge::poll(App& app, int viewW, int viewH) {
    if (!ready_) return false;

    // 멈춘 상태에서 요청받은 스텝을 프레임마다 하나씩 소비한다.
    if (pendingSteps_ > 0) {
        app.stepOnce = true;
        --pendingSteps_;
    }

    std::string text;
    if (!readWholeFile(cmdPath_, text)) return false;
    DeleteFileA(cmdPath_.c_str());          // 같은 명령을 두 번 실행하지 않도록 즉시 지운다

    auto kv = parseKV(text);
    auto it = kv.find("cmd");
    if (it == kv.end()) { writeResponse("ok=0\nerror=cmd 키가 없습니다\n"); return false; }
    const std::string cmd = it->second;

    if (cmd == "status") {
        writeResponse(statusBody(app));
        return false;
    }

    if (cmd == "set") {
        bool needApply = false;
        if (has(kv, "particleCount")) {
            int n = getInt(kv, "particleCount", app.cfg.particleCount);
            if (n > 0) { app.cfg.particleCount = n; needApply = true; }
        }
        if (has(kv, "gridSize")) {
            int g = getInt(kv, "gridSize", app.cfg.gridSize);
            // 격자는 2의 거듭제곱만 쓴다(주기 wrap 을 비트 마스크로 처리하기 때문).
            if (g == 1024 || g == 2048 || g == 4096) { app.cfg.gridSize = g; needApply = true; }
        }
        if (has(kv, "boundary")) {
            app.cfg.boundary = (kv["boundary"] == "periodic") ? Boundary::Periodic
                                                              : Boundary::Isolated;
            needApply = true;
        }
        if (has(kv, "law"))
            app.cfg.law = (kv["law"] == "inverse_r") ? GravityLaw::InverseR
                                                     : GravityLaw::InverseSquare;
        if (has(kv, "gravity"))        app.cfg.gravity        = getFloat(kv, "gravity", app.cfg.gravity);
        if (has(kv, "softeningCells")) app.cfg.softeningCells = getFloat(kv, "softeningCells", app.cfg.softeningCells);
        if (has(kv, "timeScale"))      app.cfg.timeScale      = getFloat(kv, "timeScale", app.cfg.timeScale);
        if (has(kv, "sortInterval"))   app.cfg.sortInterval   = getInt(kv, "sortInterval", app.cfg.sortInterval);
        if (has(kv, "pressure"))       app.cfg.pressureEnabled = getInt(kv, "pressure", 1) != 0;
        if (has(kv, "pressureK"))      app.cfg.pressureK      = getFloat(kv, "pressureK", app.cfg.pressureK);
        if (has(kv, "gamma"))          app.cfg.gamma          = getFloat(kv, "gamma", app.cfg.gamma);
        if (has(kv, "temperature"))    app.cfg.temperatureEnabled = getInt(kv, "temperature", 1) != 0;
        if (has(kv, "brightness"))     app.view.brightness    = getFloat(kv, "brightness", app.view.brightness);
        if (has(kv, "displayGamma"))   app.view.gamma         = getFloat(kv, "displayGamma", app.view.gamma);
        if (has(kv, "hud"))            app.view.showHud       = getInt(kv, "hud", 1) != 0;
        if (has(kv, "colormap")) {
            const std::string& c = kv["colormap"];
            app.view.cmap = (c == "gray") ? ColorMap::Gray
                          : (c == "thermal") ? ColorMap::Thermal : ColorMap::Astro;
        }
        if (has(kv, "zoom")) app.zoom = getFloat(kv, "zoom", app.zoom);
        if (has(kv, "panX")) app.panX = getFloat(kv, "panX", app.panX);
        if (has(kv, "panY")) app.panY = getFloat(kv, "panY", app.panY);

        if (needApply) app.applyConfig();
        writeResponse(statusBody(app));
        return false;
    }

    if (cmd == "preset") {
        Preset p;
        if (!parsePreset(kv["preset"], p)) {
            writeResponse("ok=0\nerror=모르는 프리셋입니다\n");
            return false;
        }
        // 설정 보드와 같은 규칙을 쓴다 — 경계·압력·팽창을 함께 바꾼다
        ApplyPresetDefaults(app.cfg, p);
        app.applyConfig();
        app.sim.reset();
        app.running = true;
        writeResponse(statusBody(app));
        return false;
    }

    if (cmd == "run") {
        app.running = getInt(kv, "running", 1) != 0;
        writeResponse(statusBody(app));
        return false;
    }

    if (cmd == "step") {
        int c = getInt(kv, "count", 1);
        if (c < 1) c = 1;
        if (c > 100000) c = 100000;
        app.running = false;
        pendingSteps_ = c;
        // 스텝은 프레임에 걸쳐 소비되므로 여기서는 접수만 알린다.
        char buf[128];
        snprintf(buf, sizeof(buf), "ok=1\nqueuedSteps=%d\n", c);
        writeResponse(buf);
        return false;
    }

    if (cmd == "reset") {
        app.sim.reset();
        writeResponse(statusBody(app));
        return false;
    }

    if (cmd == "screenshot") {
        std::string path = kv.count("path") ? kv["path"] : (dir_ + "\\shot.raw");
        bool ok = saveScreenshot(path, viewW, viewH);
        char buf[1024];
        snprintf(buf, sizeof(buf), "ok=%d\npath=%s\nwidth=%d\nheight=%d\n",
                 ok ? 1 : 0, path.c_str(), viewW, viewH);
        writeResponse(buf);
        return false;
    }

    if (cmd == "quit") {
        writeResponse("ok=1\nquitting=1\n");
        return true;
    }

    writeResponse("ok=0\nerror=모르는 명령입니다\n");
    return false;
}
