#include "gfx/PngWriter.h"

#include <cstdio>
#include <cstring>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>
#pragma comment(lib, "gdiplus.lib")

namespace {

unsigned CrcTable[256];
bool crcReady = false;

void initCrc() {
    for (unsigned n = 0; n < 256; ++n) {
        unsigned c = n;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        CrcTable[n] = c;
    }
    crcReady = true;
}

unsigned crc32(const unsigned char* p, size_t n, unsigned c = 0xFFFFFFFFu) {
    if (!crcReady) initCrc();
    for (size_t i = 0; i < n; ++i) c = CrcTable[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c;
}

void put32(std::vector<unsigned char>& v, unsigned x) {
    v.push_back((unsigned char)(x >> 24)); v.push_back((unsigned char)(x >> 16));
    v.push_back((unsigned char)(x >> 8));  v.push_back((unsigned char)x);
}

// PNG 청크 하나 = 길이 + 타입 + 데이터 + CRC(타입부터 데이터까지)
void putChunk(std::vector<unsigned char>& out, const char* type,
              const unsigned char* data, size_t len) {
    put32(out, (unsigned)len);
    const size_t at = out.size();
    out.insert(out.end(), type, type + 4);
    if (len) out.insert(out.end(), data, data + len);
    const unsigned c = crc32(out.data() + at, out.size() - at) ^ 0xFFFFFFFFu;
    put32(out, c);
}

} // namespace

bool WritePngRGBA(const std::string& path, const unsigned char* rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return false;

    // 1) 줄마다 앞에 필터 바이트(0 = 필터 없음)를 붙인 원본 스트림
    const size_t stride = (size_t)w * 4;
    std::vector<unsigned char> raw;
    raw.reserve((stride + 1) * h);
    for (int y = 0; y < h; ++y) {
        raw.push_back(0);
        raw.insert(raw.end(), rgba + (size_t)y * stride, rgba + (size_t)(y + 1) * stride);
    }

    // 2) zlib 스트림 — 헤더 + 무압축(stored) 블록들 + adler32
    //    stored 블록은 한 번에 65535 바이트까지 담을 수 있다.
    std::vector<unsigned char> z;
    z.push_back(0x78); z.push_back(0x01);          // zlib 헤더(deflate, 기본 윈도우)
    size_t off = 0;
    while (off < raw.size()) {
        const size_t chunk = (raw.size() - off > 65535) ? 65535 : (raw.size() - off);
        const bool last = (off + chunk >= raw.size());
        z.push_back(last ? 1 : 0);                  // BFINAL, BTYPE=00(stored)
        z.push_back((unsigned char)(chunk & 0xFF));
        z.push_back((unsigned char)(chunk >> 8));
        z.push_back((unsigned char)(~chunk & 0xFF));
        z.push_back((unsigned char)((~chunk >> 8) & 0xFF));
        z.insert(z.end(), raw.begin() + off, raw.begin() + off + chunk);
        off += chunk;
    }
    unsigned a = 1, b = 0;
    for (unsigned char c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
    put32(z, (b << 16) | a);                        // adler32

    // 3) PNG 조립
    std::vector<unsigned char> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    unsigned char ihdr[13];
    ihdr[0] = (unsigned char)(w >> 24); ihdr[1] = (unsigned char)(w >> 16);
    ihdr[2] = (unsigned char)(w >> 8);  ihdr[3] = (unsigned char)w;
    ihdr[4] = (unsigned char)(h >> 24); ihdr[5] = (unsigned char)(h >> 16);
    ihdr[6] = (unsigned char)(h >> 8);  ihdr[7] = (unsigned char)h;
    ihdr[8] = 8;    // 채널당 8비트
    ihdr[9] = 6;    // RGBA
    ihdr[10] = ihdr[11] = ihdr[12] = 0;
    putChunk(png, "IHDR", ihdr, sizeof(ihdr));
    putChunk(png, "IDAT", z.data(), z.size());
    putChunk(png, "IEND", nullptr, 0);

    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) return false;
    // 쓴 만큼과 닫기까지 확인한다. 디스크가 모자라거나 중간에 끊기면 fwrite 는 요청보다 적게 쓰고,
    // 버퍼에 남은 것은 fclose 에서야 실패한다 — 둘 다 안 보면 깨진 파일을 만들어 놓고
    // 성공을 돌려주게 된다(round-06 리뷰 P2 #29).
    const size_t wrote = fwrite(png.data(), 1, png.size(), f);
    const bool closedOk = (fclose(f) == 0);
    return wrote == png.size() && closedOk;
}

namespace {

// 이름으로 인코더를 찾는다. GDI+ 는 CLSID 로만 저장을 받는데 그 값을 코드에 박아 두면
// 무엇을 가리키는지 알 수 없고, 시스템이 다르면 어긋날 수도 있다.
bool FindEncoder(const wchar_t* mime, CLSID* out) {
    UINT n = 0, bytes = 0;
    if (Gdiplus::GetImageEncodersSize(&n, &bytes) != Gdiplus::Ok || bytes == 0) return false;
    std::vector<unsigned char> buf(bytes);
    Gdiplus::ImageCodecInfo* info = (Gdiplus::ImageCodecInfo*)buf.data();
    if (Gdiplus::GetImageEncoders(n, bytes, info) != Gdiplus::Ok) return false;
    for (UINT i = 0; i < n; ++i)
        if (wcscmp(info[i].MimeType, mime) == 0) { *out = info[i].Clsid; return true; }
    return false;
}

} // namespace

bool WriteJpgRGBA(const std::string& path, const unsigned char* rgba, int w, int h, int quality) {
    if (!rgba || w <= 0 || h <= 0) return false;
    if (quality < 1) quality = 1;
    if (quality > 100) quality = 100;

    // GDI+ 는 쓰기 직전에 켜고 끝나면 끈다. 앱이 도는 내내 켜 둘 만한 것이 아니고,
    // 저장은 사용자가 누를 때만 일어난다.
    Gdiplus::GdiplusStartupInput si;
    ULONG_PTR token = 0;
    if (Gdiplus::GdiplusStartup(&token, &si, nullptr) != Gdiplus::Ok) return false;

    bool ok = false;
    {
        // GDI+ 의 32bppARGB 는 메모리에서 BGRA 순서다. 그대로 넘기면 빨강과 파랑이 바뀐다.
        std::vector<unsigned char> bgra((size_t)w * h * 4);
        for (size_t i = 0, n = (size_t)w * h; i < n; ++i) {
            bgra[i * 4 + 0] = rgba[i * 4 + 2];
            bgra[i * 4 + 1] = rgba[i * 4 + 1];
            bgra[i * 4 + 2] = rgba[i * 4 + 0];
            bgra[i * 4 + 3] = 255;
        }
        Gdiplus::Bitmap bmp(w, h, w * 4, PixelFormat32bppARGB, bgra.data());
        CLSID clsid{};
        if (bmp.GetLastStatus() == Gdiplus::Ok && FindEncoder(L"image/jpeg", &clsid)) {
            ULONG q = (ULONG)quality;
            Gdiplus::EncoderParameters params;
            params.Count = 1;
            params.Parameter[0].Guid = Gdiplus::EncoderQuality;
            params.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
            params.Parameter[0].NumberOfValues = 1;
            params.Parameter[0].Value = &q;

            const int need = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
            std::vector<wchar_t> wpath(need > 0 ? need : 1, 0);
            if (need > 0) MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wpath.data(), need);
            ok = (bmp.Save(wpath.data(), &clsid, &params) == Gdiplus::Ok);
        }
    }
    Gdiplus::GdiplusShutdown(token);
    return ok;
}
