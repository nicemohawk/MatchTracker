#!/usr/bin/env python3
"""Draws the app icon: a penalty area on knitted cloth, once per kit.

    python3 scripts/draw-icons.py

Writes iOS App/AppIcon.icon and its alternates, and Watch App/AppIcon.icon. The colors are the presets
in MatchTrackerKit's KitColors.swift; keep the two in step.
"""
import json
import math
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
# Preset: cloth and yarn as lightness, chroma, hue.
KITS = {
    "green": ((0.318, 0.054, 166), (0.79, 0.15, 145)), "royal": ((0.36, 0.145, 264), (0.79, 0.11, 255)),
    "navy": ((0.27, 0.075, 262), (0.79, 0.09, 235)), "sky": ((0.43, 0.085, 235), (0.83, 0.10, 228)),
    "purple": ((0.34, 0.135, 300), (0.79, 0.12, 303)), "claret": ((0.31, 0.105, 12), (0.80, 0.10, 235)),
    "red": ((0.42, 0.165, 27), (0.79, 0.13, 25)), "orange": ((0.45, 0.125, 45), (0.80, 0.14, 60)),
    "gold": ((0.235, 0.015, 90), (0.84, 0.15, 90)), "black": ((0.245, 0.004, 260), (0.82, 0.008, 260)),
}
SIZE, COLUMNS = 1064, 11
WIDTH = SIZE / COLUMNS
RISE = WIDTH * 0.8
ROWS = math.ceil(SIZE / RISE)
LINES = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><g fill="none" stroke="#FFFCF5" stroke-width="46" '
         'stroke-linejoin="round"><path d="M172 -60V560H852V-60M342 -60V236H682V-60M352 560A190 190 0 0 0 672 560"/></g></svg>')


def rgb(lightness, chroma, hue):
    while True:
        a, b = chroma * math.cos(math.radians(hue)), chroma * math.sin(math.radians(hue))
        l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3
        m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3
        s = (lightness - 0.0894841775 * a - 1.2914855480 * b) ** 3
        linear = (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        if all(-0.0005 <= v <= 1.0005 for v in linear):
            break
        chroma *= 0.95
    clamped = [min(max(v, 0), 1) for v in linear]
    return [v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055 for v in clamped]


def hexed(color):
    return "#" + "".join(f"{round(v * 255):02X}" for v in color)


def heat(u, v):
    total = 0
    for x, y, along, across, strength, angle in ((0.60, 0.36, 0.22, 0.17, 1.05, -0.7), (0.36, 0.62, 0.22, 0.17, 0.95, -0.7),
                                                 (0.22, 0.84, 0.20, 0.14, 0.45, -0.7)):
        dx, dy = u - x, v - y
        p, q = dx * math.cos(angle) + dy * math.sin(angle), -dx * math.sin(angle) + dy * math.cos(angle)
        total += strength * math.exp(-(p * p / along ** 2 + q * q / across ** 2))
    return total


def stitch(column, row):
    x, y, h = -20 + column * WIDTH, -20 + row * RISE, WIDTH * 1.02
    points = [(0.06, 0), (0.36, 0), (0.5, 0.36), (0.64, 0), (0.94, 0)]
    corners = [(x + WIDTH * a, y + h * b) for a, b in points]
    corners += [(x + WIDTH * 0.94, y + h * 0.34), (x + WIDTH * 0.5, y + h), (x + WIDTH * 0.06, y + h * 0.34)]
    return "M" + "L".join(f"{a:.1f} {b:.1f}" for a, b in corners) + "Z"


def draw(folder, cloth, yarn):
    layers = [[], [], [], []]
    for row in range(ROWS):
        for column in range(COLUMNS):
            level = heat((column + 0.5) / COLUMNS, (row + 0.5) * RISE / SIZE)
            layers[3 if level > 0.9 else 2 if level > 0.58 else 1 if level > 0.26 else 0].append(stitch(column, row))
    lightness, chroma, hue = cloth
    strong = max(yarn[1], chroma * 0.8)
    colors = [rgb(lightness + 0.04, chroma, hue), rgb(max(lightness + 0.2, 0.58), strong, yarn[2]),
              rgb(0.82, yarn[1] * 1.15, yarn[2]), (1.0, 0.965, 0.878)]
    os.makedirs(os.path.join(folder, "Assets"), exist_ok=True)
    for index, (paths, color) in enumerate(zip(layers, colors), 1):
        with open(os.path.join(folder, "Assets", f"heat{index}.svg"), "w") as file:
            file.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><path d="' + "".join(paths)
                       + f'" fill="{hexed(color)}"/></svg>')
    with open(os.path.join(folder, "Assets", "lines.svg"), "w") as file:
        file.write(LINES)

    def fill(offset):
        return "extended-srgb:" + ",".join(f"{v:.5f}" for v in rgb(max(lightness + offset, 0.08), chroma * 0.8, hue)) + ",1.00000"

    flat = {"kind": "none", "opacity": 0.0}
    icon = {"fill": {"linear-gradient": [fill(-0.03), fill(-0.13)]},
            "groups": [{"layers": [{"image-name": "lines.svg", "name": "Lines"}], "shadow": {"kind": "neutral", "opacity": 0.5},
                        "translucency": {"enabled": False, "value": 0.5}, "specular": True},
                       {"layers": [{"image-name": f"heat{n}.svg", "name": f"Heat {n}", "glass": False} for n in (4, 3, 2, 1)],
                        "shadow": flat, "translucency": {"enabled": False, "value": 0.5}, "specular": False}],
            "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}}
    with open(os.path.join(folder, "icon.json"), "w") as file:
        json.dump(icon, file, indent=2)


for name, (cloth, yarn) in KITS.items():
    draw(os.path.join(ROOT, "iOS App", "AppIcon.icon" if name == "green" else f"AppIcon-{name}.icon"), cloth, yarn)
draw(os.path.join(ROOT, "Watch App", "AppIcon.icon"), *KITS["green"])
