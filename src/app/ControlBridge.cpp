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

// 밖에서 들어온 값을 쓸 수 있는 범위로 자른다.
//
// 제어 채널은 파일에서 문자열을 읽어 그대로 숫자로 바꾸므로 무엇이든 들어올 수 있다.
// NaN(숫자가 아님)이나 무한대가 설정에 들어가면 격자 전체로 번지고 — NaN 은 어떤 연산을 거쳐도
// NaN 이라 한 칸만 오염돼도 다음 스텝에 판 전체가 물든다 — 앱을 다시 켜기 전에는 못 돌린다.
// 범위 밖 값도 마찬가지다: 소프트닝 0 은 고립 경계 그린함수의 원점에서 1/0 을 만든다
// (round-06 리뷰 P1 #13). 범위는 설정 보드 슬라이더와 같게 맞춘다.
float clampF(float v, float lo, float hi, float fallback) {
    if (!(v == v)) return fallback;                       // NaN 은 자기 자신과도 다르다
    if (v > 3.0e38f || v < -3.0e38f) return fallback;     // 무한대
    return (v < lo) ? lo : ((v > hi) ? hi : v);
}
int clampI(int v, int lo, int hi) {
    return (v < lo) ? lo : ((v > hi) ? hi : v);
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
    double centroidX = 0.0, centroidY = 0.0;
    sim.measureCentroid(centroidX, centroidY);
    const double meanTemp = sim.measureMeanTemperature();

    char buf[1700];
    snprintf(buf, sizeof(buf),
        "ok=1\n"
        "fps=%.2f\nframeMs=%.3f\n"
        "particleCount=%d\ngridSize=%d\n"
        "boundary=%s\nlaw=%s\npreset=%s\n"
        "gravity=%.4f\nsofteningCells=%.3f\ntimeScale=%.3f\nsortInterval=%d\n"
        "pressure=%d\npressureK=%.4f\ngamma=%.3f\n"
        "temperature=%d\ncooling=%d\nstarFormation=%d\nexpansion=%d\n"
        "running=%d\nsimTime=%.5f\nactiveCount=%d\nstarCount=%d\n"
        // 표시 설정은 set 으로 바꿀 수 있는데 상태에는 없어서 되읽을 방법이 없었다
        // (round-06 QA-2 — 컬러맵·밝기·대비·HUD·줌팬 4항목이 자동 검증 불가로 남았다).
        "renderMode=%s\ncolorBy=%s\ncolormap=%s\n"
        "brightness=%.3f\ndisplayGamma=%.3f\nhud=%d\n"
        "zoom=%.4f\npanX=%.4f\npanY=%.4f\n"
        "recording=%d\nrecordedFrames=%d\n"
        "stepMs=%.4f\nscatterMs=%.4f\npoissonMs=%.4f\ngatherMs=%.4f\ngasMs=%.4f\n"
        // 아직 소비되지 않은 예약 스텝. 밖에서 "요청한 스텝이 다 돌았는지"를 알 유일한 신호다 —
        // 시간으로 어림하면 프레임이 느린 환경에서 덜 돈 채로 성공 응답이 나간다.
        "substeps=%d\ndtUsed=%.6f\nmaxSpeed=%.4f\nstepsPerFrame=%d\npendingSteps=%d\n"
        "totalMass=%.1f\nmaxDensity=%.2f\noccupiedCells=%d\n"
        "centroidX=%.5f\ncentroidY=%.5f\nmeanTemp=%.6f\n"
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
        app.running ? 1 : 0, app.sim.simTime(), app.sim.activeCount(), app.sim.starCount(),
        app.view.mode == RenderMode::Points ? "points" : "field",
        app.view.colorBy == ColorBy::Temperature ? "temperature"
            : app.view.colorBy == ColorBy::Speed ? "speed" : "density",
        app.view.cmap == ColorMap::Gray ? "gray"
            : app.view.cmap == ColorMap::Thermal ? "thermal" : "astro",
        app.view.brightness, app.view.gamma, app.view.showHud ? 1 : 0,
        app.zoom, app.panX, app.panY,
        app.recording ? 1 : 0, app.recordedFrames,
        t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs, t.gasMs,
        t.substeps, t.dtUsed, t.maxSpeed, app.stepsLastFrame, pendingSteps_,
        totalMass, maxDensity, occupiedCells,
        centroidX, centroidY, meanTemp,
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
    // 쓴 바이트 수를 끝까지 확인한다. 중간에 모자라게 써도 성공을 돌려주면
    // MCP 쪽이 잘린 파일을 정상 캡처로 알고 PNG 로 변환한다(round-06 리뷰 P2 #31).
    bool ok = (fwrite(head, 1, (size_t)hn, f) == (size_t)hn);
    // OpenGL 은 아래에서 위로 읽으므로 줄 순서를 뒤집어 저장한다(위가 먼저).
    const size_t rowBytes = (size_t)w * 4;
    for (int y = h - 1; y >= 0 && ok; --y)
        ok = (fwrite(px.data() + (size_t)y * w * 4, 1, rowBytes, f) == rowBytes);
    if (fclose(f) != 0) ok = false;      // 버퍼에 남은 것은 여기서야 실패가 드러난다
    return ok;
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
        if (has(kv, "particleCount")) {
            int n = getInt(kv, "particleCount", app.cfg.particleCount);
            if (n > 0) app.cfg.particleCount = n;
        }
        if (has(kv, "gridSize")) {
            int g = getInt(kv, "gridSize", app.cfg.gridSize);
            // 격자는 2의 거듭제곱만 쓴다(주기 wrap 을 비트 마스크로 처리하기 때문).
            if (g == 1024 || g == 2048 || g == 4096) app.cfg.gridSize = g;
        }
        if (has(kv, "boundary"))
            app.cfg.boundary = (kv["boundary"] == "periodic") ? Boundary::Periodic
                                                              : Boundary::Isolated;
        if (has(kv, "law"))
            app.cfg.law = (kv["law"] == "inverse_r") ? GravityLaw::InverseR
                                                     : GravityLaw::InverseSquare;
        // 아래 범위는 설정 보드 슬라이더와 같다 — 두 입구가 같은 값만 받아야 한 쪽으로만
        // 이상한 값이 들어가는 구멍이 안 생긴다.
        if (has(kv, "gravity"))        app.cfg.gravity        = clampF(getFloat(kv, "gravity", app.cfg.gravity), 0.0f, 2.0f, app.cfg.gravity);
        if (has(kv, "softeningCells")) app.cfg.softeningCells = clampF(getFloat(kv, "softeningCells", app.cfg.softeningCells), 0.5f, 6.0f, app.cfg.softeningCells);
        if (has(kv, "timeScale"))      app.cfg.timeScale      = clampF(getFloat(kv, "timeScale", app.cfg.timeScale), 0.1f, 4.0f, app.cfg.timeScale);
        if (has(kv, "sortInterval"))   app.cfg.sortInterval   = clampI(getInt(kv, "sortInterval", app.cfg.sortInterval), 1, 120);
        if (has(kv, "pressure"))       app.cfg.pressureEnabled = getInt(kv, "pressure", 1) != 0;
        if (has(kv, "pressureK"))      app.cfg.pressureK      = clampF(getFloat(kv, "pressureK", app.cfg.pressureK), 0.0f, 2.0f, app.cfg.pressureK);
        if (has(kv, "gamma"))          app.cfg.gamma          = clampF(getFloat(kv, "gamma", app.cfg.gamma), 1.0f, 2.5f, app.cfg.gamma);
        if (has(kv, "temperature"))    app.cfg.temperatureEnabled = getInt(kv, "temperature", 1) != 0;
        if (has(kv, "cooling"))        app.cfg.coolingEnabled     = getInt(kv, "cooling", 0) != 0;
        if (has(kv, "coolingRate"))    app.cfg.coolingRate        = clampF(getFloat(kv, "coolingRate", app.cfg.coolingRate), 0.0f, 1.0f, app.cfg.coolingRate);
        if (has(kv, "starFormation"))  app.cfg.starFormationEnabled = getInt(kv, "starFormation", 0) != 0;
        if (has(kv, "starDensity"))    app.cfg.starDensityThreshold = clampF(getFloat(kv, "starDensity", app.cfg.starDensityThreshold), 1.0f, 400.0f, app.cfg.starDensityThreshold);
        if (has(kv, "starTemp"))       app.cfg.starTempThreshold  = clampF(getFloat(kv, "starTemp", app.cfg.starTempThreshold), 0.0f, 1.0f, app.cfg.starTempThreshold);
        if (has(kv, "expansion"))      app.cfg.expansionEnabled   = getInt(kv, "expansion", 0) != 0;
        if (has(kv, "hubble"))         app.cfg.hubble             = clampF(getFloat(kv, "hubble", app.cfg.hubble), 0.0f, 1.0f, app.cfg.hubble);
        if (has(kv, "brightness"))     app.view.brightness    = clampF(getFloat(kv, "brightness", app.view.brightness), 0.05f, 8.0f, app.view.brightness);
        if (has(kv, "displayGamma"))   app.view.gamma         = clampF(getFloat(kv, "displayGamma", app.view.gamma), 0.5f, 4.0f, app.view.gamma);
        if (has(kv, "hud"))            app.view.showHud       = getInt(kv, "hud", 1) != 0;
        if (has(kv, "renderMode"))
            app.view.mode = (kv["renderMode"] == "points") ? RenderMode::Points
                                                           : RenderMode::DensityField;
        if (has(kv, "colorBy")) {
            const std::string& c = kv["colorBy"];
            app.view.colorBy = (c == "temperature") ? ColorBy::Temperature
                             : (c == "speed")       ? ColorBy::Speed : ColorBy::Density;
        }
        if (has(kv, "colormap")) {
            const std::string& c = kv["colormap"];
            app.view.cmap = (c == "gray") ? ColorMap::Gray
                          : (c == "thermal") ? ColorMap::Thermal : ColorMap::Astro;
        }
        // 카메라도 같다 — zoom 0 이나 NaN 이 들어가면 화면 변환이 0 으로 나누기가 된다.
        if (has(kv, "zoom")) app.zoom = clampF(getFloat(kv, "zoom", app.zoom), 0.05f, 64.0f, app.zoom);
        if (has(kv, "panX")) app.panX = clampF(getFloat(kv, "panX", app.panX), -8.0f, 8.0f, app.panX);
        if (has(kv, "panY")) app.panY = clampF(getFloat(kv, "panY", app.panY), -8.0f, 8.0f, app.panY);

        // 무엇이 바뀌었든 그 자리에서 코어에 넘긴다.
        // 전에는 파티클 수·격자·경계에서만 넘겨서, 중력·압력·냉각 같은 값을 단독으로 바꾸면
        // 계산에는 안 가는데 아래 statusBody 는 app.cfg 의 새 값을 돌려줘 성공한 것처럼 보였다
        // (round-06 리뷰 P1 #2). 재할당 여부는 Sim::reconfigure 가 판단하므로 항상 불러도 된다.
        app.applyConfig();
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

    // 마우스 도구를 좌표로 직접 부른다 — QA 가 창을 클릭하지 않고도 검증할 수 있게.
    if (cmd == "tool") {
        const std::string what = kv.count("tool") ? kv["tool"] : "";
        const float x = getFloat(kv, "x", 0.5f), y = getFloat(kv, "y", 0.5f);
        const float r = getFloat(kv, "radius", app.brush.radius);
        int result = 0;
        if (what == "shape") {
            ShapeKind k = ShapeKind::RotatingDisk;
            const std::string ks = kv.count("shape") ? kv["shape"] : "disk";
            if (ks == "blob") k = ShapeKind::StaticBlob;
            else if (ks == "ring") k = ShapeKind::GasRing;
            const int cnt = getInt(kv, "count", app.brush.shapeCount);
            const bool orb = getInt(kv, "autoOrbit", app.brush.autoOrbit ? 1 : 0) != 0;
            result = app.sim.addShape(x, y, k, getFloat(kv, "radius", app.brush.shapeRadius),
                                      cnt, orb);
        } else if (what == "spray") {
            app.sim.sprayAt(x, y, r, getFloat(kv, "strength", app.brush.strength));
        } else if (what == "well") {
            app.sim.wellAt(x, y, r, getFloat(kv, "strength", app.brush.strength));
        } else if (what == "erase") {
            result = app.sim.eraseAt(x, y, r);
        } else {
            writeResponse("ok=0\nerror=모르는 도구입니다\n");
            return false;
        }
        std::string body = "affected=" + std::to_string(result) + "\n" + statusBody(app);
        writeResponse(body);
        return false;
    }

    // 앱 자체의 녹화 기능(설정 보드 버튼과 같은 경로)을 켜고 끈다.
    if (cmd == "record") {
        const bool on = getInt(kv, "on", 1) != 0;
        if (on && !app.recording) { app.recordedFrames = 0; app.frameCounter = 0; }
        app.recording = on;
        if (has(kv, "every")) app.recordEvery = getInt(kv, "every", 1);
        writeResponse(statusBody(app));
        return false;
    }
    if (cmd == "snapshot") {
        app.snapshotRequested = true;
        writeResponse("ok=1\nqueued=1\n");
        return false;
    }

    if (cmd == "quit") {
        writeResponse("ok=1\nquitting=1\n");
        return true;
    }

    writeResponse("ok=0\nerror=모르는 명령입니다\n");
    return false;
}
