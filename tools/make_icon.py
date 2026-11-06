#!/usr/bin/env python3
"""Generate windows/res/glide.ico (the viewer's app icon) with no third-party modules.

A rounded square with a blue→teal gradient and a white "G". Sizes 16–256; 256 is PNG-compressed,
the rest are 32-bit DIBs. Run: python3 tools/make_icon.py
"""
import math, os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "windows", "res", "glide.ico")
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]
SS = 4  # supersampling per axis


def sample(u, v):
    """RGBA (premultiplied-ish floats 0..1) at normalized coords u,v in [0,1)."""
    # rounded square, corner radius 0.22, inset 0.03
    inset, rad = 0.03, 0.22
    x, y = u - 0.5, v - 0.5
    half = 0.5 - inset
    qx, qy = abs(x) - (half - rad), abs(y) - (half - rad)
    d = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - rad
    if d > 0:
        return None
    # gradient: top-left #3B82F6 (blue) → bottom-right #14B8A6 (teal)
    t = min(max((u + v) / 2, 0), 1)
    c0, c1 = (0x3B, 0x82, 0xF6), (0x14, 0xB8, 0xA6)
    col = [(a + (b - a) * t) / 255 for a, b in zip(c0, c1)]
    # "G": annulus r in [0.19, 0.31], open on the right between -15° and +50° (math angle, y up)
    r = math.hypot(x, y)
    ang = math.degrees(math.atan2(-y, x))
    ring = 0.19 <= r <= 0.31 and not (-15 < ang < 50)
    # crossbar: from x=0.02 to x=0.31, y in [-0.06, 0.0] (screen y down → just below center)
    bar = 0.02 <= x <= 0.31 and -0.0 <= y <= 0.06
    # vertical stub on the right going down from the bar to the ring's lower edge
    stub = 0.19 <= x <= 0.31 and 0.0 <= y <= 0.20 and r <= 0.31
    if ring or bar or stub:
        col = [1.0, 1.0, 1.0]
    return col


def render(n):
    px = []
    for j in range(n):
        row = []
        for i in range(n):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sj in range(SS):
                for si in range(SS):
                    c = sample((i + (si + 0.5) / SS) / n, (j + (sj + 0.5) / SS) / n)
                    if c:
                        acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += 1
            a = acc[3] / (SS * SS)
            if acc[3]:
                rgb = [acc[k] / acc[3] for k in range(3)]
            else:
                rgb = [0, 0, 0]
            row.append(tuple(int(round(c * 255)) for c in rgb) + (int(round(a * 255)),))
        px.append(row)
    return px


def dib(n, px):
    hdr = struct.pack("<IiiHHIIiiII", 40, n, n * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    body = bytearray()
    for row in reversed(px):  # bottom-up
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    mask_stride = ((n + 31) // 32) * 4
    body += bytes(mask_stride * n)  # AND mask: all 0 (alpha channel decides)
    return hdr + bytes(body)


def png(n, px):
    raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in px)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    images = []
    for n in SIZES:
        px = render(n)
        images.append((n, png(n, px) if n >= 256 else dib(n, px)))
    out = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    data = b""
    for n, img in images:
        out += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(img), offset + len(data))
        data += img
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(out + data)
    print(f"wrote {OUT} ({len(out + data)} bytes)")


if __name__ == "__main__":
    main()
