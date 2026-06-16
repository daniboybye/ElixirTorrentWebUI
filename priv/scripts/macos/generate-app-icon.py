#!/usr/bin/env python3
"""Generate ElixirTorrent icons (CLI only — no Icon Composer GUI required)."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
MACOS = ROOT / "priv" / "macos"
STATIC = ROOT / "priv" / "static"
IMAGES = STATIC / "images"
ICONSET = MACOS / "AppIcon.iconset"
ICNS = MACOS / "AppIcon.icns"
ICON_BUNDLE = MACOS / "AppIcon.icon"
ICON_ASSETS = ICON_BUNDLE / "Assets"

SIZE = 1024
PURPLE = (94, 45, 145)
PURPLE_RGBA = (*PURPLE, 255)
LETTER_TARGET_WIDTH_RATIO = 0.64


def letter_target_width_ratio(size: int) -> float:
    if size <= 24:
        return 0.48
    if size <= 48:
        return 0.52
    if size <= 128:
        return 0.58
    return LETTER_TARGET_WIDTH_RATIO


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Black.ttf",
        "/Library/Fonts/Arial Black.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def letter_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    target_width = size * letter_target_width_ratio(size)
    min_font = max(6, int(size * 0.35))
    font_size = max(min_font, int(700 * size / SIZE))
    probe = ImageDraw.Draw(Image.new("RGBA", (size, size)))

    for _ in range(24):
        font = load_font(font_size)
        bbox = probe.textbbox((0, 0), "T", font=font)
        width = bbox[2] - bbox[0]
        if width <= 0:
            break
        if abs(width - target_width) < size * 0.02:
            break
        font_size = max(min_font, int(font_size * (target_width / width)))

    return load_font(font_size)


def draw_letter(draw: ImageDraw.ImageDraw, size: int) -> None:
    font = letter_font(size)
    cx = cy = size / 2
    # Slight upward nudge for optical centering at larger sizes only.
    if size > 48:
        cy -= size * 0.02
    draw.text((cx, cy), "T", font=font, fill=(255, 255, 255, 255), anchor="mm")


def render_icon_bitmap(size: int) -> Image.Image:
    """App icon: Arial Black T on purple background."""
    img = Image.new("RGBA", (size, size), PURPLE_RGBA)
    draw = ImageDraw.Draw(img)
    draw_letter(draw, size)
    return img


def render_icon(size: int) -> Image.Image:
    if size <= 48:
        scale = 4 if size <= 16 else 2
        return render_icon_bitmap(size * scale).resize(
            (size, size),
            Image.Resampling.LANCZOS,
        )
    return render_icon_bitmap(size)


def extended_srgb(color: tuple[int, ...]) -> str:
    channels = [f"{channel / 255:.5f}" for channel in color[:3]]
    alpha = 1.0 if len(color) < 4 else color[3] / 255
    channels.append(f"{alpha:.5f}")
    return "extended-srgb:" + ",".join(channels)


def write_iconset() -> None:
    if ICONSET.exists():
        for child in ICONSET.iterdir():
            child.unlink()
    else:
        ICONSET.mkdir(parents=True)

    mapping = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for name, dim in mapping.items():
        render_icon(dim).save(ICONSET / name)


def build_icns() -> None:
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)


def write_icon_bundle() -> None:
    """Emit AppIcon.icon for macOS 26 Liquid Glass (full purple + T bitmap)."""
    if ICON_BUNDLE.exists():
        for child in ICON_BUNDLE.rglob("*"):
            if child.is_file():
                child.unlink()
    else:
        ICON_BUNDLE.mkdir(parents=True)

    ICON_ASSETS.mkdir(parents=True, exist_ok=True)
    render_icon(SIZE).save(ICON_ASSETS / "icon.png")

    purple = extended_srgb(PURPLE_RGBA)
    icon_json = {
        "fill": {"automatic-gradient": purple},
        "fill-specializations": [
            {
                "appearance": "dark",
                "value": {"automatic-gradient": purple},
            },
            {
                "appearance": "tinted",
                "value": {"automatic-gradient": purple},
            },
        ],
        "groups": [
            {
                "layers": [
                    {
                        "blend-mode": "normal",
                        "glass": True,
                        "image-name": "icon.png",
                        "name": "icon",
                        "position": {
                            "scale": 1,
                            "translation-in-points": [0, 0],
                        },
                    }
                ],
                "shadow": {"kind": "neutral", "opacity": 0.35},
                "translucency": {"enabled": True, "value": 0.25},
            }
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared",
        },
    }

    (ICON_BUNDLE / "icon.json").write_text(
        json.dumps(icon_json, indent=2) + "\n",
        encoding="utf-8",
    )


def write_web_assets() -> None:
    IMAGES.mkdir(parents=True, exist_ok=True)

    render_icon(SIZE).save(IMAGES / "app-icon.png")
    render_icon(180).save(IMAGES / "app-icon-180.png")
    render_icon(32).save(IMAGES / "app-icon-32.png")

    favicon_sizes = [16, 32, 48]
    favicon_images = [render_icon(dim) for dim in favicon_sizes]
    favicon_images[0].save(
        STATIC / "favicon.ico",
        format="ICO",
        sizes=[(dim, dim) for dim in favicon_sizes],
    )


def compile_liquid_glass() -> bool:
    script = ROOT / "priv" / "scripts" / "macos" / "build-liquid-glass-icon.sh"
    if not script.exists():
        return False

    result = subprocess.run([str(script)], check=False)
    return result.returncode == 0


def main() -> int:
    render_icon(SIZE).save(MACOS / "AppIcon-1024.png")
    write_iconset()
    build_icns()
    write_icon_bundle()
    write_web_assets()
    print(f"Generated {ICNS}")
    print(f"Generated {ICON_BUNDLE} (Liquid Glass)")
    print(f"Generated {IMAGES / 'app-icon.png'}")
    print(f"Generated {STATIC / 'favicon.ico'}")

    if compile_liquid_glass():
        print(f"Generated {MACOS / 'Assets.car'} (Liquid Glass)")
    else:
        print("Skipped Liquid Glass compile (run priv/scripts/macos/build-liquid-glass-icon.sh manually)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
