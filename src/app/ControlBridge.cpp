#include "app/ControlBridge.h"
#include "app/Version.h"

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
        case Preset::CosmicWeb:   return "web";
        case Preset::BlackHole:   return "blackhole";
        default:                  return "empty";
    }
}

bool parsePreset(const std::string& s, Preset& out) {
    if (s == "spiral") { out = Preset::SpiralDisk;  return true; }
    if (s == "tidal")  { out = Preset::TidalPair;   return true; }
    if (s == "web")    { out = Preset::CosmicWeb;   return true; }
    if (s == "blackhole") { out = Preset::BlackHole; return true; }
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
    // 요청 번호를 맨 앞에 붙인다 — 어느 명령에 대한 답인지 서버가 확인할 수 있어야 한다.
    const std::string full = curRid_.empty() ? body : ("rid=" + curRid_ + "\n" + body);
    // 임시 이름으로 다 쓴 뒤 옮긴다 — 서버가 반쯤 쓰인 파일을 읽는 것을 막는다.
    std::string tmp = respPath_ + ".tmp";
    FILE* f = nullptr;
    if (fopen_s(&f, tmp.c_str(), "wb") != 0 || !f) return;
    fwrite(full.data(), 1, full.size(), f);
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
    const BlackHoleState bh = sim.blackHole();

    const UpdateInfo up = app.updater.status();

    // **2100 에서 4096 으로 늘렸다(2026-08-16).**
    //
    // `snprintf` 는 버퍼가 모자라면 **조용히 잘라낸다.** 이 판에서 상태 항목을 열넷 더했더니
    // (simYears·dangerStepMs·meanStarMass·totalAsh·disp 셋·보존량 일곱) 뒤쪽이 통째로
    // 잘려 나갔고, 밖에서는 그 필드가 「없는」 것으로 보였다 — 값이 0 인 것과 구분이 안 된다.
    // 실측에서 보존량이 전부 0 으로 나와 커널을 두 번이나 고쳤는데, 커널은 처음부터
    // 멀쩡했고 잘린 것이 문제였다.
    //
    // **항목을 더할 때는 이 크기를 함께 본다.** 지금 출력이 약 2.4 KB 다.
    char buf[4096];
    // 방향별 분산은 격자 셋을 각각 합치는 일이라 포맷 인자 안에서 부르면 순서가 꼬인다.
    // 미리 받아 둔다.
    double dxx = 0.0, dyy = 0.0, dzz = 0.0;
    app.sim.measureDispersionAxes(dxx, dyy, dzz);
    // 원반의 공간 두께도 커널을 돌리고 `redD` 를 위 셋과 나눠 쓴다 — 포맷 인자 안에서
    // 부르면 평가 순서가 정해져 있지 않아 서로의 축소 버퍼를 덮는다.
    const double diskSigmaZ = app.sim.measureDiskThickness();
    // 벽에 붙은 수도 커널을 돌리고 `redI` 를 다른 측정과 나눠 쓴다 — 포맷 인자 안에서
    // 부르면 평가 순서가 정해져 있지 않아 서로의 축소 버퍼를 덮는다.
    const int atWall = app.sim.wallCount();
    // 보존량도 같은 이유로 미리 받는다 — 커널을 여럿 돌리므로 포맷 인자 안에서 부르면
    // 평가 순서가 정해져 있지 않아 값이 섞인다.
    const Sim::Conservation cons = app.sim.measureConservation();
    const Sim::Emergence    emg  = app.sim.measureEmergence();
    float rot[4] = {0.f, 0.f, 0.f, 0.f};
    app.sim.rotationCurve(rot);

    snprintf(buf, sizeof(buf),
        // GPU 가 실패해 스텝이 전부 무동작이면 ok=0 으로 알린다.
        // 늘 1 을 돌려주면 자동 검증이 멈춘 시뮬레이션을 성공으로 읽는다(round-08 리뷰 A13).
        "ok=%d\nsimFailed=%d\n"
        "fps=%.2f\nframeMs=%.3f\n"
        "particleCount=%d\ngridSize=%d\n"
        "boundary=%s\nlaw=%s\npreset=%s\n"
        "gravity=%.4f\nsofteningCells=%.3f\ntimeScale=%.3f\nsortInterval=%d\n"
        "pressure=%d\npressureK=%.4f\ngamma=%.3f\nstarJeansK=%.1f\n"
        "temperature=%d\ncooling=%d\nstarFormation=%d\nexpansion=%d\n"
        // simYears 는 simTime 을 천문 시간으로 옮긴 값이다(kYearsPerSimUnit).
        // 별의 나이·수명을 밖에서 확인하려면 무차원 시뮬 시간만으로는 안 된다.
        "running=%d\nsimTime=%.5f\nsimYears=%.6g\nactiveCount=%d\nstarCount=%d\n"
        // 표시 설정은 set 으로 바꿀 수 있는데 상태에는 없어서 되읽을 방법이 없었다
        // (round-06 QA-2 — 컬러맵·밝기·대비·HUD·줌팬 4항목이 자동 검증 불가로 남았다).
        "renderMode=%s\ncolorBy=%s\ncolormap=%s\n"
        "brightness=%.3f\ndisplayGamma=%.3f\nhud=%d\n"
        "contact=%d\ncontactStiffness=%.0f\ncontactDamping=%.3f\n"
        // 자동 업데이트 상태. version 은 지금 도는 빌드, latest 는 저장소의 최신이다.
        "version=%s\nupdateChecked=%d\nupdateAvailable=%d\nlatestVersion=%s\nupdateError=%s\n"
        "zoom=%.4f\npanX=%.4f\npanY=%.4f\n"
        "recording=%d\nrecordedFrames=%d\n"
        "stepMs=%.4f\nscatterMs=%.4f\npoissonMs=%.4f\ngatherMs=%.4f\ngasMs=%.4f\n"
        // 아직 소비되지 않은 예약 스텝. 밖에서 "요청한 스텝이 다 돌았는지"를 알 유일한 신호다 —
        // 시간으로 어림하면 프레임이 느린 환경에서 덜 돈 채로 성공 응답이 나간다.
        "substeps=%d\ndtUsed=%.6f\nmaxSpeed=%.4f\nstepsPerFrame=%d\npendingSteps=%d\n"
        "totalMass=%.1f\nmaxDensity=%.2f\noccupiedCells=%d\n"
        "centroidX=%.5f\ncentroidY=%.5f\nmeanTemp=%.6f\n"
        // 블랙홀 — 삼키고 자라는지 밖에서 확인할 유일한 창이다. 화면의 점 하나로는
        // 지평선이 커졌는지 알 수 없다.
        "bhActive=%d\nbhX=%.5f\nbhY=%.5f\nbhRs=%.6f\nbhMass=%.1f\nbhBorn=%d\nbhCount=%d\n"
        // 워치독이 이번 설정에서 몇 ms 를 위험선으로 잡았는지. 이 값이 2000(드라이버 타임아웃)
        // 근처로 올라가면 방어가 사실상 없는 상태라, 밖에서 확인할 수 있어야 한다.
        // 재 사슬이 도는지 밖에서 볼 창. meanStarMass 가 시간에 따라 내려가면 도는 것이다.
        // 방향별 분산. zz 가 xx·yy 보다 작으면 원반이 스스로 납작해지는 중이다.
        "vramFreeMB=%.0f\ndangerStepMs=%.1f\nmeanStarMass=%.3f\ntotalAsh=%.1f\n"
        "dispXX=%.8f\ndispYY=%.8f\ndispZZ=%.8f\n"
        // 그래서 판이 실제로 얼마나 두꺼운가. 씨앗 diskThickness 보다 크게 자라면
        // 두께를 만든 것은 초기 배치가 아니라 압력이다.
        "diskSigmaZ=%.6f\ndiskSeed=%.6f\n"
        // 판 벽에 붙어 있는 수. 벽을 타고 미끄러지는 것이 화면에 보이는데, 그것을 지울지
        // 정하려면 이 값이 시간에 따라 어떻게 변하는지 봐야 한다.
        "atWall=%d\n"
        // 보존량. **gas + star + nova + remnant + 삼킨 수 = 총 알갱이 수** 여야 한다.
        // badValues 는 NaN·무한대 개수로 하나라도 0 이 아니면 실패다.
        // cNeutron 은 cRemnant 안에 든 수다(따로 더하면 총합이 안 맞는다).
        // cDark 는 다섯째 갈래라 총합에 **더해야** 알갱이 수와 맞는다.
        "cGas=%d\ncStar=%d\ncNova=%d\ncRemnant=%d\ncNeutron=%d\ncDark=%d\nbadValues=%d\n"
        "maxCellCount=%d\ntotalMomentum=%.4f\n"
        // 창발 — 코드에 「그렇게 되라」고 안 적은 것들이 나왔는지.
        // spiralM2 가 0.1 을 넘으면 눈에 보이는 두 팔이고, ash 안쪽이 진하면 금속 기울기다.
        "spiralM2=%.4f\nashInner=%.1f\nashMid=%.1f\nashOuter=%.1f\n"
        // 위 재 분포가 착시인지 가르는 값들 — 재를 뿌린 칸 수와 알갱이 분포.
        "ashCellsIn=%d\nashCellsOut=%d\nnInner=%d\nnMid=%d\nnOuter=%d\n"
        // 「폭발 자리에서 새 별이 태어나는가」 — 새로 난 별이 있던 칸의 재 평균과
        // 판 전체의 칸당 재 평균. 앞이 뒤보다 크면 재가 쌓인 자리에서 더 잘 태어난다.
        // cellAsh 는 판 전체 평균이라 매우 작다(128³ 칸으로 나눈다) — 자릿수를 넉넉히 준다.
        "bornAsh=%.3f\ncellAsh=%.6f\n"
        // 회전곡선 — 반지름 네 구간의 평균 접선 속도. 바깥 둘이 안 떨어지면 평평한 것이고,
        // 그것이 암흑물질 헤일로가 실제로 일하고 있다는 신호다.
        "rot1=%.5f\nrot2=%.5f\nrot3=%.5f\nrot4=%.5f\n"
        // 코어가 실제로 들고 있는 값. **밖에서 보낸 설정이 여기까지 왔는지**를 보는 창이다 —
        // `app.cfg` 만 읽으면 코어에 안 갔어도 성공한 것처럼 보인다(round-06 리뷰 P1 #2).
        "coreNebulaK=%.4f\ncoreGlowK=%.4f\ncoreIonizeK=%.4f\ncoreDark=%.4f\n"
        // **나머지 설정도 같은 창으로 낸다(2026-08-18).**
        //
        // 전수조사에서 설정 스물넷을 보내 대조했더니 **열셋은 밖에서 확인할 방법이 없었다.**
        // 그것이 `gridSize` 버그가 숨어 있던 구조적 이유다 — 2D 시절 값만 받아 32/64/128 을
        // 조용히 무시했는데, 값이 코어에 닿았는지 볼 창이 없으니 아무도 못 찾았다. UI 에서는
        // 컨트롤을 움직이면 라벨이 바뀌니 **동작하는 것처럼 보인다.**
        //
        // 위 넷과 같은 `core*` 이름을 쓴다 — 이 접두어가 「코어가 실제로 들고 있는 값」을
        // 뜻하고, `app.cfg` 만 읽으면 코어에 안 갔어도 성공한 것처럼 보인다.
        "coreCoolRate=%.4f\ncoreFormEff=%.5f\ncoreSunMass=%.2f\ncoreKick=%.4f\n"
        "coreAshYield=%.3f\ncoreAshCool=%.3f\ncoreWind=%.4f\ncoreDustTau=%.3f\n"
        "coreAshDiff=%.3f\ncoreBhRs=%.4f\ncoreBhRatio=%.1f\ncoreExplode=%.4f\n"
        "coreSunLife=%.2f\ncoreIonMin=%.2f\n"
        // 분산 텐서의 교차항 ÷ 대각항. 격자를 셋에서 여섯으로 늘릴지 정하는 값이다.
        "dispCross=%.5f\n"
        // 새 별이 재 봉우리의 둘레에서 났는지(껍질) 봉우리 자체에서 났는지(중심).
        "bornShell=%.4f\n",
        Sim::failed() ? 0 : 1, Sim::failed() ? 1 : 0,
        app.fps, app.frameMs,
        app.sim.particleCount(), app.sim.gridSize(),
        app.cfg.boundary == Boundary::Isolated ? "isolated" : "periodic",
        app.cfg.law == GravityLaw::InverseSquare ? "inverse_square" : "inverse_r",
        presetSlug(app.cfg.preset),
        app.cfg.gravity, app.cfg.softeningCells, app.cfg.timeScale, app.cfg.sortInterval,
        app.cfg.pressureEnabled ? 1 : 0, app.cfg.pressureK, app.cfg.gamma, app.cfg.starJeansK,
        app.cfg.temperatureEnabled ? 1 : 0, app.cfg.coolingEnabled ? 1 : 0,
        app.cfg.starFormationEnabled ? 1 : 0, app.cfg.expansionEnabled ? 1 : 0,
        app.running ? 1 : 0, app.sim.simTime(), app.sim.simTime() * kYearsPerSimUnit,
        app.sim.activeCount(), app.sim.starCount(),
        app.view.mode == RenderMode::Points ? "points" : "field",
        // **`Ash` 가 빠져 있어 재 보기가 `density` 로 보고됐다(2026-08-18에 고침).**
        // 실제로는 설정이 됐는데 이 줄이 그것을 표현하지 못해, 밖에서는 「안 먹었다」와
        // 구분되지 않았다. 전수조사(r80)에서 `colorBy=ash` 가 FAIL 로 나온 원인이다 —
        // 기능이 아니라 **보고하는 창이 좁았던 것**이다.
        app.view.colorBy == ColorBy::Dispersion ? "dispersion"
            : app.view.colorBy == ColorBy::Speed ? "speed"
            : app.view.colorBy == ColorBy::Light ? "light"
            : app.view.colorBy == ColorBy::Ash   ? "ash" : "density",
        app.view.cmap == ColorMap::Gray ? "gray"
            : app.view.cmap == ColorMap::Thermal ? "thermal"
            : app.view.cmap == ColorMap::Blackbody ? "blackbody" : "astro",
        app.view.brightness, app.view.gamma, app.view.showHud ? 1 : 0,
        app.cfg.contactEnabled ? 1 : 0, app.cfg.contactStiffness, app.cfg.contactDamping,
        STARDUST_VERSION, up.checked ? 1 : 0, up.available ? 1 : 0,
        up.latest.c_str(), up.error.c_str(),
        app.zoom, app.panX, app.panY,
        app.recording ? 1 : 0, app.recordedFrames,
        t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs, t.gasMs,
        t.substeps, t.dtUsed, t.maxSpeed, app.stepsLastFrame, pendingSteps_,
        totalMass, maxDensity, occupiedCells,
        centroidX, centroidY, meanTemp,
        bh.active ? 1 : 0, bh.x, bh.y, bh.rs, bh.mass, bh.born ? 1 : 0, sim.blackHoleCount(),
        Sim::deviceFreeBytes() / 1048576.0, app.dangerStepMs,
        app.sim.meanStarMass(), app.sim.totalAsh(), dxx, dyy, dzz,
        diskSigmaZ, app.cfg.diskThickness, atWall,
        cons.gas, cons.stars, cons.exploding, cons.remnants, cons.neutronStars,
        cons.darkMatter, cons.bad,
        cons.maxCellCount, cons.momentum,
        emg.spiralM2, emg.ashInner, emg.ashMid, emg.ashOuter,
        emg.ashCellsInner, emg.ashCellsOuter, emg.nInner, emg.nMid, emg.nOuter,
        sim.bornAshMean(),
        // 판 전체의 칸당 재 평균. 격자는 패딩 없이 G³ 다.
        (double)sim.totalAsh() / (double)((double)sim.gridSize() * sim.gridSize() * sim.gridSize()),
        rot[0], rot[1], rot[2], rot[3],
        sim.config().nebulaK, sim.config().starGlowK,
        sim.config().starIonizeK, sim.config().darkMatterFraction,
        // 위 포맷의 `core*` 열넷과 **같은 순서**여야 한다 — 어긋나면 뒤쪽 필드가 통째로
        // 엉뚱한 값이 되고, 그것은 밖에서 0 과 구분되지 않는다.
        sim.config().coolingRate, sim.config().starFormEfficiency,
        sim.config().starSunMass, sim.config().starKickSpeed,
        sim.config().starAshYield, sim.config().ashCoolK,
        sim.config().starWindRate, sim.config().dustExtinctionK,
        sim.config().ashDiffuseK, sim.config().blackHoleRs,
        sim.config().starBHRatio, sim.config().starExplodeSim,
        sim.config().starSunLifeSim, sim.config().nebulaIonMin,
        sim.dispCrossRatio(), sim.bornShellRatio());
    return buf;
}

// 화면을 RGBA raw 로 저장한다. PNG 인코더를 앱에 넣지 않으려고 변환은 MCP 서버에 맡긴다
// (Node 는 zlib 이 내장이라 PNG 를 만들기 쉽다). 헤더는 "NBRAW1 <w> <h>\n" 한 줄.
// 경로를 실제 절대 경로로 펴서 제어 폴더 안인지 본다.
// 문자열만 비교하면 "..\..\Windows\..." 같은 상대 경로가 그대로 통과하므로
// GetFullPathNameA 로 먼저 펴고, Windows 파일 시스템이 대소문자를 안 가리니 낮춰서 비교한다.
bool ControlBridge::isInsideControlDir(const std::string& path) const {
    if (dir_.empty() || path.empty()) return false;
    char full[1024] = { 0 }, root[1024] = { 0 };
    if (!GetFullPathNameA(path.c_str(), (DWORD)sizeof(full), full, nullptr)) return false;
    if (!GetFullPathNameA(dir_.c_str(), (DWORD)sizeof(root), root, nullptr)) return false;

    std::string f(full), r(root);
    for (char& c : f) c = (char)tolower((unsigned char)c);
    for (char& c : r) c = (char)tolower((unsigned char)c);
    if (!r.empty() && r.back() != '\\') r += '\\';
    return f.size() > r.size() && f.compare(0, r.size(), r) == 0;
}

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
    //
    // 차감은 **예약 시점이 아니라 실행이 끝난 뒤**에 한다. poll 은 App::tick 다음에 불리므로,
    // 여기서 세운 stepOnce 는 다음 프레임에야 실행된다 — 예약하면서 바로 빼면
    // 마지막 스텝이 아직 안 돌았는데 pendingSteps=0 으로 응답해, 호출자가 한 스텝 일찍
    // "다 됐다"고 판단한다(round-08 리뷰 A7). App::tick 이 실행하면 stepOnce 가 내려간다.
    if (issuedStep_ && !app.stepOnce) {     // 앞서 예약한 것이 실제로 돌았다
        if (pendingSteps_ > 0) --pendingSteps_;
        issuedStep_ = false;
    }
    if (pendingSteps_ > 0 && !issuedStep_) {
        app.stepOnce = true;
        issuedStep_ = true;
    }

    std::string text;
    if (!readWholeFile(cmdPath_, text)) return false;
    DeleteFileA(cmdPath_.c_str());          // 같은 명령을 두 번 실행하지 않도록 즉시 지운다

    auto kv = parseKV(text);
    // 요청 번호를 응답에 그대로 돌려준다. 이게 없으면 타임아웃된 명령의 늦은 응답을
    // 다음 명령이 자기 것으로 읽는다(round-08 리뷰 B3).
    curRid_ = kv.count("rid") ? kv["rid"] : std::string();
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
            // 보드 슬라이더와 같은 상한을 건다. 여기만 뚫려 있으면 밖에서 보낸 명령 하나로
            // 그래픽카드가 감당 못 하는 설정에 들어갈 수 있다.
            if (n > app.hardMaxParticles) n = app.hardMaxParticles;
            // 격자·소프트닝도 함께 맞춘다. 보드의 개수 슬라이더와 같은 규칙이어야
            // 밖에서 바꾼 뒤의 화면이 안에서 바꾼 것과 달라지지 않는다.
            if (n > 0) { app.cfg.particleCount = n; ApplyAutoGrid(app.cfg); }
        }
        // 격자를 직접 지정하면 자동 선택을 덮어쓴다(그 뒤 개수를 바꾸면 다시 자동으로 돌아간다).
        if (has(kv, "gridSize")) {
            int g = getInt(kv, "gridSize", app.cfg.gridSize);
            // 격자는 2의 거듭제곱만 쓴다(주기 wrap 을 비트 마스크로 처리하기 때문).
            //
            // **2D 시절 값(1024·2048·4096)만 받고 있었다 — 3D 로 옮긴 뒤 안 고쳤다.**
            //
            // 그래서 둘이 동시에 깨져 있었다. 32·64·128 을 보내면 **조용히 무시**돼
            // 격자를 못 바꿨고(2026-08-17 실측: 세 값을 보냈는데 전부 128 로 돌았다),
            // 2048 을 보내면 **그대로 들어갔다** — 3D 에서 2048³ 은 85억 칸이다.
            // 2026-08-14 에 회귀 테스트가 그런 값을 요청했다가 시스템 메모리가 통째로
            // 치솟은 그 경로가 아직 열려 있었다(CLAUDE.md 3번).
            //
            // 최대는 256 이다 — 그 위는 알갱이가 하나도 없어도 한 스텝이 25 ms 다.
            if (g == 32 || g == 64 || g == 128 || g == 256) app.cfg.gridSize = g;
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
        // 원반을 처음 깔 때 주는 두께 **씨앗**이다. 「두께를 손으로 안 정해도 두께가
        // 생기는가」를 대조하려면 이 값을 밖에서 0 과 0.001 로 바꿔 볼 수 있어야 한다.
        // 0 을 허용한다 — 완전 평면이면 z 속도가 전부 0 이라 압력이 부풀릴 것도 없고,
        // 그 대칭이 안 깨지는 것 자체가 결과다(round-10 판단).
        if (has(kv, "diskThickness"))  app.cfg.diskThickness  = clampF(getFloat(kv, "diskThickness", app.cfg.diskThickness), 0.0f, 0.3f, app.cfg.diskThickness);
        // Jeans 상수 — 별 비율을 5% 안팎으로 맞추려면 밖에서 돌려 볼 수 있어야 한다.
        // 상한을 크게 잡는다: σ² 가 잘 식은 자리에서 0.0002 까지 내려가므로 문턱을 올리려면
        // 그만큼 큰 수가 필요하다.
        if (has(kv, "starJeansK"))     app.cfg.starJeansK     = clampF(getFloat(kv, "starJeansK", app.cfg.starJeansK), 0.0f, 1.0e7f, app.cfg.starJeansK);
        // 별 형성 효율 — 가스가 남는 비율을 정하는 값이라 밖에서 스캔할 수 있어야 한다.
        // 1 이면 옛 동작(조건을 만족하면 즉시 전부 별)이라 상한을 거기 둔다.
        if (has(kv, "starFormEfficiency"))
            app.cfg.starFormEfficiency = clampF(getFloat(kv, "starFormEfficiency", app.cfg.starFormEfficiency), 0.0f, 1.0f, app.cfg.starFormEfficiency);
        // 수명·최후를 가르는 값들. 별 비율이 평형에 드는지는 이 넷의 균형이 정하므로
        // 밖에서 돌려 볼 수 있어야 한다.
        if (has(kv, "starSunMass"))    app.cfg.starSunMass    = clampF(getFloat(kv, "starSunMass", app.cfg.starSunMass), 1.0f, 1.0e6f, app.cfg.starSunMass);
        if (has(kv, "starSunLifeSim")) app.cfg.starSunLifeSim = clampF(getFloat(kv, "starSunLifeSim", app.cfg.starSunLifeSim), 0.001f, 1.0e6f, app.cfg.starSunLifeSim);
        if (has(kv, "starExplodeSim")) app.cfg.starExplodeSim = clampF(getFloat(kv, "starExplodeSim", app.cfg.starExplodeSim), 0.0001f, 10.0f, app.cfg.starExplodeSim);
        if (has(kv, "starKickSpeed"))  app.cfg.starKickSpeed  = clampF(getFloat(kv, "starKickSpeed", app.cfg.starKickSpeed), 0.0f, 0.5f, app.cfg.starKickSpeed);
        if (has(kv, "starBHRatio"))    app.cfg.starBHRatio    = clampF(getFloat(kv, "starBHRatio", app.cfg.starBHRatio), 1.0f, 1.0e5f, app.cfg.starBHRatio);
        if (has(kv, "starCollapseToBH")) app.cfg.starCollapseToBH = getInt(kv, "starCollapseToBH", 0) != 0;
        if (has(kv, "starIonizeK"))    app.cfg.starIonizeK    = clampF(getFloat(kv, "starIonizeK", app.cfg.starIonizeK), 0.0f, 100.0f, app.cfg.starIonizeK);
        if (has(kv, "darkMatterFraction")) app.cfg.darkMatterFraction = clampF(getFloat(kv, "darkMatterFraction", app.cfg.darkMatterFraction), 0.0f, 0.9f, app.cfg.darkMatterFraction);
        if (has(kv, "starWindRate"))   app.cfg.starWindRate   = clampF(getFloat(kv, "starWindRate", app.cfg.starWindRate), 0.0f, 10.0f, app.cfg.starWindRate);
        if (has(kv, "dustExtinctionK")) app.cfg.dustExtinctionK = clampF(getFloat(kv, "dustExtinctionK", app.cfg.dustExtinctionK), 0.0f, 20.0f, app.cfg.dustExtinctionK);
        if (has(kv, "ashDiffuseK"))    app.cfg.ashDiffuseK    = clampF(getFloat(kv, "ashDiffuseK", app.cfg.ashDiffuseK), 0.0f, 10.0f, app.cfg.ashDiffuseK);
        // 무엇으로 볼지. 「빛」은 별이 실제로 내는 밝기(L = M^3.5)로 그린다 —
        // 밀도 그림과 대비가 통째로 다르다.
        if (has(kv, "starAshYield"))   app.cfg.starAshYield   = clampF(getFloat(kv, "starAshYield", app.cfg.starAshYield), 0.0f, 100.0f, app.cfg.starAshYield);
        if (has(kv, "ashCoolK"))       app.cfg.ashCoolK       = clampF(getFloat(kv, "ashCoolK", app.cfg.ashCoolK), 0.0f, 10.0f, app.cfg.ashCoolK);
        if (has(kv, "nebulaK"))        app.cfg.nebulaK        = clampF(getFloat(kv, "nebulaK", app.cfg.nebulaK), 0.0f, 5.0f, app.cfg.nebulaK);
        // 이온화 문턱. **밖에서 쓸어 볼 수 있어야 한다** — 격자에 쌓인 별빛의 스케일을
        // 커널 밖에서는 알 수 없어, 값을 추측해 넣었더니 문턱이 전혀 안 걸렸다
        // (2026-08-17: 0.3 에서 따뜻한 색 94.6%). 상한을 크게 열어 두고 실측으로 찾는다.
        if (has(kv, "nebulaIonMin"))   app.cfg.nebulaIonMin   = clampF(getFloat(kv, "nebulaIonMin", app.cfg.nebulaIonMin), 0.0f, 100000.0f, app.cfg.nebulaIonMin);
        // 별 후광 — 밝은 별이 얼마나 넓게 보이나. 0 이면 옛 그림(전부 같은 크기)이라
        // 켠 것과 끈 것을 견줄 수 있어야 한다.
        if (has(kv, "starGlowK"))      app.cfg.starGlowK      = clampF(getFloat(kv, "starGlowK", app.cfg.starGlowK), 0.0f, 5.0f, app.cfg.starGlowK);
        if (has(kv, "gamma"))          app.cfg.gamma          = clampF(getFloat(kv, "gamma", app.cfg.gamma), 1.0f, 2.5f, app.cfg.gamma);
        if (has(kv, "temperature"))    app.cfg.temperatureEnabled = getInt(kv, "temperature", 1) != 0;
        if (has(kv, "cooling"))        app.cfg.coolingEnabled     = getInt(kv, "cooling", 0) != 0;
        if (has(kv, "coolingRate"))    app.cfg.coolingRate        = clampF(getFloat(kv, "coolingRate", app.cfg.coolingRate), 0.0f, 1.0f, app.cfg.coolingRate);
        if (has(kv, "starFormation"))  app.cfg.starFormationEnabled = getInt(kv, "starFormation", 0) != 0;
        // (`starDensity`·`starTemp` 를 받던 두 줄을 지웠다 — 코어가 안 읽는 값이라
        //  받아 봐야 「먹힌 것처럼 보이는데 아무 일도 안 일어나는」 상태만 만든다.
        //  별 형성 문턱은 Jeans 조건 하나뿐이고 그 상수는 `starJeansK` 다.)
        if (has(kv, "expansion"))      app.cfg.expansionEnabled   = getInt(kv, "expansion", 0) != 0;
        if (has(kv, "hubble"))         app.cfg.hubble             = clampF(getFloat(kv, "hubble", app.cfg.hubble), 0.0f, 1.0f, app.cfg.hubble);
        if (has(kv, "brightness"))     app.view.brightness    = clampF(getFloat(kv, "brightness", app.view.brightness), 0.05f, 8.0f, app.view.brightness);
        if (has(kv, "displayGamma"))   app.view.gamma         = clampF(getFloat(kv, "displayGamma", app.view.gamma), 0.5f, 4.0f, app.view.gamma);
        if (has(kv, "hud"))            app.view.showHud       = getInt(kv, "hud", 1) != 0;
        if (has(kv, "spin"))           app.cfg.spin = clampF(getFloat(kv, "spin", app.cfg.spin), -3.0f, 3.0f, app.cfg.spin);
        if (has(kv, "strongForce"))    app.cfg.strongForceEnabled = getInt(kv, "strongForce", 0) != 0;
        if (has(kv, "emForce"))        app.cfg.emForceEnabled     = getInt(kv, "emForce", 0) != 0;
        if (has(kv, "weakForce"))      app.cfg.weakForceEnabled   = getInt(kv, "weakForce", 0) != 0;
        if (has(kv, "strongForceK"))
            app.cfg.strongForceK = clampF(getFloat(kv, "strongForceK", app.cfg.strongForceK), 1000.0f, 300000.0f, app.cfg.strongForceK);
        if (has(kv, "emForceK"))
            app.cfg.emForceK = clampF(getFloat(kv, "emForceK", app.cfg.emForceK), 0.001f, 0.5f, app.cfg.emForceK);
        if (has(kv, "blackHoleMassScale"))
            app.cfg.blackHoleMassScale = clampF(getFloat(kv, "blackHoleMassScale", app.cfg.blackHoleMassScale),
                                                0.002f, 1.0f, app.cfg.blackHoleMassScale);
        if (has(kv, "contact"))        app.cfg.contactEnabled = getInt(kv, "contact", 0) != 0;
        if (has(kv, "drawer"))         app.drawerOpen         = getInt(kv, "drawer", 0) != 0;
        if (has(kv, "horizon"))        app.showHorizon        = getInt(kv, "horizon", 0) != 0;
        if (has(kv, "dispersion"))
            app.cfg.orbitDispersion = clampF(getFloat(kv, "dispersion", app.cfg.orbitDispersion),
                                             0.0f, 1.0f, app.cfg.orbitDispersion);
        if (has(kv, "contactStiffness"))
            app.cfg.contactStiffness = clampF(getFloat(kv, "contactStiffness", app.cfg.contactStiffness),
                                              1.0e3f, 1.0e8f, app.cfg.contactStiffness);
        if (has(kv, "contactDamping"))
            app.cfg.contactDamping = clampF(getFloat(kv, "contactDamping", app.cfg.contactDamping),
                                            0.0f, 1.0f, app.cfg.contactDamping);
        if (has(kv, "renderMode"))
            app.view.mode = (kv["renderMode"] == "points") ? RenderMode::Points
                                                           : RenderMode::DensityField;
        if (has(kv, "colorBy")) {
            const std::string& c = kv["colorBy"];
            // "temperature" 도 받아 준다 — 밖에서 부르던 이름이라 그대로 두면 조용히 무시된다.
            app.view.colorBy = (c == "light")                             ? ColorBy::Light
                             : (c == "dispersion" || c == "temperature")  ? ColorBy::Dispersion
                             : (c == "speed")                             ? ColorBy::Speed
                             : (c == "ash" || c == "metal")               ? ColorBy::Ash
                                                                          : ColorBy::Density;
            // **`app.look` 도 함께 바꾼다.** 설정 보드가 `ApplyLook` 을 부르면 그것이
            // `look` 을 보고 `colorBy` 를 다시 정하므로, 여기서 `colorBy` 만 바꾸면
            // 보드를 건드리는 순간 되돌아간다.
            // **`look` 을 필요할 때만 건드린다(2026-08-18에 고침).**
            //
            // 전에는 `Light` 가 아니면 무조건 `Density` 로 밀었다. 그래서 `colorBy=ash` 를
            // 보내면 위 파서가 제대로 `ColorBy::Ash` 를 넣는데도 `look` 이 `Density` 가 되고,
            // `ApplyLook` 이 다음 프레임에 `colorBy` 를 밀도로 되돌렸다 — **재 보기가 밖에서
            // 아예 안 켜졌다.** 전수조사(r80)에서 잡았다.
            //
            // `ColorBy` 는 다섯 갈래인데 `Look` 은 셋(Density·Dispersion·Light)이라
            // `Speed`·`Ash` 는 짝이 없다. 짝 없는 것을 `Density` 로 미는 것이 잘못이었다 —
            // `ApplyLook` 은 `look == Light` 일 때만 `colorBy` 를 정하므로(그 함수 주석에
            // 「여기서 `app.look` 을 덮어쓰지 않는다」고 적혀 있다) **`look` 을 그대로 두면
            // `colorBy` 가 유지된다.** 빛에서 벗어날 때만 밀도로 내린다.
            const bool wantLight = (app.view.colorBy == ColorBy::Light);
            if (wantLight)                              app.look = App::Look::Light;
            else if (app.look == App::Look::Light)      app.look = App::Look::Density;
            // **컬러맵도 함께 바꾼다.** `ApplyLook` 이 이 짝을 맞추지만 그것은 시작 시
            // 한 번만 불린다 — 여기서 안 바꾸면 빛으로 보면서 밀도용 색을 쓰게 되고,
            // 그러면 「무거운 별은 푸르고 가벼운 별은 붉다」가 화면에 안 나온다.
            // 아래 "colormap" 키가 함께 오면 그쪽이 이긴다(사용자가 명시한 것이 우선).
            app.view.cmap = wantLight ? ColorMap::Blackbody : ColorMap::Astro;
        }
        if (has(kv, "colormap")) {
            const std::string& c = kv["colormap"];
            app.view.cmap = (c == "gray")      ? ColorMap::Gray
                          : (c == "thermal")   ? ColorMap::Thermal
                          : (c == "blackbody") ? ColorMap::Blackbody : ColorMap::Astro;
        }
        // 카메라도 같다 — zoom 0 이나 NaN 이 들어가면 화면 변환이 0 으로 나누기가 된다.
        if (has(kv, "zoom")) app.zoom = clampF(getFloat(kv, "zoom", app.zoom), 0.05f, 64.0f, app.zoom);
        if (has(kv, "panX")) app.panX = clampF(getFloat(kv, "panX", app.panX), -8.0f, 8.0f, app.panX);
        if (has(kv, "panY")) app.panY = clampF(getFloat(kv, "panY", app.panY), -8.0f, 8.0f, app.panY);
        // 보는 방향(라디안). 창을 오른쪽 단추로 끌면 바뀌는 값과 같은 것이라,
        // 밖에서 각도를 지정해 여러 방향의 그림을 견줄 수 있다.
        if (has(kv, "camYaw"))
            app.camYaw = clampF(getFloat(kv, "camYaw", app.camYaw), -6.2832f, 6.2832f, app.camYaw);
        if (has(kv, "camPitch"))
            app.camPitch = clampF(getFloat(kv, "camPitch", app.camPitch), -1.5533f, 1.5533f, app.camPitch);

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
        ApplyAutoGrid(app.cfg);   // 보드의 장면 버튼과 같은 순서여야 한다
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
        // 저장 위치를 제어 폴더 안으로만 묶는다.
        // MCP 서버가 자기 쪽에서 경로를 검사하지만 그건 **그 통로를 쓸 때만** 걸린다 —
        // cmd.txt 에 직접 절대경로를 써 넣으면 앱 권한으로 아무 파일이나 화면 데이터로
        // 덮어쓸 수 있었다(round-08 리뷰 A4). 앱 스스로도 막아야 실제 방어가 된다.
        if (!isInsideControlDir(path)) {
            writeResponse("ok=0\nerror=제어 폴더 밖에는 저장할 수 없습니다\n");
            return false;
        }
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
        // 도구 인자도 set 과 같은 규칙으로 자른다.
        // 여기만 검증이 빠져 있었는데, 1e300 같은 값이 float 무한대가 되면 그 자리에 놓인
        // 파티클의 위치·속도가 NaN 이 되고 다음 산란에서 격자 전체로 번진다(round-08 리뷰 A5).
        // 좌표는 판 밖도 허용해야 하지만(화면 밖에서 끌어오는 우물) 한계는 둔다.
        const float x = clampF(getFloat(kv, "x", 0.5f), -4.0f, 5.0f, 0.5f);
        const float y = clampF(getFloat(kv, "y", 0.5f), -4.0f, 5.0f, 0.5f);
        const float r = clampF(getFloat(kv, "radius", app.brush.radius), 0.001f, 4.0f, app.brush.radius);
        int result = 0;
        if (what == "shape") {
            // 모양 이름. 예전 이름(disk)도 계속 받는다 — 기존 검증 스크립트가 그것을 쓴다.
            ShapeKind k = ShapeKind::Galaxy;
            const std::string ks = kv.count("shape") ? kv["shape"] : "galaxy";
            if      (ks == "sun")   k = ShapeKind::Sun;
            else if (ks == "ring")  k = ShapeKind::Ring;
            else if (ks == "cloud") k = ShapeKind::Cloud;
            else if (ks == "blackhole" || ks == "blob") k = ShapeKind::BlackHole;
            else if (ks == "saturn") k = ShapeKind::Saturn;
            const int cnt = clampI(getInt(kv, "count", app.brush.shapeCount), 1, 300000000);
            const bool orb = getInt(kv, "autoOrbit", app.brush.autoOrbit ? 1 : 0) != 0;
            const float sr = clampF(getFloat(kv, "radius", app.brush.shapeRadius),
                                    0.001f, 4.0f, app.brush.shapeRadius);
            result = app.sim.addShape(x, y, k, sr, cnt, orb);
        } else if (what == "spray") {
            app.sim.sprayAt(x, y, r, clampF(getFloat(kv, "strength", app.brush.strength),
                                            -8.0f, 8.0f, app.brush.strength));
        } else if (what == "well") {
            app.sim.wellAt(x, y, r, clampF(getFloat(kv, "strength", app.brush.strength),
                                           -8.0f, 8.0f, app.brush.strength));
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

    // 자동 업데이트를 밖에서 눌러 본다. 보드의 「받아서 다시 켜기」와 같은 일을 한다 —
    // 창을 띄우지 않고도 받아서 갈아 끼우는 흐름 전체를 확인할 수 있어야 한다.
    if (cmd == "update") {
        std::string err;
        const bool ok = app.updater.applyUpdate(err);
        char b[320];
        snprintf(b, sizeof(b), "ok=%d\napplied=%d\nerror=%s\n",
                 ok ? 1 : 0, ok ? 1 : 0, err.c_str());
        writeResponse(b);
        return false;
    }

    if (cmd == "quit") {
        writeResponse("ok=1\nquitting=1\n");
        return true;
    }

    writeResponse("ok=0\nerror=모르는 명령입니다\n");
    return false;
}
