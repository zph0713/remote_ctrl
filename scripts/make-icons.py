#!/usr/bin/env python3
"""Generate MiVoice's app icon and menu-bar template.

The generated files are committed so the macOS build does not need Pillow.
Run from the repo root: python3 scripts/make-icons.py
"""
from __future__ import annotations

import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
PACKAGING = ROOT / "Packaging"
S = 2048


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_app_icon() -> Image.Image:
    # Deep navy-to-teal rounded square.
    background = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    top = (10, 24, 38)
    bottom = (18, 58, 74)
    draw = ImageDraw.Draw(background)
    for y in range(S):
        color = lerp(top, bottom, y / (S - 1))
        draw.line([(0, y), (S, y)], fill=color + (255,))

    # Soft highlight in the upper-left.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    gdraw.ellipse(
        [-S * 0.25, -S * 0.35, S * 0.7, S * 0.55],
        fill=(80, 190, 190, 38),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(S // 18))
    background = Image.alpha_composite(background, glow)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, S - 1, S - 1],
        radius=int(S * 0.225),
        fill=255,
    )
    rounded = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rounded.paste(background, (0, 0), mask)

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Microphone body.
    body = [S * 0.355, S * 0.225, S * 0.535, S * 0.565]
    d.rounded_rectangle(body, radius=int(S * 0.09), fill=(246, 252, 252, 255))
    # Subtle grille lines inside the capsule.
    for index in range(3):
        y = S * (0.295 + index * 0.038)
        d.rounded_rectangle(
            [S * 0.385, y, S * 0.505, y + S * 0.009],
            radius=int(S * 0.004),
            fill=(16, 52, 64, 60),
        )

    # U-shaped stand and base.
    stand_box = [S * 0.295, S * 0.355, S * 0.595, S * 0.675]
    d.arc(stand_box, start=0, end=180, fill=(246, 252, 252, 255), width=int(S * 0.036))
    d.line(
        [(S * 0.445, S * 0.675), (S * 0.445, S * 0.765)],
        fill=(246, 252, 252, 255),
        width=int(S * 0.036),
    )
    d.rounded_rectangle(
        [S * 0.345, S * 0.755, S * 0.545, S * 0.795],
        radius=int(S * 0.02),
        fill=(246, 252, 252, 255),
    )

    # Three signal arcs to the right of the microphone.
    center = (S * 0.575, S * 0.39)
    for index, radius in enumerate((0.15, 0.225, 0.30)):
        alpha = (215, 150, 90)[index]
        width = int(S * (0.028 - index * 0.003))
        box = [
            center[0] - S * radius,
            center[1] - S * radius,
            center[0] + S * radius,
            center[1] + S * radius,
        ]
        d.arc(box, start=-58, end=58, fill=(246, 252, 252, alpha), width=width)

    # Small amber status dot on the mic base.
    d.ellipse(
        [S * 0.515, S * 0.735, S * 0.555, S * 0.775],
        fill=(255, 178, 96, 255),
    )

    rounded = Image.alpha_composite(rounded, layer)
    return rounded.resize((1024, 1024), Image.LANCZOS)


def make_menu_icon(size: int) -> Image.Image:
    scale = 8
    s = size * scale
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(image)
    black = (0, 0, 0, 255)

    # Mic capsule.
    d.rounded_rectangle(
        [s * 0.19, s * 0.10, s * 0.47, s * 0.54],
        radius=int(s * 0.14),
        fill=black,
    )
    # Stand.
    d.arc(
        [s * 0.10, s * 0.30, s * 0.56, s * 0.76],
        start=0,
        end=180,
        fill=black,
        width=max(2, int(s * 0.075)),
    )
    d.line(
        [(s * 0.33, s * 0.76), (s * 0.33, s * 0.88)],
        fill=black,
        width=max(2, int(s * 0.075)),
    )
    d.rounded_rectangle(
        [s * 0.19, s * 0.86, s * 0.47, s * 0.94],
        radius=max(1, int(s * 0.03)),
        fill=black,
    )
    # Two signal arcs.
    for radius, width_scale in ((0.24, 0.07), (0.38, 0.055)):
        box = [
            s * 0.50 - s * radius,
            s * 0.36 - s * radius,
            s * 0.50 + s * radius,
            s * 0.36 + s * radius,
        ]
        d.arc(
            box,
            start=-55,
            end=55,
            fill=black,
            width=max(2, int(s * width_scale)),
        )

    return image.resize((size, size), Image.LANCZOS)


def write_icns(icon: Image.Image) -> None:
    entries = [
        (b"ic11", 32),
        (b"ic12", 64),
        (b"ic07", 128),
        (b"ic13", 256),
        (b"ic08", 256),
        (b"ic14", 512),
        (b"ic09", 512),
        (b"ic10", 1024),
    ]
    chunks: list[bytes] = []
    for kind, size in entries:
        import io

        buffer = io.BytesIO()
        icon.resize((size, size), Image.LANCZOS).save(buffer, "PNG")
        payload = buffer.getvalue()
        chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    (PACKAGING / "AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main() -> None:
    PACKAGING.mkdir(exist_ok=True)
    icon = make_app_icon()
    icon.save(PACKAGING / "AppIcon-1024.png")
    write_icns(icon)
    make_menu_icon(18).save(PACKAGING / "MenuBarIcon.png")
    make_menu_icon(36).save(PACKAGING / "MenuBarIcon@2x.png")
    print("wrote Packaging/AppIcon.icns, AppIcon-1024.png, MenuBarIcon.png/@2x.png")


if __name__ == "__main__":
    main()
