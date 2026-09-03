#!/usr/bin/env python3
"""Remove a connected near-white backdrop while preserving the subject."""

import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter


def main() -> None:
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    image = Image.open(source).convert("RGB")
    width, height = image.size
    pixels = list(image.get_flattened_data())
    candidate = bytearray(width * height)
    for index, (red, green, blue) in enumerate(pixels):
        is_neutral = max(red, green, blue) - min(red, green, blue) < 42
        candidate[index] = int(min(red, green, blue) > 205 and is_neutral)

    background = bytearray(width * height)
    queue: deque[int] = deque()
    for x in range(width):
        for y in (0, height - 1):
            _enqueue(y * width + x, candidate, background, queue)
    for y in range(height):
        for x in (0, width - 1):
            _enqueue(y * width + x, candidate, background, queue)

    while queue:
        index = queue.popleft()
        x = index % width
        y = index // width
        neighbors = []
        if x > 0:
            neighbors.append(index - 1)
        if x < width - 1:
            neighbors.append(index + 1)
        if y > 0:
            neighbors.append(index - width)
        if y < height - 1:
            neighbors.append(index + width)
        for neighbor in neighbors:
            _enqueue(neighbor, candidate, background, queue)

    mask = Image.frombytes("L", (width, height), bytes(255 * value for value in background))
    alpha = Image.eval(mask.filter(ImageFilter.GaussianBlur(1.4)), lambda value: 255 - value)
    output = image.convert("RGBA")
    output.putalpha(alpha)
    output = output.crop(output.getbbox())
    output.thumbnail((640, 640), Image.Resampling.LANCZOS)
    output.save(destination, optimize=True)


def _enqueue(
    index: int, candidate: bytearray, background: bytearray, queue: deque[int]
) -> None:
    if candidate[index] and not background[index]:
        background[index] = 1
        queue.append(index)


if __name__ == "__main__":
    main()
