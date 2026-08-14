#include "app/Prefs.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <map>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>

namespace {

// %LOCALAPPDATA%\Stardust\settings.ini
//
// 설치 폴더가 아니라 여기에 두는 이유: 설치본은 자동 업데이트가 실행 파일을 갈아 끼우는
// 자리라, 거기 두면 판올림 때 설정이 함께 지워질 수 있다.
std::string PrefsPath(bool createDir) {
    wchar_t* base = nullptr;
    if (SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base) != S_OK || !base) return "";
    char utf8[MAX_PATH * 3] = {0};
    WideCharToMultiByte(CP_UTF8, 0, base, -1, utf8, sizeof(utf8), nullptr, nullptr);
    CoTaskMemFree(base);
    std::string dir = std::string(utf8) + "\\Stardust";
    if (createDir) CreateDirectoryA(dir.c_str(), nullptr);
    return dir + "\\settings.ini";
}

// 아주 작은 키=값 형식. 줄마다 `이름=값` 이고 그 밖의 줄은 무시한다.
// 형식을 단순하게 두는 이유는, 이 파일이 깨져도 앱이 못 뜨는 일이 없어야 하기 때문이다.
std::map<std::string, std::string> ReadAll(const std::string& path) {
    std::map<std::string, std::string> kv;
    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) return kv;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        char* eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        std::string k = line, v = eq + 1;
        while (!v.empty() && (v.back() == '\n' || v.back() == '\r')) v.pop_back();
        if (!k.empty()) kv[k] = v;
    }
    fclose(f);
    return kv;
}

int   GetI(const std::map<std::string, std::string>& kv, const char* k, int d) {
    auto it = kv.find(k); if (it == kv.end()) return d;
    return atoi(it->second.c_str());
}
float GetF(const std::map<std::string, std::string>& kv, const char* k, float d) {
    auto it = kv.find(k); if (it == kv.end()) return d;
    return (float)atof(it->second.c_str());
}
bool  GetB(const std::map<std::string, std::string>& kv, const char* k, bool d) {
    auto it = kv.find(k); if (it == kv.end()) return d;
    return atoi(it->second.c_str()) != 0;
}
std::string GetS(const std::map<std::string, std::string>& kv, const char* k,
                 const std::string& d) {
    auto it = kv.find(k); if (it == kv.end()) return d;
    return it->second;
}

} // namespace

void LoadPrefs(App& app) {
    const std::string path = PrefsPath(false);
    if (path.empty()) return;
    const auto kv = ReadAll(path);
    if (kv.empty()) return;   // 첫 실행

    // 보기 — 밝기·세기·알갱이 크기처럼 취향에 가까운 값들
    app.brightDensity   = GetF(kv, "brightDensity", app.brightDensity);
    app.gammaDensity    = GetF(kv, "gammaDensity",  app.gammaDensity);
    app.view.brightness = app.brightDensity;
    app.view.gamma      = app.gammaDensity;
    app.ui.pointSizePx  = GetF(kv, "pointSize",     app.ui.pointSizePx);
    app.ui.background   = GetI(kv, "background",    app.ui.background);
    app.ui.showGridOverlay = GetB(kv, "gridOverlay", app.ui.showGridOverlay);
    app.showHorizon     = GetB(kv, "showHorizon",   app.showHorizon);

    // 성능
    app.ui.frameCap        = GetI(kv, "frameCap",     app.ui.frameCap);
    app.ui.halfResWhenBusy = GetB(kv, "halfRes",      app.ui.halfResWhenBusy);
    app.ui.pauseWhenHidden = GetB(kv, "pauseHidden",  app.ui.pauseWhenHidden);

    // 조작
    app.ui.dragSensitivity = GetF(kv, "dragSens",   app.ui.dragSensitivity);
    app.ui.wheelZoomSpeed  = GetF(kv, "wheelSpeed", app.ui.wheelZoomSpeed);
    app.ui.wheelInverted   = GetB(kv, "wheelInv",   app.ui.wheelInverted);

    // 저장과 녹화
    app.ui.saveFolder      = GetS(kv, "saveFolder", app.ui.saveFolder);
    app.ui.imageFormat     = GetI(kv, "imageFormat", app.ui.imageFormat);
    app.ui.recordFps       = GetI(kv, "recordFps",   app.ui.recordFps);
    app.ui.recordWithoutUi = GetB(kv, "recordNoUi",  app.ui.recordWithoutUi);
    app.ui.shutterSound    = GetB(kv, "shutter",     app.ui.shutterSound);

    // 판을 다시 깔아야 하는 값들.
    //
    // 여기까지 남기는 이유는, 알갱이 수를 어렵게 맞춰 놓고 다음에 켰을 때 기본값으로
    // 돌아가 있으면 그 조절을 매번 다시 해야 하기 때문이다. 다만 카드가 바뀌었거나
    // 상한이 내려갔을 수 있으므로, 읽은 뒤 App::init 의 상한 검사를 그대로 통과시킨다.
    app.cfg.particleCount = GetI(kv, "particleCount", app.cfg.particleCount);
    app.cfg.gridSize      = GetI(kv, "gridSize",      app.cfg.gridSize);
    app.cfg.timeScale     = GetF(kv, "timeScale",     app.cfg.timeScale);
    app.brush.shapeCount  = GetI(kv, "shapeCount",    app.brush.shapeCount);
    app.brush.shapeRadius = GetF(kv, "shapeRadius",   app.brush.shapeRadius);
}

void SavePrefs(const App& app) {
    const std::string path = PrefsPath(true);
    if (path.empty()) return;
    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) return;

    fprintf(f, "# Stardust 설정. 지우면 다음 실행 때 기본값으로 돌아갑니다.\n");
    fprintf(f, "brightDensity=%.4f\n", app.brightDensity);
    fprintf(f, "gammaDensity=%.4f\n",  app.gammaDensity);
    fprintf(f, "pointSize=%.3f\n",     app.ui.pointSizePx);
    fprintf(f, "background=%d\n",      app.ui.background);
    fprintf(f, "gridOverlay=%d\n",     app.ui.showGridOverlay ? 1 : 0);
    fprintf(f, "showHorizon=%d\n",     app.showHorizon ? 1 : 0);
    fprintf(f, "frameCap=%d\n",        app.ui.frameCap);
    fprintf(f, "halfRes=%d\n",         app.ui.halfResWhenBusy ? 1 : 0);
    fprintf(f, "pauseHidden=%d\n",     app.ui.pauseWhenHidden ? 1 : 0);
    fprintf(f, "dragSens=%.3f\n",      app.ui.dragSensitivity);
    fprintf(f, "wheelSpeed=%.3f\n",    app.ui.wheelZoomSpeed);
    fprintf(f, "wheelInv=%d\n",        app.ui.wheelInverted ? 1 : 0);
    fprintf(f, "saveFolder=%s\n",      app.ui.saveFolder.c_str());
    fprintf(f, "imageFormat=%d\n",     app.ui.imageFormat);
    fprintf(f, "recordFps=%d\n",       app.ui.recordFps);
    fprintf(f, "recordNoUi=%d\n",      app.ui.recordWithoutUi ? 1 : 0);
    fprintf(f, "shutter=%d\n",         app.ui.shutterSound ? 1 : 0);
    fprintf(f, "particleCount=%d\n",   app.cfg.particleCount);
    fprintf(f, "gridSize=%d\n",        app.cfg.gridSize);
    fprintf(f, "timeScale=%.4f\n",     app.cfg.timeScale);
    fprintf(f, "shapeCount=%d\n",      app.brush.shapeCount);
    fprintf(f, "shapeRadius=%.4f\n",   app.brush.shapeRadius);
    fclose(f);
}
