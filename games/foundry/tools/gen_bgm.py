# 程序化生成 8-bit BGM 循环（纯标准库，无依赖）
# 输出: assets/audio/bgm_loop.wav (22050Hz 16bit mono, 无缝循环)
# 编曲: A 小调 8 小节 110BPM, Am-F-C-G 进行
#   - 低音: 方波根音 (每拍)
#   - 琶音: 三角波分解和弦 (八分音符)
#   - 旋律: 第二遍起进入的方波主旋律
import math
import struct
import wave
import os

SR = 22050
BPM = 110.0
BEAT = 60.0 / BPM  # 一拍秒数
BARS = 8
TOTAL = int(SR * BEAT * 4 * BARS)
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")

# 音名 -> 频率
NOTE = {}
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def _build_notes():
    for octv in range(1, 7):
        for i, n in enumerate(NAMES):
            midi = 12 * (octv + 1) + i
            NOTE["%s%d" % (n, octv)] = 440.0 * 2 ** ((midi - 69) / 12.0)


_build_notes()

# 和弦进行 (每 2 小节一个和弦): Am F C G
PROG = [
    ("A2", ["A3", "C4", "E4"]),
    ("F2", ["F3", "A3", "C4"]),
    ("C3", ["C4", "E4", "G4"]),  # C 用 E4 起更亮
    ("G2", ["G3", "B3", "D4"]),
]

# 主旋律 (八分音符, None=休止), 覆盖 8 小节 = 64 个八分音符
MELODY = [
    "E4", "A4", "C5", "B4", "A4", None, "E4", None,
    "F4", "A4", "C5", "A4", "F4", None, "C4", None,
    "E4", "G4", "C5", "G4", "E4", None, "G4", None,
    "D4", "G4", "B4", "G4", "D5", "B4", "G4", None,
] * 2


def square(f, t, duty=0.5):
    ph = (f * t) % 1.0
    return 1.0 if ph < duty else -1.0


def tri(f, t):
    ph = (f * t) % 1.0
    return 4.0 * abs(ph - 0.5) - 1.0


def decay(i, n, k=3.0):
    """指数衰减包络"""
    return math.exp(-k * i / n)


buf = [0.0] * TOTAL

# --- 低音: 每拍一个方波根音 ---
step = int(SR * BEAT)
for bar in range(BARS):
    root = PROG[bar // 2][0]
    f = NOTE[root]
    for beat in range(4):
        n = int(SR * BEAT * 0.92)
        off = (bar * 4 + beat) * step
        for i in range(n):
            if off + i < TOTAL:
                v = 0.16 * square(f, i / SR, 0.25) * decay(i, n, 2.0)
                buf[off + i] += v

# --- 琶音: 八分音符三角波 ---
step8 = int(SR * BEAT * 0.5)
for bar in range(BARS):
    chord = PROG[bar // 2][1]
    for e in range(8):
        note = chord[e % 3] if e % 4 != 3 else chord[(e + 1) % 3]
        f = NOTE[note]
        n = step8
        off = (bar * 8 + e) * step8
        for i in range(n):
            if off + i < TOTAL:
                v = 0.10 * tri(f, i / SR) * decay(i, n, 2.5)
                buf[off + i] += v

# --- 旋律: 方波 + 轻微混响感 (延迟一次叠加) ---
for e in range(64):
    note = MELODY[e]
    if note is None:
        continue
    f = NOTE[note]
    n = int(SR * BEAT * 0.9)
    off = e * step8
    for i in range(n):
        if off + i < TOTAL:
            v = 0.13 * square(f, i / SR, 0.3) * decay(i, n, 2.0)
            buf[off + i] += v
            if off + i + int(SR * 0.08) < TOTAL:
                buf[off + i + int(SR * 0.08)] += v * 0.25

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "bgm_loop.wav")
with wave.open(path, "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(b"".join(
        struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in buf
    ))
peak = max(abs(s) for s in buf)
print("bgm_loop.wav: %.2fs peak=%.2f" % (TOTAL / SR, peak))
