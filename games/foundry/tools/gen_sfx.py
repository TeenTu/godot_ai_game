# 程序化生成买量风 8-bit 音效（纯标准库，无依赖）
# 输出: assets/audio/sfx_*.wav  (22050Hz 16bit mono)
import math
import struct
import wave
import os

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")


def env(i, n, a=0.01, r=0.6):
    """attack/release 包络：a=attack 比例, r=release 比例"""
    t = i / n
    if t < a:
        return t / a
    if t > 1 - r:
        return max(0.0, (1 - t) / r)
    return 1.0


def sine(f, t):
    return math.sin(2 * math.pi * f * t)


def square(f, t):
    return 1.0 if sine(f, t) >= 0 else -1.0


def write_wav(name, samples):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples
        ))
    print(f"  {name}: {len(samples)/SR:.2f}s")


def gen_click():
    n = int(SR * 0.05)
    return [0.5 * square(900, i / SR) * env(i, n, 0.02, 0.8) for i in range(n)]


def gen_coin():
    """双音叮当 E6->B6 带泛音"""
    n = int(SR * 0.16)
    out = []
    for i in range(n):
        t = i / SR
        f = 1319 if t < 0.07 else 1976
        v = 0.55 * sine(f, t) + 0.2 * sine(f * 2, t)
        out.append(v * env(i, n, 0.01, 0.75))
    return out


def gen_place():
    """木质低频咚 + 短噪声起音"""
    n = int(SR * 0.12)
    out = []
    for i in range(n):
        t = i / SR
        f = 200 * (1 - 0.4 * t / 0.12)  # 频率下滑
        v = 0.8 * sine(f, t) * math.exp(-t * 22)
        out.append(v * env(i, n, 0.005, 0.5))
    return out


def gen_go():
    """上行三连号角 C5-E5-G5 方波"""
    seq = [(523, 0.08), (659, 0.08), (784, 0.16)]
    out = []
    for f, d in seq:
        n = int(SR * d)
        out += [0.4 * square(f, i / SR) * env(i, n, 0.05, 0.3) for i in range(n)]
    return out


def gen_win():
    """大调琶音上扬 C-E-G-C(高八度) 三角波感"""
    seq = [(523, 0.1), (659, 0.1), (784, 0.1), (1047, 0.28)]
    out = []
    for f, d in seq:
        n = int(SR * d)
        out += [
            (0.5 * sine(f, i / SR) + 0.25 * sine(f * 2, i / SR)) * env(i, n, 0.02, 0.5)
            for i in range(n)
        ]
    return out


def gen_lose():
    """下行两音 小调叹息"""
    seq = [(392, 0.18), (311, 0.38)]
    out = []
    for f, d in seq:
        n = int(SR * d)
        out += [
            (0.5 * sine(f, i / SR) + 0.15 * sine(f / 2, i / SR)) * env(i, n, 0.02, 0.6)
            for i in range(n)
        ]
    return out


def gen_vs():
    """对撞冲击: 低频扫频 + 白噪声衰减"""
    n = int(SR * 0.22)
    out = []
    seed = 12345
    for i in range(n):
        t = i / SR
        f = 500 * math.exp(-t * 9) + 60
        seed = (seed * 1103515245 + 12345) % (2**31)
        noise = ((seed / 2**31) - 0.5) * 0.7 * math.exp(-t * 14)
        out.append((0.6 * sine(f, t) + noise) * env(i, n, 0.005, 0.4))
    return out


if __name__ == "__main__":
    print("generating sfx ->", os.path.abspath(OUT))
    write_wav("sfx_click.wav", gen_click())
    write_wav("sfx_coin.wav", gen_coin())
    write_wav("sfx_place.wav", gen_place())
    write_wav("sfx_go.wav", gen_go())
    write_wav("sfx_win.wav", gen_win())
    write_wav("sfx_lose.wav", gen_lose())
    write_wav("sfx_vs.wav", gen_vs())
    print("done")
