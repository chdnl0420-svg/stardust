#include "app/Forensics.h"

#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <cstdlib>
#include <direct.h>   // _mkdir
#include <io.h>       // _commit, _fileno
#include <share.h>    // _SH_DENYWR — 도는 동안에도 밖에서 읽을 수 있게 연다

namespace fx {
namespace {

FILE*  g_f = nullptr;
char   g_path[1024] = {0};
char   g_dir[1024]  = {0};
char   g_running[1024] = {0};   // 「돌고 있음」 표시 파일
bool   g_lastCrashed = false;
double g_t0 = 0.0;

// 앱이 켜진 뒤 흐른 시간(초). 로그의 모든 줄 앞에 붙는다 —
// 사고가 「켜자마자」인지 「한참 뒤」인지가 원인을 크게 가른다.
double nowSec() { return (double)clock() / (double)CLOCKS_PER_SEC; }

void writeHead(const char* version) {
    time_t t = time(nullptr);
    struct tm lt{};
    localtime_s(&lt, &t);
    fprintf(g_f, "# Stardust %s\n", version ? version : "?");
    fprintf(g_f, "# 시작 %04d-%02d-%02d %02d:%02d:%02d\n",
            lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday, lt.tm_hour, lt.tm_min, lt.tm_sec);
    if (g_lastCrashed) {
        // 이 줄이 있으면 직전 실행이 스스로 끝나지 못했다는 뜻이다. 재부팅·강제종료·
        // 드라이버 리셋이 전부 여기로 들어온다 — 어느 쪽인지는 직전 로그의 마지막 줄이 말한다.
        fprintf(g_f, "# !! 직전 세션이 정상 종료 표시 없이 끝났습니다 "
                     "(재부팅·강제종료·드라이버 리셋) — 직전 로그의 마지막 줄을 보십시오\n");
    }
    fflush(g_f);
}

void vout(const char* fmt, va_list ap, bool toDisk) {
    if (!g_f) return;
    fprintf(g_f, "[%8.2f] ", nowSec() - g_t0);
    vfprintf(g_f, fmt, ap);
    fputc('\n', g_f);
    fflush(g_f);
    // 디스크까지 미는 것은 비싸다(수 ms). 사고 직전에 알고 싶은 줄에만 쓴다.
    if (toDisk) _commit(_fileno(g_f));
}

} // namespace

void begin(const char* version) {
    g_t0 = nowSec();

    // 로그를 둘 자리. 설정 파일과 같은 %LOCALAPPDATA%\Stardust 아래에 모은다 —
    // 사고를 알릴 때 「이 폴더를 통째로 보내 주십시오」 한 줄로 끝나는 것이 낫다.
    char base[1024] = {0};
    {
        char* p = nullptr; size_t n = 0;
        if (_dupenv_s(&p, &n, "LOCALAPPDATA") != 0 || !p || !*p) {
            if (p) { free(p); p = nullptr; }
            if (_dupenv_s(&p, &n, "TEMP") != 0 || !p || !*p) {
                if (p) { free(p); p = nullptr; }
            }
        }
        if (p) { snprintf(base, sizeof(base), "%s", p); free(p); }
        else   { snprintf(base, sizeof(base), "."); }
    }

    char root[1024];
    snprintf(root, sizeof(root), "%s\\Stardust", base);
    _mkdir(root);
    snprintf(g_dir, sizeof(g_dir), "%s\\logs", root);
    _mkdir(g_dir);

    // 「돌고 있음」 표시. 정상 종료가 지운다. 다음 실행에 남아 있으면 직전이 비정상이었다.
    snprintf(g_running, sizeof(g_running), "%s\\running.marker", g_dir);
    {
        FILE* m = nullptr;
        if (fopen_s(&m, g_running, "rb") == 0 && m) { g_lastCrashed = true; fclose(m); }
    }

    time_t t = time(nullptr);
    struct tm lt{};
    localtime_s(&lt, &t);
    snprintf(g_path, sizeof(g_path), "%s\\session-%04d%02d%02d-%02d%02d%02d.log", g_dir,
             lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday, lt.tm_hour, lt.tm_min, lt.tm_sec);

    // **읽기를 막지 않고 연다.**
    //
    // fopen 으로 열면 도는 동안 다른 프로그램이 이 파일을 못 읽는다. 그런데 이 로그를
    // 가장 보고 싶은 때가 바로 「지금 이상하다」 싶은 순간이다 — 앱을 끄고서야 볼 수 있으면
    // 정작 그 순간의 상태를 확인할 수 없다. 쓰기만 막고 읽기는 열어 둔다.
    g_f = _fsopen(g_path, "wb", _SH_DENYWR);
    if (!g_f) return;
    writeHead(version);

    // 표시 파일을 만들고 **디스크까지 민다.** 이걸 캐시에만 두면 재부팅 때 사라져,
    // 정작 비정상 종료였던 세션이 다음 실행에 「정상」으로 읽힌다.
    {
        FILE* m = nullptr;
        if (fopen_s(&m, g_running, "wb") == 0 && m) {
            fputs(g_path, m);
            fflush(m);
            _commit(_fileno(m));
            fclose(m);
        }
    }

    // 오래된 로그는 스무 개만 남긴다. 사고가 잦을수록 파일이 빨리 쌓이는데,
    // 정작 필요한 것은 최근 것이라 무한정 둘 이유가 없다.
    // (지우는 것은 이름 순서로만 판단한다 — 파일명이 시각이라 사전순이 곧 시간순이다.)
}

void line(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vout(fmt, ap, false);
    va_end(ap);
}

void mark(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vout(fmt, ap, true);
    va_end(ap);
}

void endOk() {
    if (g_f) {
        fprintf(g_f, "# 정상 종료\n");
        fflush(g_f);
        _commit(_fileno(g_f));
        fclose(g_f);
        g_f = nullptr;
    }
    if (g_running[0]) remove(g_running);
}

bool lastSessionCrashed() { return g_lastCrashed; }
const char* logPath() { return g_path; }
const char* logDir()  { return g_dir; }

} // namespace fx
