#include "app/Updater.h"
#include "app/Version.h"

#include <windows.h>
#include <winhttp.h>
#include <shlwapi.h>
#include <thread>
#include <vector>
#include <cstdio>

#pragma comment(lib, "winhttp.lib")

namespace {

// UTF-8 <-> UTF-16. Win32 는 W 계열만 쓰고, 밖으로는 UTF-8 로만 주고받는다.
std::wstring toW(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}
std::string toU8(const std::wstring& w) {
    if (w.empty()) return std::string();
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// 주소를 host / path 로 가른다. https 만 받는다 —
// http 를 허용하면 중간에서 내용을 바꿔치기한 실행 파일을 받게 된다.
bool splitHttps(const std::string& url, std::wstring& host, std::wstring& path) {
    const std::string pre = "https://";
    if (url.compare(0, pre.size(), pre) != 0) return false;
    const size_t slash = url.find('/', pre.size());
    if (slash == std::string::npos) return false;
    host = toW(url.substr(pre.size(), slash - pre.size()));
    path = toW(url.substr(slash));
    return true;
}

// 한 번의 GET. body 가 nullptr 이면 본문을 버리고, file 이 있으면 그 파일로 흘려 쓴다.
// 리디렉션은 WinHTTP 가 알아서 따라간다(릴리스 자산은 다른 호스트로 넘긴다).
bool httpGet(const std::string& url, std::string* body, FILE* file, std::string& err) {
    std::wstring host, path;
    if (!splitHttps(url, host, path)) { err = "주소가 https 가 아닙니다"; return false; }

    // GitHub 는 User-Agent 가 없으면 403 을 돌려준다.
    HINTERNET ses = WinHttpOpen(L"Stardust-Updater/1.0",
                                WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!ses) { err = "네트워크를 열지 못했습니다"; return false; }
    // 응답이 없을 때 앱이 붙잡히지 않도록 짧게 끊는다.
    WinHttpSetTimeouts(ses, 5000, 8000, 15000, 30000);

    bool ok = false;
    HINTERNET con = WinHttpConnect(ses, host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (con) {
        HINTERNET req = WinHttpOpenRequest(con, L"GET", path.c_str(), nullptr,
                                           WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                           WINHTTP_FLAG_SECURE);
        if (req) {
            const wchar_t* hdr = L"Accept: application/vnd.github+json\r\n";
            if (WinHttpSendRequest(req, hdr, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
                && WinHttpReceiveResponse(req, nullptr)) {
                DWORD code = 0, len = sizeof(code);
                WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                    WINHTTP_HEADER_NAME_BY_INDEX, &code, &len, WINHTTP_NO_HEADER_INDEX);
                if (code == 200) {
                    std::vector<char> buf(64 * 1024);
                    ok = true;
                    for (;;) {
                        DWORD got = 0;
                        if (!WinHttpReadData(req, buf.data(), (DWORD)buf.size(), &got)) { ok = false; break; }
                        if (got == 0) break;
                        if (body) body->append(buf.data(), got);
                        if (file && fwrite(buf.data(), 1, got, file) != got) { ok = false; break; }
                    }
                    if (!ok) err = "내려받는 중에 끊겼습니다";
                } else {
                    char m[64];
                    snprintf(m, sizeof(m), "서버가 %lu 를 돌려주었습니다", (unsigned long)code);
                    err = m;
                }
            } else {
                err = "요청을 보내지 못했습니다";
            }
            WinHttpCloseHandle(req);
        }
        WinHttpCloseHandle(con);
    } else {
        err = "서버에 닿지 못했습니다";
    }
    WinHttpCloseHandle(ses);
    return ok;
}

// JSON 에서 "key": "value" 의 값을 뽑는다.
//
// 제대로 된 파서가 아니다. GitHub 릴리스 응답은 모양이 고정이고 우리가 읽는 것은 세 개뿐이라
// 이 정도로 충분하다. 다만 값에 이스케이프(\") 가 들어 있으면 거기서 끊긴다 — 그래서 이 함수로
// 읽는 것은 버전 태그와 주소처럼 이스케이프가 나올 수 없는 항목으로 한정한다.
std::string jsonValue(const std::string& src, const std::string& key, size_t from = 0) {
    const std::string pat = "\"" + key + "\"";
    size_t p = src.find(pat, from);
    if (p == std::string::npos) return std::string();
    p = src.find(':', p + pat.size());
    if (p == std::string::npos) return std::string();
    p = src.find('"', p);
    if (p == std::string::npos) return std::string();
    const size_t e = src.find('"', p + 1);
    if (e == std::string::npos) return std::string();
    return src.substr(p + 1, e - p - 1);
}

// "v0.2.0" 또는 "0.2.0" 을 숫자 셋으로 가른다.
void parseVersion(const std::string& s, int out[3]) {
    out[0] = out[1] = out[2] = 0;
    const char* p = s.c_str();
    if (*p == 'v' || *p == 'V') ++p;
    sscanf_s(p, "%d.%d.%d", &out[0], &out[1], &out[2]);
}

// a 가 b 보다 새 버전인가.
bool isNewer(const std::string& a, const std::string& b) {
    int x[3], y[3];
    parseVersion(a, x);
    parseVersion(b, y);
    for (int i = 0; i < 3; ++i) {
        if (x[i] != y[i]) return x[i] > y[i];
    }
    return false;
}

std::wstring exePathW() {
    wchar_t buf[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    return std::wstring(buf);
}

} // namespace

void Updater::startCheck() {
    {
        std::lock_guard<std::mutex> lk(mu_);
        if (info_.checked) return;   // 한 번만 본다
    }
    // 창이 뜨는 것을 네트워크가 붙잡지 않도록 떼어 놓는다. 결과는 잠금으로 넘긴다.
    std::thread([this] {
        UpdateInfo r;
        r.checked = true;

        const std::string api = "https://api.github.com/repos/"
                                STARDUST_REPO_OWNER "/" STARDUST_REPO_NAME "/releases/latest";
        std::string body;
        if (!httpGet(api, &body, nullptr, r.error)) {
            std::lock_guard<std::mutex> lk(mu_);
            info_ = r;
            return;
        }

        r.latest = jsonValue(body, "tag_name");
        if (r.latest.empty()) {
            r.error = "저장소에 아직 배포본이 없습니다";
            std::lock_guard<std::mutex> lk(mu_);
            info_ = r;
            return;
        }

        // 자산 중 실행 파일 하나만 받는다. 이름을 못 박아 두어, 릴리스에 딸린 다른 파일이
        // 실행 파일 자리로 들어오는 것을 막는다.
        const std::string wantName = "Stardust.exe";
        size_t at = body.find("\"name\":\"" + wantName + "\"");
        if (at != std::string::npos) r.downloadUrl = jsonValue(body, "browser_download_url", at);

        r.notes = jsonValue(body, "name");
        r.available = isNewer(r.latest, STARDUST_VERSION) && !r.downloadUrl.empty();
        if (isNewer(r.latest, STARDUST_VERSION) && r.downloadUrl.empty())
            r.error = "새 버전에 실행 파일이 붙어 있지 않습니다";

        std::lock_guard<std::mutex> lk(mu_);
        info_ = r;
    }).detach();
}

UpdateInfo Updater::status() const {
    std::lock_guard<std::mutex> lk(mu_);
    return info_;
}

bool Updater::applyUpdate(std::string& err) {
    UpdateInfo cur = status();
    if (!cur.available || cur.downloadUrl.empty()) { err = "받을 것이 없습니다"; return false; }

    const std::wstring exe = exePathW();
    const std::wstring tmp = exe + L".new";
    const std::wstring bat = exe + L".update.bat";

    // 새 실행 파일을 옆에 받는다. 받다가 끊기면 반쯤 받은 파일이 남으므로 그때는 지우고 만다.
    {
        FILE* f = nullptr;
        if (_wfopen_s(&f, tmp.c_str(), L"wb") != 0 || !f) { err = "파일을 만들지 못했습니다"; return false; }
        const bool ok = httpGet(cur.downloadUrl, nullptr, f, err);
        fclose(f);
        if (!ok) { DeleteFileW(tmp.c_str()); return false; }
    }

    // 윈도우는 돌고 있는 실행 파일을 덮어쓰지 못한다.
    // 그래서 앱이 끝나기를 기다렸다가 바꿔치기하고 다시 띄우는 작은 스크립트를 남긴다.
    // 스크립트는 마지막에 스스로를 지운다.
    {
        FILE* f = nullptr;
        if (_wfopen_s(&f, bat.c_str(), L"w, ccs=UTF-8") != 0 || !f) {
            DeleteFileW(tmp.c_str());
            err = "스크립트를 만들지 못했습니다";
            return false;
        }
        const std::string exeU8 = toU8(exe);
        const std::string tmpU8 = toU8(tmp);
        fprintf(f,
            "@echo off\r\n"
            "chcp 65001 >nul\r\n"
            ":wait\r\n"
            "tasklist /fi \"imagename eq Stardust.exe\" 2>nul | find /i \"Stardust.exe\" >nul\r\n"
            "if not errorlevel 1 (\r\n"
            "  ping -n 2 127.0.0.1 >nul\r\n"
            "  goto wait\r\n"
            ")\r\n"
            "move /y \"%s\" \"%s\" >nul\r\n"
            "start \"\" \"%s\"\r\n"
            "del \"%%~f0\"\r\n",
            tmpU8.c_str(), exeU8.c_str(), exeU8.c_str());
        fclose(f);
    }

    // 창 없이 띄운다. 이 뒤에 앱이 끝나면 스크립트가 이어받는다.
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"cmd.exe /c \"" + bat + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');
    if (!CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        DeleteFileW(tmp.c_str());
        DeleteFileW(bat.c_str());
        err = "업데이트를 시작하지 못했습니다";
        return false;
    }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    restart_ = true;
    return true;
}
