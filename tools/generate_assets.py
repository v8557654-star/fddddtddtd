#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BACKROOMS // BODYCAM  --  procedural asset generator.

Generates EVERY binary asset the game needs, from scratch:
  * textures/*.png   - metal, monster skin, lens dirt, film grain, static,
                       jumpscare face + normal/roughness maps
  * audio/*.ogg      - fluorescent hum, ambience drone, footsteps, monster
                       growls / screeches, heartbeat, whispers, stingers...

Run:  python3 tools/generate_assets.py
No third party assets are used anywhere in this project.
"""

import os
import wave
import zlib

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX_DIR = os.path.join(ROOT, "textures")
AUD_DIR = os.path.join(ROOT, "audio")
os.makedirs(TEX_DIR, exist_ok=True)
os.makedirs(AUD_DIR, exist_ok=True)

SR = 44100


# ======================================================================================
#  TILEABLE NOISE HELPERS
# ======================================================================================
def periodic_value_noise(size, cells, rng):
    """Perfectly tileable smooth value noise (periodic bicubic-ish interpolation)."""
    g = rng.random((cells, cells))
    xs = np.linspace(0.0, cells, size, endpoint=False)
    base = np.floor(xs).astype(np.int64)
    frac = xs - base
    i0 = base % cells
    i1 = (base + 1) % cells
    t = frac * frac * frac * (frac * (frac * 6.0 - 15.0) + 10.0)  # quintic
    tx = t[None, :]
    ty = t[:, None]
    a = g[np.ix_(i0, i0)]
    b = g[np.ix_(i0, i1)]
    c = g[np.ix_(i1, i0)]
    d = g[np.ix_(i1, i1)]
    top = a * (1.0 - tx) + b * tx
    bot = c * (1.0 - tx) + d * tx
    return top * (1.0 - ty) + bot * ty


def fbm(size, octaves=6, base_cells=2, gain=0.5, seed=0, warp=0.0):
    """Tileable fractal brownian motion, normalised to 0..1."""
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size), dtype=np.float64)
    amp = 1.0
    total = 0.0
    cells = base_cells
    wx = np.zeros((size, size))
    wy = np.zeros((size, size))
    if warp > 0.0:
        wx = periodic_value_noise(size, base_cells * 3, np.random.default_rng(seed + 991)) - 0.5
        wy = periodic_value_noise(size, base_cells * 3, np.random.default_rng(seed + 992)) - 0.5
    for _ in range(octaves):
        n = periodic_value_noise(size, cells, np.random.default_rng(seed + cells * 7919))
        if warp > 0.0:
            n = n + warp * (wx * 0.5 + wy * 0.5)
        out += n * amp
        total += amp
        amp *= gain
        cells *= 2
    out /= max(total, 1e-9)
    lo, hi = out.min(), out.max()
    return (out - lo) / max(hi - lo, 1e-9)


def white_noise(size, seed=0):
    rng = np.random.default_rng(seed)
    return rng.random((size, size))


def height_to_normal(h, strength=2.0):
    """Tileable sobel -> tangent space normal map (RGB, 0..255)."""
    dx = np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)
    dy = np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)
    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(h)
    n = np.stack([nx, ny, nz], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return (n * 0.5 + 0.5)


def save_rgb(arr, name):
    img = Image.fromarray(np.clip(arr * 255.0, 0, 255).astype(np.uint8), "RGB")
    img.save(os.path.join(TEX_DIR, name), optimize=True)
    print("  tex:", name, img.size)


def save_rgba(arr, name):
    img = Image.fromarray(np.clip(arr * 255.0, 0, 255).astype(np.uint8), "RGBA")
    img.save(os.path.join(TEX_DIR, name), optimize=True)
    print("  tex:", name, img.size)


def save_normal(h, name, strength=2.0):
    save_rgb(height_to_normal(h, strength), name)


# ======================================================================================
#  TEXTURES
# ======================================================================================
def tex_wallpaper(size=1024):
    """Damp, stained mustard-yellow backrooms wallpaper with vertical striping."""
    base = np.array([0.735, 0.628, 0.318])
    y = np.linspace(0, 1, size, endpoint=False)[:, None]
    x = np.linspace(0, 1, size, endpoint=False)[None, :]

    # vertical wallpaper stripes (tileable: integer frequency)
    stripes = 0.5 + 0.5 * np.cos(x * 2 * np.pi * 12.0)
    stripes = np.power(stripes, 2.2)

    big = fbm(size, 5, 2, 0.55, seed=11)              # broad mottling
    mid = fbm(size, 6, 8, 0.5, seed=12)                # medium stains
    fine = fbm(size, 4, 64, 0.5, seed=13)              # paper fibre
    grain = white_noise(size, seed=14)

    col = base.copy() * np.ones((size, size, 1))
    col *= (0.93 + 0.09 * stripes)[..., None]
    col *= (0.80 + 0.34 * big)[..., None]

    # damp / dirty patches -> brown-green
    stain = np.clip((mid - 0.52) * 3.4, 0, 1) ** 1.6
    stain_col = np.array([0.34, 0.27, 0.15])
    col = col * (1 - stain[..., None] * 0.85) + stain_col * stain[..., None]

    # darker water damage running down from the top
    drip = np.clip((fbm(size, 4, 4, 0.5, seed=15) - 0.45) * 3.0, 0, 1)
    vertical = np.clip((1.0 - y) * 1.25, 0, 1) ** 0.8
    damp = drip * vertical * 0.55
    col *= (1 - damp[..., None] * 0.5)
    col += np.array([0.03, 0.04, 0.0]) * damp[..., None]

    # horizontal seam / dado line
    seam = np.exp(-((y - 0.62) * size / 2.6) ** 2) * 0.30
    col *= (1 - seam[..., None])

    col += (fine - 0.5)[..., None] * 0.055
    col += (grain - 0.5)[..., None] * 0.030
    save_rgb(col, "wallpaper.png")

    hgt = big * 0.35 + mid * 0.35 + fine * 0.22 + grain * 0.08 + stripes * 0.06 + stain * 0.4
    save_normal(hgt, "wallpaper_n.png", 2.6)

    # roughness: stains are wetter/shinier
    rough = 0.86 - stain * 0.34 - damp * 0.2 + (grain - 0.5) * 0.05
    save_rgb(np.repeat(np.clip(rough, 0, 1)[..., None], 3, axis=-1), "wallpaper_r.png")


def tex_carpet(size=1024):
    """Mouldy mono-yellow office carpet."""
    base = np.array([0.470, 0.404, 0.196])
    fibre = fbm(size, 7, 48, 0.55, seed=21)
    blotch = fbm(size, 5, 3, 0.5, seed=22)
    macro = fbm(size, 4, 8, 0.5, seed=23)
    grain = white_noise(size, seed=24)
    speck = (white_noise(size, seed=25) > 0.985).astype(float)

    col = base * np.ones((size, size, 1))
    col *= (0.86 + 0.28 * fibre)[..., None]
    col *= (0.80 + 0.40 * blotch)[..., None]
    col *= (0.92 + 0.16 * macro)[..., None]

    dark = np.array([0.16, 0.13, 0.07])
    dirty = np.clip((blotch - 0.56) * 3.2, 0, 1) ** 1.7
    col = col * (1 - dirty[..., None] * 0.8) + dark * dirty[..., None]

    col += (grain - 0.5)[..., None] * 0.075
    col += speck[..., None] * np.array([0.10, 0.09, 0.05])
    save_rgb(col, "carpet.png")

    hgt = fibre * 0.6 + grain * 0.25 + macro * 0.15 + speck * 0.3
    save_normal(hgt, "carpet_n.png", 3.4)
    rough = 0.94 - dirty * 0.2 + (grain - 0.5) * 0.06
    save_rgb(np.repeat(np.clip(rough, 0, 1)[..., None], 3, axis=-1), "carpet_r.png")


def tex_ceiling(size=512):
    """Acoustic drop-ceiling tile: off-white speckled mineral fibre."""
    base = np.array([0.795, 0.782, 0.735])
    speckle = fbm(size, 6, 96, 0.5, seed=31)
    dots = white_noise(size, seed=32)
    blotch = fbm(size, 4, 4, 0.5, seed=33)
    yellow = np.clip((fbm(size, 5, 3, 0.5, seed=34) - 0.58) * 3.0, 0, 1) ** 1.5

    col = base * np.ones((size, size, 1))
    col *= (0.93 + 0.14 * speckle)[..., None]
    col -= (dots > 0.93)[..., None] * 0.16
    col *= (0.95 + 0.10 * blotch)[..., None]
    col = col * (1 - yellow[..., None] * 0.35) + np.array([0.55, 0.44, 0.22]) * yellow[..., None] * 0.5
    save_rgb(col, "ceiling.png")
    hgt = speckle * 0.5 + dots * 0.3 + blotch * 0.2
    save_normal(hgt, "ceiling_n.png", 1.1)


def tex_concrete(size=512):
    base = np.array([0.36, 0.355, 0.335])
    n1 = fbm(size, 6, 4, 0.5, seed=41)
    n2 = fbm(size, 5, 24, 0.5, seed=42)
    g = white_noise(size, seed=43)
    col = base * np.ones((size, size, 1))
    col *= (0.82 + 0.36 * n1)[..., None]
    col *= (0.92 + 0.16 * n2)[..., None]
    col += (g - 0.5)[..., None] * 0.05
    cracks = np.clip(1.0 - np.abs(fbm(size, 4, 6, 0.5, seed=44) - 0.5) * 14.0, 0, 1) ** 2.0
    col *= (1 - cracks[..., None] * 0.42)
    save_rgb(col, "concrete.png")
    save_normal(n1 * 0.6 + n2 * 0.3 + g * 0.1, "concrete_n.png", 1.8)


def tex_metal(size=512):
    """Rusted painted metal (doors, panels, vents)."""
    base = np.array([0.30, 0.30, 0.27])
    brushed = fbm(size, 5, 128, 0.6, seed=51)
    rust = np.clip((fbm(size, 6, 4, 0.5, seed=52, warp=0.35) - 0.48) * 3.0, 0, 1) ** 1.4
    grain = white_noise(size, seed=53)
    col = base * np.ones((size, size, 1))
    col *= (0.9 + 0.2 * brushed)[..., None]
    rust_col = np.array([0.42, 0.21, 0.09])
    col = col * (1 - rust[..., None]) + rust_col * rust[..., None]
    col += (grain - 0.5)[..., None] * 0.04
    save_rgb(col, "metal.png")
    save_normal(brushed * 0.4 + rust * 0.5 + grain * 0.1, "metal_n.png", 2.2)
    rough = 0.42 + rust * 0.45 + (grain - 0.5) * 0.06
    save_rgb(np.repeat(np.clip(rough, 0, 1)[..., None], 3, axis=-1), "metal_r.png")


def tex_skin(size=512):
    """Sickly pale, veiny, wet flesh for the entity."""
    base = np.array([0.78, 0.74, 0.68])
    blotch = fbm(size, 6, 3, 0.55, seed=61)
    pore = fbm(size, 5, 64, 0.5, seed=62)
    veins = np.clip(1.0 - np.abs(fbm(size, 5, 8, 0.5, seed=63, warp=0.6) - 0.5) * 26.0, 0, 1) ** 1.7
    bruise = np.clip((fbm(size, 5, 2, 0.5, seed=64) - 0.66) * 3.0, 0, 1)
    col = base * np.ones((size, size, 1))
    col *= (0.90 + 0.16 * blotch)[..., None]
    col *= (0.95 + 0.10 * pore)[..., None]
    col = col * (1 - veins[..., None] * 0.40) + np.array([0.46, 0.42, 0.44]) * veins[..., None] * 0.40
    col = col * (1 - bruise[..., None] * 0.28) + np.array([0.58, 0.52, 0.52]) * bruise[..., None] * 0.28
    save_rgb(col, "skin.png")
    save_normal(blotch * 0.35 + pore * 0.5 + veins * 0.4, "skin_n.png", 2.0)


def tex_lens_dirt(size=1024):
    """Bodycam lens: dust, smudges, scratches, fingerprints (alpha mask)."""
    rng = np.random.default_rng(71)
    a = np.zeros((size, size))
    yy, xx = np.mgrid[0:size, 0:size].astype(float)

    # broad smudges
    sm = fbm(size, 5, 2, 0.5, seed=72)
    a += np.clip((sm - 0.60) * 3.2, 0, 1) * 0.30

    # fingerprints: rings
    for _ in range(7):
        cx, cy = rng.uniform(0.1, 0.9) * size, rng.uniform(0.1, 0.9) * size
        r = rng.uniform(0.05, 0.14) * size
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        rings = 0.5 + 0.5 * np.sin(d / r * 26.0)
        mask = np.exp(-((d / r) ** 2))
        a += rings * mask * 0.20

    # dust specks
    dust = white_noise(size, seed=73)
    a += (dust > 0.9985).astype(float) * rng.uniform(0.25, 0.6, (size, size))
    a += np.clip((dust - 0.985) * 20.0, 0, 1) * 0.10

    # scratches (long thin lines)
    for _ in range(26):
        x0, y0 = rng.uniform(0, size), rng.uniform(0, size)
        ang = rng.uniform(0, np.pi)
        ln = rng.uniform(0.05, 0.45) * size
        w = rng.uniform(0.6, 1.8)
        ex, ey = x0 + np.cos(ang) * ln, y0 + np.sin(ang) * ln
        steps = int(ln / 1.5) + 2
        for i in range(steps):
            t = i / steps
            px, py = int((x0 + (ex - x0) * t) % size), int((y0 + (ey - y0) * t) % size)
            r = int(w) + 1
            a[max(0, py - r):py + r + 1, max(0, px - r):px + r + 1] += rng.uniform(0.05, 0.2)

    # corner grime
    cx, cy = size / 2, size / 2
    d = np.sqrt(((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2)
    a += np.clip((d - 0.62) * 1.5, 0, 1) ** 1.5 * 0.55

    a = np.clip(a, 0, 1)
    rgba = np.ones((size, size, 4))
    rgba[..., 3] = a
    save_rgba(rgba, "lens_dirt.png")


def tex_grain(size=512):
    """Tileable monochrome film grain + a few horizontal dropout lines."""
    rng = np.random.default_rng(81)
    g = rng.random((size, size))
    lines = np.zeros((size, size))
    for _ in range(6):
        y = rng.integers(0, size)
        lines[y, :] = rng.uniform(0.4, 1.0)
    v = g * 0.9 + lines * 0.1
    rgba = np.ones((size, size, 4))
    rgba[..., 0] = v
    rgba[..., 1] = v
    rgba[..., 2] = v
    rgba[..., 3] = 1.0
    save_rgba(rgba, "grain.png")


def tex_static(size=256):
    """RGB analog static / VHS noise."""
    rng = np.random.default_rng(91)
    v = rng.random((size, size, 3))
    lum = rng.random((size, size, 1))
    v = v * 0.35 + lum * 0.65
    save_rgb(v, "static.png")


def tex_exit_sign(size=256):
    """Glowing EXIT sign face."""
    img = np.zeros((size, size, 3)) + 0.02
    img[:, :, 0] = 0.05
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    glow = np.exp(-(((yy - size / 2) / (size * 0.6)) ** 2))
    img += glow[:, :, None] * np.array([0.10, 0.0, 0.0])[None, None, :]
    # blocky "EXIT" glyphs
    glyphs = {
        "E": ["1111", "1000", "1110", "1000", "1111"],
        "X": ["1001", "0110", "0010", "0110", "1001"],
        "I": ["1111", "0010", "0010", "0010", "1111"],
        "T": ["1111", "0010", "0010", "0010", "0010"],
    }
    word = "EXIT"
    cw, ch = 5, 5
    total_w = len(word) * cw + (len(word) - 1)
    scale = size // (total_w + 4)
    ox = (size - total_w * scale) // 2
    oy = (size - ch * scale) // 2
    for gi, ch_name in enumerate(word):
        g = glyphs[ch_name]
        for ry, row in enumerate(g):
            for rx, cell in enumerate(row):
                if cell == "1":
                    px = ox + (gi * (cw + 1) + rx) * scale
                    py = oy + ry * scale
                    img[py:py + scale, px:px + scale] = np.array([1.0, 0.10, 0.08])
    save_rgb(np.clip(img, 0, 1), "exit_sign.png")


def build_textures():
    print("[textures]")
    tex_metal()
    tex_skin()
    tex_lens_dirt()
    tex_grain()
    tex_static()


# ======================================================================================
#  AUDIO
# ======================================================================================
def write_wav(name, data, rate=SR, loop=False):
    data = np.asarray(data, dtype=np.float64)
    if data.ndim == 1:
        data = data[:, None]
    peak = np.max(np.abs(data))
    if peak > 0:
        data = data / max(peak, 1.0) * min(peak, 0.98)
    pcm = np.clip(data * 32767.0, -32768, 32767).astype("<i2")
    # v7: ship OGG Vorbis (about 10x smaller than PCM); falls back to WAV
    # when python-soundfile is not installed. audio_bank.gd accepts both.
    path = os.path.join(AUD_DIR, name)
    try:
        import soundfile as sf
        path = os.path.splitext(path)[0] + ".ogg"
        sf.write(path, np.clip(data, -1.0, 1.0).astype(np.float32), rate, format="OGG", subtype="VORBIS")
        name = os.path.basename(path)
    except ImportError:
        with wave.open(path, "wb") as w:
            w.setnchannels(pcm.shape[1])
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(pcm.tobytes())
    kb = os.path.getsize(path) / 1024.0
    print(f"  aud: {name:<28} {data.shape[0]/rate:5.2f}s  {pcm.shape[1]}ch  {kb:7.1f} KB  loop={loop}")


def t_axis(dur, rate=SR):
    return np.arange(int(dur * rate)) / rate


def t_n(n, rate=SR):
    """Time axis for an EXACT sample count (avoids float drift vs t_axis)."""
    return np.arange(int(n)) / rate


def crossfade_loop(x, fade=0.06, rate=SR):
    """Make a mono/stereo buffer loop seamlessly by crossfading tail into head."""
    n = int(fade * rate)
    if n * 2 >= x.shape[0]:
        return x
    head = x[:n].copy()
    tail = x[-n:].copy()
    ramp = np.linspace(0, 1, n)[:, None] if x.ndim > 1 else np.linspace(0, 1, n)
    mixed = head * ramp + tail * (1 - ramp)
    out = x[:-n].copy()
    out[:n] = mixed
    return out


def lowpass(x, cutoff, rate=SR, order=2):
    from scipy.signal import butter, sosfilt
    sos = butter(order, cutoff / (rate / 2), btype="low", output="sos")
    return sosfilt(sos, x, axis=0)


def highpass(x, cutoff, rate=SR, order=2):
    from scipy.signal import butter, sosfilt
    sos = butter(order, cutoff / (rate / 2), btype="high", output="sos")
    return sosfilt(sos, x, axis=0)


def bandpass(x, lo, hi, rate=SR, order=3):
    from scipy.signal import butter, sosfilt
    sos = butter(order, [lo / (rate / 2), hi / (rate / 2)], btype="band", output="sos")
    return sosfilt(sos, x, axis=0)


def env_ad(n, attack, decay, curve=2.0):
    e = np.zeros(n)
    a = max(1, int(attack * n))
    e[:a] = np.linspace(0, 1, a) ** 1.5
    e[a:] = np.linspace(1, 0, n - a) ** curve
    return e


def brown_noise(n, seed=0):
    rng = np.random.default_rng(seed)
    w = rng.standard_normal(n)
    b = np.cumsum(w)
    b -= np.linspace(b[0], b[-1], n)
    b /= np.max(np.abs(b)) + 1e-9
    return b


# --------------------------------------------------------------------------------------
def aud_hum(dur=4.0):
    """Fluorescent tube ballast hum: 100 Hz mains ripple + harmonics + hiss + crackle."""
    t = t_axis(dur)
    n = len(t)
    out = np.zeros(n)
    for k, amp in ((1, 0.55), (2, 0.30), (3, 0.18), (4, 0.09), (5, 0.05), (6, 0.03)):
        f = 100.0 * k
        ph = 0.0 if k % 2 == 0 else 0.4
        out += amp * np.sin(2 * np.pi * f * t + ph + 0.35 * np.sin(2 * np.pi * 0.11 * f / 100 * t))
    # slow amplitude drift
    out *= 0.85 + 0.15 * np.sin(2 * np.pi * 0.23 * t + 1.0)
    out *= 0.9 + 0.1 * np.sin(2 * np.pi * 0.07 * t)
    rng = np.random.default_rng(5)
    hiss = highpass(rng.standard_normal(n), 2200) * 0.035
    out += hiss
    # crackle
    for _ in range(int(dur * 2.2)):
        i = rng.integers(0, n - 200)
        ln = rng.integers(6, 60)
        out[i:i + ln] += rng.standard_normal(ln) * rng.uniform(0.05, 0.20) * env_ad(ln, 0.2, 0.8)
    out = lowpass(out, 6500)
    write_wav("hum.wav", crossfade_loop(out[:, None] * 0.5), loop=True)


def aud_ambience(dur=16.0):
    """Deep room tone: HVAC drone, beating sub bass, distant structural groans."""
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(17)
    out = np.zeros((n, 2))

    sub = np.zeros(n)
    for f, a in ((38.0, 0.5), (57.5, 0.30), (76.0, 0.16), (114.0, 0.07)):
        det = 1.0 + rng.uniform(-0.0016, 0.0016)
        sub += a * np.sin(2 * np.pi * f * det * t + rng.uniform(0, 6.28))
    sub *= 0.75 + 0.25 * np.sin(2 * np.pi * 0.031 * t)

    air = lowpass(brown_noise(n, seed=18), 420) * 0.30
    air *= 0.85 + 0.15 * np.sin(2 * np.pi * 0.05 * t + 2.0)
    hiss = bandpass(rng.standard_normal(n), 900, 3200) * 0.030

    mono = sub * 0.85 + air + hiss
    out[:, 0] = mono
    out[:, 1] = np.roll(mono, int(0.013 * SR))

    # distant metallic groans / knocks, panned
    for _ in range(9):
        i = rng.integers(0, n - int(2.2 * SR))
        ln = int(rng.uniform(0.5, 2.2) * SR)
        seg = t_n(ln)
        f0 = rng.uniform(48, 190)
        tone = np.sin(2 * np.pi * f0 * seg + 2.4 * np.sin(2 * np.pi * f0 * 0.37 * seg))
        tone += bandpass(rng.standard_normal(ln), f0 * 0.7, f0 * 4.0) * 0.7
        tone *= env_ad(ln, 0.25, 0.75, 2.4) * rng.uniform(0.05, 0.16)
        pan = rng.uniform(0.15, 0.85)
        out[i:i + ln, 0] += tone * (1 - pan)
        out[i:i + ln, 1] += tone * pan

    out = lowpass(out, 5200)
    write_wav("ambience.wav", crossfade_loop(out, 0.5), loop=True)


def aud_room_tone_dark(dur=12.0):
    """Wetter, deeper tone used in unlit sections."""
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(23)
    out = lowpass(brown_noise(n, seed=24), 210) * 0.55
    out += np.sin(2 * np.pi * 31.0 * t) * 0.22 * (0.8 + 0.2 * np.sin(2 * np.pi * 0.09 * t))
    drip = np.zeros(n)
    for _ in range(6):
        i = rng.integers(0, n - 4000)
        ln = 1400
        seg = np.sin(2 * np.pi * (1100 + rng.uniform(-300, 500)) * t_n(ln))
        seg *= env_ad(ln, 0.02, 0.98, 3.0) * rng.uniform(0.05, 0.14)
        drip[i:i + ln] += seg
    out = np.stack([out + drip, np.roll(out, 400) + np.roll(drip, -300)], axis=-1)
    write_wav("room_dark.wav", crossfade_loop(out, 0.4), loop=True)


def _footstep(dur, bright, seed, low_amt=1.0):
    rng = np.random.default_rng(seed)
    n = int(dur * SR)
    t = np.arange(n) / SR
    body = rng.standard_normal(n)
    body = bandpass(body, 120, 1400 if bright else 700)
    slap = lowpass(rng.standard_normal(n), 2600 if bright else 1200)
    e = env_ad(n, 0.012, 0.99, 3.2 if bright else 4.0)
    out = (body * 0.65 + slap * 0.5) * e
    thump = np.sin(2 * np.pi * rng.uniform(58, 88) * t) * env_ad(n, 0.02, 0.98, 3.5) * low_amt
    out += thump * 0.9
    # fabric scuff
    scuff = bandpass(rng.standard_normal(n), 1800, 5200) * env_ad(n, 0.35, 0.65) * 0.10
    out += scuff
    return out * rng.uniform(0.75, 1.0)


def aud_steps():
    for i, s in enumerate((101, 102, 103, 104)):
        write_wav(f"step_walk_{i+1}.wav", _footstep(0.30, False, s, 1.0)[:, None] * 0.7)
    for i, s in enumerate((111, 112, 113, 114)):
        write_wav(f"step_run_{i+1}.wav", _footstep(0.34, True, s, 1.35)[:, None] * 0.95)
    for i, s in enumerate((121, 122)):
        write_wav(f"step_crouch_{i+1}.wav", _footstep(0.26, False, s, 0.6)[:, None] * 0.42)
    for i, s in enumerate((131, 132, 133)):
        m = _footstep(0.42, True, s, 1.7)
        m = lowpass(m, 2400) * 1.15
        write_wav(f"step_monster_{i+1}.wav", m[:, None] * 0.9)


def aud_heartbeat(dur=1.0):
    t = t_axis(dur)
    n = len(t)
    out = np.zeros(n)
    for start, amp, f in ((0.00, 1.0, 52), (0.30, 0.62, 46)):
        i = int(start * SR)
        ln = int(0.30 * SR)
        seg = t_n(ln)
        beat = np.sin(2 * np.pi * f * seg) * np.exp(-seg * 13.0)
        beat += np.sin(2 * np.pi * f * 2.1 * seg) * np.exp(-seg * 22.0) * 0.4
        beat += lowpass(np.random.default_rng(7).standard_normal(ln), 200) * np.exp(-seg * 30) * 0.3
        out[i:i + ln] += beat * amp
    write_wav("heartbeat.wav", out[:, None] * 0.9)


def aud_growl(dur=1.8):
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(201)
    f0 = 62 + 26 * np.sin(2 * np.pi * 0.9 * t)
    carrier = np.sin(2 * np.pi * np.cumsum(f0) / SR)
    mod = np.sin(2 * np.pi * np.cumsum(f0 * 1.41) / SR)
    idx = 3.4 * env_ad(n, 0.18, 0.6) + 1.2
    fm = np.sin(2 * np.pi * np.cumsum(f0) / SR + idx * mod)
    breath = bandpass(rng.standard_normal(n), 200, 2600)
    out = (fm * 0.75 + carrier * 0.25) * 0.8 + breath * 0.30
    out = np.tanh(out * 2.6) * 0.7
    out *= env_ad(n, 0.10, 0.42, 1.7)
    out *= 0.8 + 0.2 * np.sin(2 * np.pi * 22 * t)
    out = lowpass(out, 3200)
    write_wav("growl.wav", out[:, None] * 0.95)


def aud_screech(dur=1.6):
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(301)
    pitch = 780 + 1750 * np.exp(-t * 2.2) - 500 * np.clip(t - 0.85, 0, None)
    pitch = np.clip(pitch, 260, 3200)
    ph = 2 * np.pi * np.cumsum(pitch) / SR
    mod = np.sin(2 * np.pi * np.cumsum(pitch * 0.503) / SR)
    out = np.sin(ph + (5.0 * np.exp(-t * 1.5) + 1.0) * mod)
    out += np.sin(ph * 1.5 + 0.7) * 0.35
    out += bandpass(rng.standard_normal(n), 900, 6000) * 0.5
    out = np.tanh(out * 3.4)
    e = env_ad(n, 0.035, 0.55, 1.5)
    out *= e
    # feedback delay tail (cave-ish)
    tail = out.copy()
    for k in range(1, 5):
        d = int(0.083 * k * SR)
        g = 0.42 ** k
        tail[d:] += out[:-d] * g
    out = out * 0.7 + tail * 0.42
    out = lowpass(out, 9000)
    write_wav("screech.wav", out[:, None] * 0.98)


def aud_jumpscare(dur=2.4):
    """The kill scream: a FNAF-style animatronic shriek. Layers:
    sub-bass impact, distorted formant roar, metallic multi-partial shriek
    with fast pitch wobble, noise blast, and a chattering bite-snap layer.
    Heavy tanh/bit-crush and a brickwall so it slams at full scale."""
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(666)
    # --- 1. impact / sub
    sub_f = 42 + 90 * np.exp(-t * 9.0)
    sub = np.sin(2 * np.pi * np.cumsum(sub_f) / SR) * np.exp(-t * 2.2)
    thump = lowpass(rng.standard_normal(n), 180) * np.exp(-t * 14.0) * 3.0
    # --- 2. roar: sawtooth-ish glottal pulse train through 3 formants
    f0 = 118 + 32 * np.sin(2 * np.pi * 7.3 * t) * (1 + 1.5 * t) + 40 * np.exp(-t * 3.0)
    ph = np.cumsum(f0) / SR
    pulse = np.zeros(n)
    for k in range(1, 40):
        pulse += np.sin(2 * np.pi * ph * k) / (k ** 0.6)
    roar = np.zeros(n)
    for (fc, bw, g) in ((520, 220, 1.0), (1180, 300, 0.8), (2600, 500, 0.6), (3400, 600, 0.45)):
        roar += bandpass(pulse, max(40, fc - bw), fc + bw) * g
    roar = np.tanh(roar * 4.5)
    # --- 3. metallic shriek: inharmonic partials + fast vibrato + rising
    shr_base = 1450 + 900 * np.exp(-t * 1.4) + 600 * np.clip(t - 1.2, 0, None)
    vib = 1.0 + 0.045 * np.sin(2 * np.pi * (23 + 11 * t) * t)
    shriek = np.zeros(n)
    for ratio, g in ((1.0, 1.0), (1.41, 0.7), (1.79, 0.55), (2.23, 0.45), (2.97, 0.35), (3.61, 0.25)):
        f = shr_base * ratio * vib
        shriek += np.sin(2 * np.pi * np.cumsum(f) / SR + rng.uniform(0, 6.28)) * g
    shriek = np.tanh(shriek * 2.2)
    # ring-mod the shriek for that speaker-blown animatronic buzz
    shriek *= (0.55 + 0.45 * np.sign(np.sin(2 * np.pi * 61.0 * t)))
    # --- 4. noise blast
    blast = bandpass(rng.standard_normal(n), 700, 9000) * (np.exp(-t * 3.5) * 0.9 + 0.25)
    # --- 5. bite snaps: 6 sharp clicks/clacks locked to the jaw loop (0.42 s)
    snaps = np.zeros(n)
    for k in range(6):
        ts = 0.30 + k * 0.42
        i0 = int(ts * SR)
        if i0 >= n:
            break
        ln = int(0.055 * SR)
        seg = rng.standard_normal(ln) * np.exp(-np.arange(ln) / (0.006 * SR))
        seg = bandpass(seg, 900, 5200) * 3.5
        tooth = np.sin(2 * np.pi * 2900 * np.arange(ln) / SR) * np.exp(-np.arange(ln) / (0.012 * SR)) * 1.2
        snaps[i0:i0 + ln] += (seg + tooth)[: n - i0]
    # --- mix + envelope
    env = np.ones(n)
    a = int(0.012 * SR)
    env[:a] = np.linspace(0, 1, a)
    tail = int(0.55 * SR)
    env[-tail:] *= np.linspace(1, 0, tail) ** 1.6
    # the roar swells in for the first 0.25 s, shriek is instant
    swell = np.clip(t / 0.25, 0, 1)
    mix = sub * 1.6 + thump + roar * 1.3 * swell + shriek * 1.15 + blast * 0.55 + snaps * 1.1
    mix *= env
    # bit-crush a touch + hard clip + brickwall
    q = 2 ** 9
    mix = np.round(mix * q) / q
    mix = np.tanh(mix * 1.9) / np.tanh(1.9)
    mix = highpass(mix, 28)
    peak = np.max(np.abs(mix))
    mix = mix / peak * 0.995
    write_wav("jumpscare_scream.wav", mix[:, None])


def aud_stinger(dur=2.6):
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(401)
    out = np.zeros(n)
    # sub impact
    ln = int(0.9 * SR)
    seg = t_n(ln)
    imp = np.sin(2 * np.pi * (120 * np.exp(-seg * 6.0) + 32) * seg) * np.exp(-seg * 3.4)
    out[:ln] += imp
    # dissonant cluster
    for f in (155.0, 164.8, 233.1, 311.1, 466.2):
        out += np.sin(2 * np.pi * f * t + 1.3 * np.sin(2 * np.pi * 5.1 * t)) * np.exp(-t * 1.1) * 0.14
    out += bandpass(rng.standard_normal(n), 300, 5200) * 0.16 * np.exp(-t * 1.6)
    out = np.tanh(out * 2.0)
    write_wav("stinger.wav", out[:, None] * 0.95)


def aud_monster_breath(dur=4.0):
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(501)
    out = np.zeros(n)
    for phase, (cyc, inh) in enumerate(((0.0, 0.45), (2.05, 0.40))):
        i = int(cyc * SR)
        ln = int(1.7 * SR)
        if i + ln > n:
            ln = n - i
        seg = t_n(ln)
        shape = np.sin(np.pi * np.clip(seg / (inh * 2.4), 0, 1)) ** 1.6
        noise = rng.standard_normal(ln)
        wet = bandpass(noise, 320, 1500)
        gurgle = 1.0 + 0.55 * np.sin(2 * np.pi * rng.uniform(17, 33) * seg)
        rasp = bandpass(noise, 1500, 4200) * 0.35
        out[i:i + ln] += (wet * gurgle + rasp) * shape * 0.85
    out = np.tanh(out * 1.7) * 0.8
    out = lowpass(out, 4600)
    write_wav("monster_breath.wav", crossfade_loop(out[:, None], 0.25), loop=True)


def aud_breath(dur=1.1, inhale=True, seed=601):
    rng = np.random.default_rng(seed)
    n = int(dur * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    shp = np.sin(np.pi * t / dur) ** (1.4 if inhale else 1.9)
    lo, hi = (400, 1500) if inhale else (300, 1100)
    out = bandpass(noise, lo, hi) * shp * 0.9
    out += bandpass(noise, 1800, 4200) * shp * 0.22
    out = np.tanh(out * 1.6)
    write_wav(("breath_in.wav" if inhale else "breath_out.wav"), out[:, None] * 0.7)


def aud_whisper(dur=3.0):
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(701)
    noise = rng.standard_normal(n)
    out = np.zeros(n)
    pos = 0.0
    while pos < dur - 0.3:
        ln = rng.uniform(0.10, 0.30)
        i = int(pos * SR)
        l = min(int(ln * SR), n - i)
        seg = t_n(l)
        e = np.sin(np.pi * seg / ln) ** 1.3
        f1 = rng.uniform(300, 900)
        s = bandpass(noise[i:i + l], f1, f1 + rng.uniform(600, 1800)) * e
        s += bandpass(noise[i:i + l], 2000, 5200) * e * 0.3
        out[i:i + l] += s * rng.uniform(0.4, 0.9)
        pos += ln + rng.uniform(0.03, 0.16)
    out = lowpass(out, 6500) * 0.6
    out *= env_ad(n, 0.12, 0.20, 1.4)
    write_wav("whisper.wav", out[:, None])


def aud_static_burst(dur=0.7):
    n = int(dur * SR)
    rng = np.random.default_rng(801)
    out = rng.standard_normal((n, 2))
    drop = (rng.random(n) > 0.06).astype(float)
    out *= (drop[:, None] * 0.85 + 0.15)
    out *= env_ad(n, 0.02, 0.25, 1.2)[:, None]
    out = highpass(out, 300)
    write_wav("static_burst.wav", out * 0.6)


def aud_zap(dur=0.28):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(901)
    out = rng.standard_normal(n) * np.exp(-t * 22.0)
    out *= 0.5 + 0.5 * np.sign(np.sin(2 * np.pi * 100 * t))
    out += np.sin(2 * np.pi * (2400 * np.exp(-t * 12) + 180) * t) * np.exp(-t * 16) * 0.7
    out = np.tanh(out * 2.2) * 0.8
    write_wav("zap.wav", out[:, None])


def aud_flicker(dur=1.4):
    n = int(dur * SR)
    rng = np.random.default_rng(911)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for _ in range(9):
        i = rng.integers(0, n - 300)
        ln = rng.integers(20, 260)
        out[i:i + ln] += rng.standard_normal(ln) * rng.uniform(0.2, 0.7) * env_ad(ln, 0.1, 0.9)
    out += np.sin(2 * np.pi * 100 * t) * 0.12 * (rng.random(n) > 0.5)
    out = lowpass(out, 5000) * 0.7
    write_wav("flicker.wav", out[:, None])


def aud_pickup(dur=0.45):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1001)
    out = np.sin(2 * np.pi * 880 * t) * np.exp(-t * 9) * 0.35
    out += np.sin(2 * np.pi * 1320 * t) * np.exp(-t * 12) * 0.22
    out += bandpass(rng.standard_normal(n), 900, 4000) * np.exp(-t * 26) * 0.5
    write_wav("pickup.wav", out[:, None] * 0.75)


def aud_fuse(dur=0.8):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1011)
    out = bandpass(rng.standard_normal(n), 1200, 5200) * np.exp(-t * 14) * 0.8
    out += np.sin(2 * np.pi * (520 + 240 * np.exp(-t * 4)) * t) * np.exp(-t * 5.5) * 0.5
    for k in (2, 3, 5):
        out += np.sin(2 * np.pi * 340 * k * t) * np.exp(-t * (6 + k)) * 0.14
    write_wav("fuse.wav", out[:, None] * 0.85)


def aud_door(dur=1.5):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1101)
    freq = 220 + 380 * (t / dur) + 60 * np.sin(2 * np.pi * 7 * t)
    creak = np.sin(2 * np.pi * np.cumsum(freq) / SR)
    creak = bandpass(creak, 180, 3000)
    creak *= env_ad(n, 0.22, 0.30, 1.5) * 0.5
    noise = bandpass(rng.standard_normal(n), 400, 2600) * env_ad(n, 0.3, 0.4) * 0.18
    clang = np.sin(2 * np.pi * 168 * t) * np.exp(-t * 5.0) * 0.4
    clang += np.sin(2 * np.pi * 251 * t) * np.exp(-t * 6.5) * 0.25
    out = creak + noise
    i = int(0.95 * SR)
    out[i:] += clang[:n - i]
    write_wav("door.wav", out[:, None] * 0.8)


def aud_nvg(dur=2.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1201)
    out = np.sin(2 * np.pi * 11400 * t) * 0.10
    out += np.sin(2 * np.pi * 15800 * t) * 0.045
    out += highpass(rng.standard_normal(n), 3000) * 0.055
    out *= 0.9 + 0.1 * np.sin(2 * np.pi * 6.3 * t)
    write_wav("nvg_whine.wav", crossfade_loop(out[:, None]), loop=True)


def aud_click(dur=0.12):
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.sin(2 * np.pi * 2200 * t) * np.exp(-t * 60) * 0.6
    out += np.sin(2 * np.pi * 640 * t) * np.exp(-t * 45) * 0.5
    write_wav("click.wav", out[:, None] * 0.7)


def aud_deny(dur=0.35):
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.sign(np.sin(2 * np.pi * 150 * t)) * 0.35 * np.exp(-t * 6)
    out += np.sin(2 * np.pi * 96 * t) * np.exp(-t * 8) * 0.5
    write_wav("deny.wav", out[:, None] * 0.7)


def aud_distant_bang(dur=1.6):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1301)
    out = np.sin(2 * np.pi * (95 * np.exp(-t * 5) + 41) * t) * np.exp(-t * 3.0)
    out += lowpass(rng.standard_normal(n), 300) * np.exp(-t * 4.5) * 0.7
    tail = out.copy()
    for k in range(1, 4):
        d = int(0.19 * k * SR)
        tail[d:] += out[:-d] * (0.34 ** k)
    out = out * 0.6 + tail * 0.5
    write_wav("distant_bang.wav", lowpass(out, 900)[:, None] * 0.9)


def aud_noise_made(dur=0.5):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(1401)
    out = bandpass(rng.standard_normal(n), 200, 1800) * env_ad(n, 0.08, 0.6, 2.2) * 0.6
    out = lowpass(out, 1500)
    write_wav("noise_pulse.wav", out[:, None] * 0.7)


def build_audio():
    print("[audio]")
    aud_hum()
    aud_ambience()
    aud_room_tone_dark()
    aud_steps()
    aud_heartbeat()
    aud_growl()
    aud_screech()
    aud_jumpscare()
    aud_stinger()
    aud_monster_breath()
    aud_breath(1.1, True)
    aud_breath(1.3, False)
    aud_whisper()
    aud_static_burst()
    aud_zap()
    aud_flicker()
    aud_pickup()
    aud_fuse()
    aud_door()
    aud_nvg()
    aud_click()
    aud_deny()
    aud_distant_bang()
    aud_noise_made()
    build_atmosphere()


# ---------------------------------------------------------------- atmosphere pack
def aud_pipe_knock(seed=1201, n_var=3):
    """Metal pipe knocks somewhere in the walls, 1..3 hits with a ring-out."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 1.6
        n = int(dur * SR)
        t = np.arange(n) / SR
        out = np.zeros(n)
        hits = rng.integers(1, 4)
        pos = 0.05
        for _ in range(hits):
            i = int(pos * SR)
            f = rng.uniform(140, 260)
            ring = (np.sin(2 * np.pi * f * t) * np.exp(-t * 9) +
                    np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 14) * 0.5 +
                    np.sin(2 * np.pi * f * 5.4 * t) * np.exp(-t * 22) * 0.25)
            click = bandpass(rng.standard_normal(n), 1500, 6000) * np.exp(-t * 60) * 0.6
            h = (ring + click) * rng.uniform(0.6, 1.0)
            out[i:] += h[:n - i]
            pos += rng.uniform(0.18, 0.45)
        out = lowpass(out, 5000)
        write_wav("pipe_knock_%d.wav" % (v + 1), out[:, None] * 0.8)


def aud_creak(seed=1301, n_var=3):
    """Slow structural creak / settling groan in the wallpaper walls."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = rng.uniform(1.4, 2.6)
        n = int(dur * SR)
        t = np.arange(n) / SR
        f = rng.uniform(70, 140) * (1 + 0.35 * np.sin(2 * np.pi * rng.uniform(0.4, 1.2) * t + rng.uniform(0, 6)))
        ph = 2 * np.pi * np.cumsum(f) / SR
        sig = np.sign(np.sin(ph)) * 0.35 + np.sin(ph * 2.02) * 0.4 + np.sin(ph * 3.1) * 0.2
        stick = bandpass(rng.standard_normal(n), 300, 1800) * (0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(9, 16) * t)) * 0.4
        out = (sig + stick) * env_ad(n, 0.35, 0.5, 1.4)
        out = lowpass(out, 2200)
        write_wav("creak_%d.wav" % (v + 1), out[:, None] * 0.7)


def aud_drip(seed=1401, n_var=3):
    """Single water drip into a shallow puddle."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.7
        n = int(dur * SR)
        t = np.arange(n) / SR
        f0 = rng.uniform(900, 1500)
        chirp = np.sin(2 * np.pi * (f0 * t + 1800 * t * t)) * np.exp(-t * 28)
        body = np.sin(2 * np.pi * rng.uniform(320, 480) * t) * np.exp(-t * 18) * 0.5
        splash = bandpass(rng.standard_normal(n), 2000, 7000) * np.exp(-t * 40) * 0.25
        out = chirp + body + splash
        write_wav("drip_%d.wav" % (v + 1), out[:, None] * 0.7)


def aud_lamp_buzz(dur=3.0):
    """Dying fluorescent tube: harsh 100 Hz buzz with sputter. Looped."""
    rng = np.random.default_rng(1501)
    n = int(dur * SR)
    t = np.arange(n) / SR
    buzz = np.sign(np.sin(2 * np.pi * 100 * t)) * 0.3 + np.sin(2 * np.pi * 200 * t) * 0.3 + np.sin(2 * np.pi * 300 * t) * 0.15
    sput = (rng.random(n) < 0.0009).astype(float)
    sput = np.convolve(sput, np.exp(-np.arange(400) / 60.0), mode="same") * 3.0
    gate = 0.6 + 0.4 * (np.sin(2 * np.pi * 3.3 * t) > -0.3)
    out = (buzz * gate + bandpass(rng.standard_normal(n), 2000, 8000) * 0.05) * (1 + sput)
    out = highpass(out, 80)
    write_wav("lamp_buzz.wav", crossfade_loop(out[:, None] * 0.6, 0.2), loop=True)


def aud_hvac_surge(dur=5.0):
    """Ventilation kicks in: a rising whoosh + duct rattle, then settles."""
    rng = np.random.default_rng(1601)
    n = int(dur * SR)
    t = np.arange(n) / SR
    env = np.clip(t / 1.2, 0, 1) * np.exp(-np.clip(t - 3.0, 0, None) * 1.8)
    wind = (lowpass(rng.standard_normal(n), 500) * (1 - env * 0.6) + lowpass(rng.standard_normal(n), 1400) * env * 0.6) * env
    rattle = bandpass(rng.standard_normal(n), 900, 2400) * (rng.random(n) < 0.02) * env * 1.5
    rattle = np.convolve(rattle, np.exp(-np.arange(300) / 50.0), mode="same")
    thump = np.sin(2 * np.pi * 48 * t) * np.exp(-t * 4) * 0.7
    out = wind * 0.6 + rattle * 0.3 + thump
    write_wav("hvac_surge.wav", out[:, None] * 0.75)


def aud_far_voices(dur=4.5):
    """Unintelligible murmur far down a corridor -- formants without words."""
    rng = np.random.default_rng(1701)
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(3):
        f0 = rng.uniform(95, 180) * (1 + 0.08 * np.sin(2 * np.pi * rng.uniform(2, 5) * t))
        src = np.sign(np.sin(2 * np.pi * np.cumsum(f0) / SR)) * 0.5 + rng.standard_normal(n) * 0.1
        voice = np.zeros(n)
        for F, bw in ((rng.uniform(300, 700), 90), (rng.uniform(900, 1800), 140), (rng.uniform(2200, 3000), 220)):
            fm = F * (1 + 0.25 * np.sin(2 * np.pi * rng.uniform(1.5, 4.0) * t + rng.uniform(0, 6)))
            voice += bandpass(src, np.max(fm) - bw, np.max(fm) + bw) * 0.5
        syll = 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(3, 5) * t + rng.uniform(0, 6))
        gaps = (np.sin(2 * np.pi * rng.uniform(0.3, 0.6) * t + rng.uniform(0, 6)) > -0.2)
        out += voice * syll * gaps * rng.uniform(0.4, 0.8)
    out = lowpass(out, 1800) * env_ad(n, 0.8, 1.2, 1.3)
    write_wav("far_voices.wav", out[:, None] * 0.55)


def aud_far_steps(dur=3.2):
    """Someone (something?) walking far away, evenly, then stopping."""
    rng = np.random.default_rng(1801)
    n = int(dur * SR)
    out = np.zeros(n)
    pos = 0.1
    while pos < dur - 0.4:
        i = int(pos * SR)
        m = int(0.25 * SR)
        tt = np.arange(m) / SR
        st = (np.sin(2 * np.pi * rng.uniform(55, 80) * tt) * np.exp(-tt * 28) +
              bandpass(rng.standard_normal(m), 250, 1400) * np.exp(-tt * 45) * 0.5)
        out[i:i + m] += st * rng.uniform(0.7, 1.0)
        pos += rng.uniform(0.52, 0.6)
    out = lowpass(out, 900)
    write_wav("far_steps.wav", out[:, None] * 0.8)


def aud_brownout(dur=2.4):
    """Power sag: the hum drops an octave and comes back with a thunk."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    sag = 1.0 - 0.5 * np.exp(-((t - 0.9) / 0.5) ** 2)
    f = 100 * sag
    hum = np.sin(2 * np.pi * np.cumsum(f) / SR) * 0.35 + np.sin(2 * np.pi * np.cumsum(f * 2) / SR) * 0.2
    hum *= 0.4 + 0.6 * sag
    thunk = np.sin(2 * np.pi * 60 * t) * np.exp(-np.clip(t - 1.55, 0, None) * 12) * (t > 1.55) * 0.9
    out = hum + thunk
    write_wav("brownout.wav", out[:, None] * 0.8)


def build_atmosphere():
    aud_pipe_knock()
    aud_creak()
    aud_drip()
    aud_lamp_buzz()
    aud_hvac_surge()
    aud_far_voices()
    aud_far_steps()
    aud_brownout()
    build_spider()


# ---------------------------------------------------------------- spider pack (Level 2)
def aud_spider_click(seed=1501, n_var=3):
    """Chitin clicks / mandible chatter: 4-9 dry ticks in a burst."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.9
        n = int(dur * SR)
        t = np.arange(n) / SR
        out = np.zeros(n)
        pos = 0.02
        for _ in range(rng.integers(4, 10)):
            i = int(pos * SR)
            f = rng.uniform(1800, 4200)
            tick = (np.sin(2 * np.pi * f * t) * np.exp(-t * 260) +
                    bandpass(rng.standard_normal(n), 2500, 9000) * np.exp(-t * 180) * 0.8)
            tick *= rng.uniform(0.5, 1.0)
            out[i:] += tick[:n - i]
            pos += rng.uniform(0.04, 0.13)
        out = highpass(out, 900)
        write_wav("spider_click_%d.wav" % (v + 1), out[:, None] * 0.8)


def aud_spider_step(seed=1601, n_var=3):
    """A single hard leg tap on concrete (tip of a chitin leg)."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.22
        n = int(dur * SR)
        t = np.arange(n) / SR
        f = rng.uniform(700, 1300)
        out = (np.sin(2 * np.pi * f * t) * np.exp(-t * 90) * 0.7 +
               bandpass(rng.standard_normal(n), 1200, 7000) * np.exp(-t * 70) +
               np.sin(2 * np.pi * rng.uniform(140, 220) * t) * np.exp(-t * 40) * 0.5)
        write_wav("spider_step_%d.wav" % (v + 1), out[:, None] * 0.8)


def aud_spider_hiss(dur=1.6):
    """Wet, airy hiss with a rattle underneath."""
    rng = np.random.default_rng(1701)
    n = int(dur * SR)
    t = np.arange(n) / SR
    air = bandpass(rng.standard_normal(n), 1800, 9000)
    air *= 0.6 + 0.4 * np.sin(2 * np.pi * 23 * t)
    rattle = np.sign(np.sin(2 * np.pi * (38 + 20 * t) * t)) * bandpass(rng.standard_normal(n), 300, 1500) * 0.5
    out = (air + rattle) * env_ad(n, 0.12, 0.55, 1.6)
    out = lowpass(out, 9500)
    write_wav("spider_hiss.wav", out[:, None] * 0.8)


def aud_spider_screech(dur=1.8):
    """Higher, shriller than the Level 0 creature: a chittering shriek."""
    t = t_axis(dur)
    n = len(t)
    rng = np.random.default_rng(1801)
    pitch = 1400 + 2600 * np.exp(-t * 3.0) - 700 * np.clip(t - 0.9, 0, None)
    pitch = np.clip(pitch, 500, 5200)
    ph = 2 * np.pi * np.cumsum(pitch) / SR
    trem = 0.55 + 0.45 * np.sign(np.sin(2 * np.pi * 31 * t))
    out = np.sin(ph + 3.0 * np.sin(ph * 0.49)) * trem
    out += np.sin(ph * 1.5) * 0.3
    out += bandpass(rng.standard_normal(n), 1500, 9000) * 0.55
    out = np.tanh(out * 3.0)
    out *= env_ad(n, 0.03, 0.5, 1.4)
    tail = out.copy()
    for k in range(1, 4):
        d = int(0.07 * k * SR)
        tail[d:] += out[:-d] * (0.4 ** k)
    out = out * 0.7 + tail * 0.4
    write_wav("spider_screech.wav", out[:, None] * 0.98)


def aud_crate(seed=1901):
    """Wooden crate: climbing in (creak + thud) and lid settling."""
    rng = np.random.default_rng(seed)
    dur = 1.1
    n = int(dur * SR)
    t = np.arange(n) / SR
    creak = np.sign(np.sin(2 * np.pi * (90 + 60 * np.sin(2 * np.pi * 1.3 * t)) * t)) * 0.3
    creak *= env_ad(n, 0.2, 0.5, 1.5) * (t < 0.55)
    thud = np.sin(2 * np.pi * 75 * t) * np.exp(-(t - 0.5).clip(0) * 25) * (t > 0.5) * 0.9
    knock = bandpass(rng.standard_normal(n), 400, 2500) * np.exp(-(t - 0.5).clip(0) * 40) * (t > 0.5) * 0.5
    out = lowpass(creak + thud + knock, 3500)
    write_wav("crate.wav", out[:, None] * 0.85)


def build_spider():
    aud_spider_click()
    aud_spider_step()
    aud_spider_hiss()
    aud_spider_screech()
    aud_crate()


def build_icon():
    size = 256
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    d = np.sqrt((xx - 128) ** 2 + (yy - 128) ** 2) / 128
    col = np.zeros((size, size, 3))
    col += np.array([0.72, 0.60, 0.24]) * np.clip(1.1 - d, 0, 1)[..., None]
    col += fbm(size, 5, 3, 0.5, seed=9)[:, :, None] * np.array([0.10, 0.08, 0.02])
    # eyes
    for cx in (94, 162):
        e = np.exp(-(((xx - cx) / 13) ** 2 + ((yy - 122) / 8) ** 2))
        col += e[:, :, None] * np.array([1.0, 0.95, 0.8]) * 1.6
    # grin
    g = np.exp(-(((yy - (168 + 8 * np.cos((xx - 128) / 26))) / 5) ** 2)) * (np.abs(xx - 128) < 46)
    col += g[:, :, None] * np.array([0.95, 0.92, 0.8]) * 1.2
    a = np.clip(1.0 - np.clip(d - 0.92, 0, 1) * 12.0, 0, 1)
    rgba = np.dstack([np.clip(col, 0, 1), a])
    Image.fromarray((rgba * 255).astype(np.uint8), "RGBA").save(os.path.join(ROOT, "icon.png"))
    print("  icon.png")


# ---------------------------------------------------------------- jumpscare face
def gen_jumpscare_face(out_dir):
    """Pale faceless visage with black sockets and a toothy grin (512x512)."""
    import numpy as np
    import scipy.ndimage as ndi
    S = 512
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    cx = cy = S / 2
    img = np.zeros((S, S, 3))
    d = np.sqrt(((xx - cx) / (S * 0.30)) ** 2 + ((yy - cy) / (S * 0.42)) ** 2)
    face = np.clip(1.0 - d, 0, 1) ** 0.7
    noise = ndi.gaussian_filter(rng.random((S, S)), 3)
    face *= (0.75 + 0.5 * noise)
    img += face[..., None] * np.array([0.62, 0.58, 0.52])
    img *= (1.0 - 0.5 * np.exp(-(((yy - cy) / (S * 0.5)) ** 2))[..., None] * 0.3)
    for ex in (-0.13, 0.13):
        e = np.exp(-(((xx - cx - ex * S) / (S * 0.075)) ** 2 + ((yy - cy + 0.10 * S) / (S * 0.10)) ** 2))
        img *= (1.0 - e[..., None] * 0.97)
        g = np.exp(-(((xx - cx - ex * S) / (S * 0.012)) ** 2 + ((yy - cy + 0.10 * S) / (S * 0.012)) ** 2))
        img += g[..., None] * np.array([0.9, 0.9, 0.85]) * 0.8
    grin_y = cy + 0.16 * S + 0.05 * S * np.cos((xx - cx) / (S * 0.16))
    grin = np.exp(-(((yy - grin_y) / (S * 0.085)) ** 2)) * np.clip(1 - np.abs(xx - cx) / (S * 0.24), 0, 1)
    img *= (1.0 - grin[..., None] * 0.96)
    teeth = (np.sin(xx / 3.1) > 0.2) * grin * np.exp(-(((yy - grin_y + S * 0.03) / (S * 0.03)) ** 2))
    img += teeth[..., None] * np.array([0.75, 0.72, 0.62]) * 0.9
    teeth2 = (np.sin(xx / 3.1 + 1.3) > 0.2) * grin * np.exp(-(((yy - grin_y - S * 0.035) / (S * 0.025)) ** 2))
    img += teeth2[..., None] * np.array([0.6, 0.58, 0.5]) * 0.7
    veins = np.clip(1 - np.abs(ndi.gaussian_filter(rng.random((S, S)), 2) - 0.5) * 14, 0, 1) ** 2
    img *= (1 - veins[..., None] * 0.35 * face[..., None])
    vr = np.sqrt(((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2)
    img *= np.clip(1.15 - vr, 0, 1)[..., None] ** 1.4
    img += (rng.random((S, S, 3)) - 0.5) * 0.06
    img = np.clip(img, 0, 1)
    Image.fromarray((img * 255).astype(np.uint8), "RGB").save(os.path.join(out_dir, "jumpscare.png"))



def build_paper():
    """Scattered office paper: 4 sheets in a 2x2 atlas (RGBA, 512x512).
    Yellowed A4s with faint typewriter lines, a form, a smear, a torn note."""
    rng = np.random.default_rng(4242)
    S = 512
    atlas = np.zeros((S, S, 4), dtype=np.float32)
    def sheet(kind):
        h, w = 256, 256
        img = np.zeros((h, w, 4), dtype=np.float32)
        # sheet rect (A4-ish inside the tile), slight yellowing gradient
        y0, y1, x0, x1 = 14, 242, 36, 220
        base = np.array([0.86, 0.82, 0.70])
        yy, xx = np.mgrid[y0:y1, x0:x1]
        stain = periodic_value_noise(256, 6, rng)[y0:y1, x0:x1]
        col = base[None, None, :] * (0.78 + 0.32 * stain)[..., None]
        col *= (1.0 - 0.18 * ((yy - y0) / (y1 - y0)))[..., None]   # darker bottom
        img[y0:y1, x0:x1, :3] = col
        img[y0:y1, x0:x1, 3] = 1.0
        ink = np.array([0.12, 0.11, 0.10])
        if kind == 0:      # typed lines
            for ly in range(y0 + 30, y1 - 20, 11):
                ln = rng.integers(60, 170)
                for lx in range(x0 + 22, x0 + 22 + ln, 5):
                    if rng.random() < 0.82:
                        img[ly:ly + 6, lx:lx + 3, :3] = ink * rng.uniform(0.6, 1.0)
        elif kind == 1:    # form with a table
            for ly in range(y0 + 26, y1 - 16, 22):
                img[ly, x0 + 14:x1 - 14, :3] = ink * 0.7
            for lx in (x0 + 14, x0 + 60, x0 + 120, x1 - 14):
                img[y0 + 26:y1 - 16, lx, :3] = ink * 0.7
            for ly in range(y0 + 32, y1 - 20, 22):
                for lx in range(x0 + 22, x1 - 26, 5):
                    if rng.random() < 0.35:
                        img[ly:ly + 5, lx:lx + 3, :3] = ink
        elif kind == 2:    # handwritten scrawl + big smear
            for k in range(9):
                cy = y0 + 40 + k * 20
                x = x0 + 20
                while x < x1 - 30:
                    seg = rng.integers(8, 26)
                    amp = rng.uniform(1.5, 4.5)
                    for i in range(seg):
                        yy2 = int(cy + amp * np.sin(i * 0.8 + k))
                        img[yy2:yy2 + 2, x + i, :3] = ink * 0.85
                    x += seg + rng.integers(3, 9)
            sm = periodic_value_noise(256, 4, rng)
            mask = np.clip((sm - 0.55) * 4.0, 0, 1)
            img[..., :3] = img[..., :3] * (1 - mask[..., None] * 0.6) + np.array([0.30, 0.14, 0.10]) * (mask[..., None] * 0.6)
        else:              # torn note, few big words
            img[:, :, :] = 0.0
            ty0, ty1, tx0, tx1 = 60, 200, 40, 216
            tear = (periodic_value_noise(256, 8, rng)[0, :] * 18).astype(int)
            for x in range(tx0, tx1):
                img[ty0 + tear[x]:ty1 - tear[(x * 3) % 256], x, :3] = base * rng.uniform(0.75, 0.95)
                img[ty0 + tear[x]:ty1 - tear[(x * 3) % 256], x, 3] = 1.0
            for ly in range(ty0 + 36, ty1 - 30, 24):
                for lx in range(tx0 + 24, tx1 - 30, 9):
                    if rng.random() < 0.7:
                        img[ly:ly + 12, lx:lx + 6, :3] = np.array([0.45, 0.08, 0.06])
        # paper grain + edge dirt
        g = periodic_value_noise(256, 48, rng)
        img[..., :3] *= (0.9 + 0.2 * g)[..., None]
        return img
    for k in range(4):
        r, c = divmod(k, 2)
        atlas[r * 256:(r + 1) * 256, c * 256:(c + 1) * 256] = sheet(k)
    save_rgba(atlas, "paper.png")


# ---------------------------------------------------------------- level 7 quest pack
def aud_dig(seed=1701, n_var=3):
    """Hands scraping through dry earth and gravel: one scoop per file."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.7
        n = int(dur * SR)
        t = np.arange(n) / SR
        scrape = bandpass(rng.standard_normal(n), 400, 3200) * env_ad(n, 0.05, 0.55, 1.5)
        # gravel: dozens of tiny clicks
        grav = np.zeros(n)
        for _ in range(int(rng.integers(25, 45))):
            i = int(rng.uniform(0.02, 0.6) * SR)
            ln = int(rng.uniform(0.003, 0.012) * SR)
            grav[i:i + ln] += rng.standard_normal(ln) * np.exp(-np.arange(ln) / ln * 4) * rng.uniform(0.3, 1.0)
        grav = highpass(grav, 1200)
        thud = np.sin(2 * np.pi * 70 * t) * np.exp(-t * 22) * 0.6
        out = lowpass(scrape * 0.7 + grav * 0.5 + thud, 6000)
        write_wav("dig_%d.wav" % (v + 1), out[:, None] * 0.85)


def aud_key_jingle(dur=0.9):
    rng = np.random.default_rng(1801)
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    pos = 0.0
    for _ in range(6):
        i = int(pos * SR)
        f = rng.uniform(2400, 5200)
        ring = (np.sin(2 * np.pi * f * t) * np.exp(-t * 30) + np.sin(2 * np.pi * f * 1.9 * t) * np.exp(-t * 45) * 0.4)
        out[i:] += ring[:n - i] * rng.uniform(0.4, 1.0)
        pos += rng.uniform(0.05, 0.13)
    out = highpass(out, 1500)
    write_wav("key_jingle.wav", out[:, None] * 0.6)


def aud_unlock(dur=1.4):
    rng = np.random.default_rng(1802)
    n = int(dur * SR)
    t = np.arange(n) / SR
    # key turns: grinding + two heavy clacks
    grind = bandpass(rng.standard_normal(n), 900, 2600) * env_ad(n, 0.02, 0.5, 1.0) * 0.35
    out = grind.copy()
    for pos, f in ((0.35, 180), (0.62, 140)):
        i = int(pos * SR)
        clack = (np.sin(2 * np.pi * f * t) * np.exp(-t * 14) + bandpass(rng.standard_normal(n), 1200, 5000) * np.exp(-t * 60) * 0.7)
        out[i:] += clack[:n - i]
    out = lowpass(out, 6500)
    write_wav("unlock.wav", out[:, None] * 0.9)


def aud_collapse(dur=2.6):
    """The rubble pile finally gives: a slide of earth, stones bouncing."""
    rng = np.random.default_rng(1803)
    n = int(dur * SR)
    t = np.arange(n) / SR
    slide = lowpass(brown_noise(n, 7), 900) * env_ad(n, 0.15, 1.6, 1.3) * 2.5
    hiss = bandpass(rng.standard_normal(n), 800, 4000) * env_ad(n, 0.1, 1.2, 1.2) * 0.4
    stones = np.zeros(n)
    for _ in range(40):
        i = int(rng.uniform(0.1, 2.0) * SR)
        f = rng.uniform(150, 600)
        ln = int(0.12 * SR)
        tt = np.arange(ln) / SR
        stones[i:i + ln] += np.sin(2 * np.pi * f * tt) * np.exp(-tt * 40) * rng.uniform(0.2, 0.8) * (1.0 - i / n)
    rumble = np.sin(2 * np.pi * 42 * t) * env_ad(n, 0.05, 1.0, 1.0) * 0.8
    out = slide + hiss + stones + rumble
    write_wav("collapse.wav", out[:, None] * 0.9)


def aud_stairs_step(seed=1901, n_var=3):
    """Boots on a steel stair tread: ringy, hollow."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.45
        n = int(dur * SR)
        t = np.arange(n) / SR
        f = rng.uniform(210, 330)
        ring = (np.sin(2 * np.pi * f * t) * np.exp(-t * 18) + np.sin(2 * np.pi * f * 2.3 * t) * np.exp(-t * 26) * 0.5)
        imp = bandpass(rng.standard_normal(n), 300, 3500) * np.exp(-t * 55)
        out = lowpass(ring * 0.5 + imp, 5000)
        write_wav("stairs_%d.wav" % (v + 1), out[:, None] * 0.8)


def build_level7():
    print("[level 7 audio]")
    aud_dig()
    aud_key_jingle()
    aud_unlock()
    aud_collapse()
    aud_stairs_step()


# ======================================================================================
#  v9: Level 3 tunnels + Level 4 "run or die"
# ======================================================================================
def aud_quake(dur=8.0):
    """Earthquake bed: brown-noise rumble with slow surges + sub throb. Loops."""
    n = int(dur * SR); t = np.arange(n) / SR
    rng = np.random.default_rng(2101)
    bed = lowpass(brown_noise(n, 11), 140) * 2.2
    surge = 0.55 + 0.45 * (0.5 + 0.5 * np.sin(2 * np.pi * t / dur * 3.0 + 0.7)) * (0.6 + 0.4 * np.sin(2 * np.pi * t / dur * 7.0))
    sub = np.sin(2 * np.pi * 31.0 * t + 2.0 * np.sin(2 * np.pi * 0.37 * t)) * 0.35
    grit = bandpass(rng.standard_normal(n), 300, 1800) * 0.06 * (0.5 + 0.5 * np.sin(2 * np.pi * t / dur * 5.0))
    out = (bed * surge + sub * surge + grit)
    out = crossfade_loop(out, 0.25)
    write_wav("quake.wav", out[:, None] * 0.9, loop=True)

def aud_fall_wind(dur=2.6):
    """Falling: wind rushing up, rising in pitch and level, cut by the fade."""
    n = int(dur * SR); t = np.arange(n) / SR
    rng = np.random.default_rng(2201)
    w = rng.standard_normal(n)
    out = np.zeros(n)
    # sweep the band upward in chunks
    chunk = int(0.1 * SR)
    for i in range(0, n, chunk):
        f = 250 + 1500 * (i / n) ** 1.4
        seg = bandpass(w[max(0, i - chunk):i + chunk], f * 0.6, f * 1.6)
        seg = seg[-min(chunk, n - i):] if i > 0 else seg[:chunk]
        out[i:i + len(seg)] += seg
    env = np.clip(t / 0.5, 0, 1) ** 1.5 * (0.5 + 0.5 * t / dur)
    out = out * env
    out += lowpass(brown_noise(n, 12), 200) * env * 0.8
    write_wav("fall_wind.wav", out[:, None] * 0.9)

def aud_rock_hit(seed=2301, n_var=3):
    """Concrete chunk landing: dull crack + grit scatter."""
    for v in range(n_var):
        rng = np.random.default_rng(seed + v)
        dur = 0.7; n = int(dur * SR); t = np.arange(n) / SR
        f = rng.uniform(70, 120)
        thump = np.sin(2 * np.pi * f * t * np.exp(-t * 2.0)) * np.exp(-t * 14)
        crack = bandpass(rng.standard_normal(n), 900, 5000) * np.exp(-t * 60) * 0.9
        grit = bandpass(rng.standard_normal(n), 1500, 7000) * np.exp(-t * 7) * 0.12 * (rng.random(n) > 0.6)
        out = thump * 1.4 + crack + grit
        write_wav("rock_hit_%d.wav" % (v + 1), out[:, None] * 0.9)


def build_v9():
    print("[v9 audio]")
    aud_quake()
    aud_fall_wind()
    aud_rock_hit()


def main():
    build_textures()
    build_audio()
    build_icon()
    gen_jumpscare_face(TEX_DIR)
    build_paper()
    build_level7()
    build_v9()
    print("DONE")


if __name__ == "__main__":
    main()
