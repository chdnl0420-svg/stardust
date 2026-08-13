"""諛??寃⑹옄 raw(float32) -> PNG.  ?몃? ?대?吏 ?쇱씠釉뚮윭由??놁씠 zlib留뚯쑝濡?PNG瑜??대떎."""
import zlib, struct, sys, os
import numpy as np

G = 1024
OUT = r"D:\Project\Nbody\proto\out"


def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# 泥쒖껜 ?ъ쭊 ?먮굦??而щ윭留? 寃??-> ?⑥깋 -> 蹂대씪 -> 二쇳솴 -> ?곕끂??STOPS = [
    (0.00, (0, 0, 0)),
    (0.18, (12, 14, 48)),
    (0.38, (40, 36, 120)),
    (0.58, (120, 70, 170)),
    (0.76, (225, 140, 70)),
    (0.90, (255, 214, 130)),
    (1.00, (255, 255, 240)),
]


def colormap(t):
    t = np.clip(t, 0.0, 1.0)
    out = np.zeros(t.shape + (3,), dtype=np.float32)
    for i in range(len(STOPS) - 1):
        a, ca = STOPS[i]
        b, cb = STOPS[i + 1]
        m = (t >= a) & (t <= b)
        if not m.any():
            continue
        f = (t[m] - a) / (b - a)
        for c in range(3):
            out[m, c] = ca[c] + (cb[c] - ca[c]) * f
    return out.astype(np.uint8)


def load(name):
    p = os.path.join(OUT, name)
    a = np.fromfile(p, dtype=np.float32)
    if a.size != G * G:
        raise RuntimeError(f"{name}: ?ш린 遺덉씪移?{a.size} != {G*G}")
    return a.reshape(G, G)


def downsample(a, factor):
    h, w = a.shape
    return a.reshape(h // factor, factor, w // factor, factor).mean(axis=(1, 3))


def tone(a, hi_pct=99.85):
    """濡쒓렇 ?ㅼ???+ ?곸쐞 諛깅텇???뺢퇋??"""
    v = np.log1p(np.maximum(a, 0.0))
    hi = np.percentile(v, hi_pct)
    if hi <= 0:
        hi = v.max() if v.max() > 0 else 1.0
    return v / hi


def make_sheet(scene, half=512):
    tiles = []
    for k in range(4):
        a = load(f"{scene}_{k}.raw")
        a = downsample(a, G // half)
        tiles.append(colormap(tone(a)))
    top = np.concatenate([tiles[0], tiles[1]], axis=1)
    bot = np.concatenate([tiles[2], tiles[3]], axis=1)
    sheet = np.concatenate([top, bot], axis=0)
    # ?щ텇硫?寃쎄퀎??    sheet[half - 1:half + 1, :, :] = 60
    sheet[:, half - 1:half + 1, :] = 60
    path = os.path.join(OUT, f"{scene}.png")
    write_png(path, sheet)
    return path


if __name__ == "__main__":
    scenes = sys.argv[1:] or ["spiral", "tidal", "shock", "structure"]
    for s in scenes:
        try:
            print(make_sheet(s))
        except Exception as e:
            print(f"{s}: ?ㅽ뙣 - {e}")

