"""Render Arma-style map tiles from the data the game server exports (fn_map / fn_mapDetail).

Tile scheme: zoom 0..MAX_ZOOM, 256 px tiles, 2**z tiles per side covering the whole world square,
tile y=0 at the north edge. Tiles that are entirely sea are not written; the server answers them
with one shared sea tile.
"""

import hashlib
import json
import math
import os
import shutil
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw

RENDER_VERSION = "2"
MAX_ZOOM = 6
TILE = 256
SS = 2  # supersampling factor

# Arma map palette
SEA = np.array([166, 196, 222], np.float32)
SEA_EDGE = (110, 150, 190, 255)
LAND = np.array([233, 228, 210], np.float32)
FOREST = np.array([170, 196, 128], np.float32)
SURFACE_TINTS = [  # (keywords in the surface name, colour)
    (("beach", "sand"), (237, 226, 190)),
    (("rock", "stony", "stone", "cliff"), (214, 208, 196)),
    (("concrete", "asphalt", "pavement", "runway"), (220, 216, 208)),
    (("forest",), (220, 226, 196)),
    (("field", "farm", "crop"), (232, 226, 196)),
    (("marsh", "swamp"), (214, 226, 210)),
]
CONTOUR_MINOR = (168, 140, 100)
CONTOUR_MAJOR = (150, 118, 80)
GRID = (60, 60, 60)

ROAD_STYLES = {  # type: (fill, outline, min width px at 1x, min zoom)
    "MAIN ROAD": ((236, 168, 70), (130, 84, 30), 2.2, 0),
    "ROAD": ((250, 246, 232), (120, 104, 80), 1.6, 2),
    "TRACK": ((168, 132, 92), None, 1.1, 3),
    "TRAIL": ((150, 120, 86), None, 0.8, 4),
}
BUILDING_COLORS = {
    0: (88, 88, 88), 1: (60, 60, 60), 2: (92, 104, 72), 3: (140, 92, 44),
    4: (156, 60, 60), 5: (70, 70, 70), 6: (138, 133, 128),
}

# Set in each worker by _init
_W = {}


def data_version(terrain, detail):
    h = hashlib.sha1(RENDER_VERSION.encode())
    for row in terrain["rows"]:
        h.update(row.encode())
    h.update(json.dumps(detail, sort_keys=True).encode())
    return h.hexdigest()[:12]


def _decode_terrain(terrain):
    n = terrain["grid"]
    raw = np.frombuffer(bytes.fromhex("".join(terrain["rows"])), np.uint8).reshape(n, n).astype(np.float32)
    h = np.where(raw == 0, -8.0, (raw - 1) * 1.5)  # sea gets a small negative depth for a clean coastline
    return h  # [row south->north, col west->east]


def _surface_colors(detail):
    legend = detail["surfaceLegend"]
    palette = {}
    for code, name in legend.items():
        low = name.lower()
        color = LAND
        for keys, tint in SURFACE_TINTS:
            if any(k in low for k in keys):
                color = np.array(tint, np.float32)
                break
        palette[code] = color
    n = detail["surfaceGrid"]
    grid = np.empty((n, n, 3), np.float32)
    for r, row in enumerate(detail["surfaceRows"]):
        grid[r] = np.array([palette.get(ch, LAND) for ch in row], np.float32)
    return grid


def _decode_trees(detail):
    n = detail["treeGrid"]
    return np.frombuffer(bytes.fromhex("".join(detail["treeRows"])), np.uint8).reshape(n, n).astype(np.float32)


def _buckets(items, key_xy, size, cell=1000):
    """Spatial index: (cx, cy) -> [items] for quick per-tile lookup."""
    out = {}
    for it in items:
        for x, y in key_xy(it):
            k = (int(x // cell), int(y // cell))
            out.setdefault(k, set()).add(id(it))
    lookup = {id(it): it for it in items}
    return {k: [lookup[i] for i in v] for k, v in out.items()}, cell


def _init(terrain, detail):
    size = float(terrain["size"])
    _W["size"] = size
    _W["height"] = _decode_terrain(terrain)
    # Relief shading computed on the height grid itself, then interpolated per pixel (smooth).
    step = size / _W["height"].shape[0]
    gy_, gx_ = np.gradient(np.maximum(_W["height"], 0), step)  # rows run south->north
    _W["shade"] = np.clip(1.0 + (-gx_ - gy_) * 0.35, 0.86, 1.06).astype(np.float32)
    _W["surface"] = _surface_colors(detail)
    _W["trees"] = _decode_trees(detail)
    roads = [tuple(r) for r in detail["roads"]]
    buildings = [tuple(b) for b in detail["buildings"]]
    _W["roads"], _W["cell"] = _buckets(roads, lambda r: ((r[2], r[3]), (r[4], r[5])), size)
    _W["buildings"], _ = _buckets(buildings, lambda b: ((b[0], b[1]),), size)


def _sample(grid, gx, gy):
    """Bilinear sample of a [rows south->north, cols] grid at fractional cell coords (centre-based)."""
    n_r, n_c = grid.shape[:2]
    gx = np.clip(gx, 0, n_c - 1.001)
    gy = np.clip(gy, 0, n_r - 1.001)
    x0 = np.floor(gx).astype(np.int32)
    y0 = np.floor(gy).astype(np.int32)
    fx = gx - x0
    fy = gy - y0
    if grid.ndim == 3:
        fx = fx[..., None]
        fy = fy[..., None]
    a = grid[y0, x0]
    b = grid[y0, x0 + 1]
    c = grid[y0 + 1, x0]
    d = grid[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def _render(job):
    z, tx, ty, out_dir = job
    size = _W["size"]
    n_tiles = 2 ** z
    tile_m = size / n_tiles
    px = TILE * SS
    m = tile_m / px  # metres per supersampled pixel
    x0 = tx * tile_m
    y_top = size - ty * tile_m

    xs = x0 + (np.arange(px) + 0.5) * m
    ys = y_top - (np.arange(px) + 0.5) * m
    X, Y = np.meshgrid(xs, ys)

    hgrid = _W["height"]
    step = size / hgrid.shape[0]
    H = _sample(hgrid, X / step - 0.5, Y / step - 0.5)
    land = H > 0

    # Quick exit for open sea with nothing on it.
    if not land.any():
        return None

    sgrid = _W["surface"]
    sstep = size / sgrid.shape[0]
    rgb = _sample(sgrid, X / sstep - 0.5, Y / sstep - 0.5)

    tgrid = _W["trees"]
    tstep = size / tgrid.shape[0]
    T = _sample(tgrid, X / tstep - 0.5, Y / tstep - 0.5)
    forest = np.clip((T - 4.0) / 30.0, 0, 0.8)[..., None]
    rgb = rgb * (1 - forest) + FOREST * forest

    # Very light relief so the terrain reads at low zoom; light from the north-west.
    shade = _sample(_W["shade"], X / step - 0.5, Y / step - 0.5)[..., None]
    rgb = rgb * shade

    rgb = np.where(land[..., None], rgb, SEA)

    # Contours: draw where the height band changes between neighbouring pixels.
    def edges(interval):
        band = np.floor(np.maximum(H, 0) / interval)
        e = np.zeros_like(land)
        e[:, :-1] |= band[:, :-1] != band[:, 1:]
        e[:-1, :] |= band[:-1, :] != band[1:, :]
        return e & land

    if z >= 3:
        minor = edges(10.0)
        rgb[minor] = rgb[minor] * 0.55 + np.array(CONTOUR_MINOR, np.float32) * 0.45
    if z >= 1:
        major = edges(50.0)
        rgb[major] = rgb[major] * 0.25 + np.array(CONTOUR_MAJOR, np.float32) * 0.75

    # 1 km grid, over land only so all-sea tiles (served as one shared image) stay consistent.
    if z >= 3:
        cols = np.nonzero(np.diff(np.floor(xs / 1000)) != 0)[0] + 1
        rows = np.nonzero(np.diff(np.floor(ys / 1000)) != 0)[0] + 1
        g = np.zeros_like(land)
        for c in cols:
            g[:, max(0, c - SS // 2):c + SS // 2] = True
        for r in rows:
            g[max(0, r - SS // 2):r + SS // 2, :] = True
        g &= land
        rgb[g] = rgb[g] * 0.82 + np.array(GRID, np.float32) * 0.18

    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(img, "RGBA")

    # Coastline
    coast = np.zeros_like(land)
    coast[:, :-1] |= land[:, :-1] != land[:, 1:]
    coast[:-1, :] |= land[:-1, :] != land[1:, :]
    ys_c, xs_c = np.nonzero(coast)
    if len(xs_c):
        arr = np.array(img)
        arr[ys_c, xs_c] = SEA_EDGE[:3]
        img = Image.fromarray(arr)
        draw = ImageDraw.Draw(img, "RGBA")

    def to_px(x, y):
        return ((x - x0) / m, (y_top - y) / m)

    cell = _W["cell"]
    pad = 60
    cx0, cx1 = int((x0 - pad) // cell), int((x0 + tile_m + pad) // cell)
    cy0, cy1 = int((y_top - tile_m - pad) // cell), int((y_top + pad) // cell)

    def nearby(index):
        seen = set()
        for cx in range(cx0, cx1 + 1):
            for cy in range(cy0, cy1 + 1):
                for it in index.get((cx, cy), ()):
                    if id(it) not in seen:
                        seen.add(id(it))
                        yield it

    # Buildings (z >= 4)
    if z >= 4:
        for bx, by, w, l, d, kind in nearby(_W["buildings"]):
            a = math.radians(d)
            ca, sa = math.cos(a), math.sin(a)
            corners = []
            for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                lx, ly = sx * w / 2, sy * l / 2
                # Arma direction: clockwise from north; model x is east, y is north
                wx = bx + lx * ca + ly * sa
                wy = by - lx * sa + ly * ca
                corners.append(to_px(wx, wy))
            draw.polygon(corners, fill=BUILDING_COLORS.get(int(kind), BUILDING_COLORS[0]) + (255,))

    # Roads: outlines first, then fills, so junctions merge cleanly.
    roads = [r for r in nearby(_W["roads"]) if r[0] in ROAD_STYLES and z >= ROAD_STYLES[r[0]][3]]
    order = ["TRAIL", "TRACK", "ROAD", "MAIN ROAD"]
    roads.sort(key=lambda r: order.index(r[0]))

    def width_px(r):
        fill, outline, min_w, _ = ROAD_STYLES[r[0]]
        return max(min_w * SS, float(r[1]) / m)

    for r in roads:
        fill, outline, _, _ = ROAD_STYLES[r[0]]
        if outline:
            w = width_px(r) + 2 * SS
            a, b = to_px(r[2], r[3]), to_px(r[4], r[5])
            draw.line([a, b], fill=outline + (255,), width=max(1, round(w)))
            for p in (a, b):
                draw.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=outline + (255,))
    for r in roads:
        fill, outline, _, _ = ROAD_STYLES[r[0]]
        w = width_px(r)
        a, b = to_px(r[2], r[3]), to_px(r[4], r[5])
        if r[0] == "TRAIL":
            # dashed
            length = math.hypot(b[0] - a[0], b[1] - a[1])
            if length > 0:
                dash = 6 * SS
                steps = max(1, int(length // dash))
                for i in range(0, steps, 2):
                    t0, t1 = i / steps, min(1, (i + 1) / steps)
                    draw.line([(a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0),
                               (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)],
                              fill=fill + (255,), width=max(1, round(w)))
            continue
        draw.line([a, b], fill=fill + (255,), width=max(1, round(w)))
        for p in (a, b):
            draw.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=fill + (255,))

    img = img.resize((TILE, TILE), Image.LANCZOS)
    path = os.path.join(out_dir, str(z), str(tx), f"{ty}.png")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    return path


def render_all(terrain, detail, out_dir, processes=4, progress=None):
    """Render every tile into out_dir. Returns the number of land tiles written."""
    tmp = out_dir + ".partial"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    Image.new("RGB", (TILE, TILE), tuple(int(c) for c in SEA)).save(os.path.join(tmp, "sea.png"))
    jobs = [(z, tx, ty, tmp) for z in range(MAX_ZOOM + 1) for tx in range(2 ** z) for ty in range(2 ** z)]
    written = 0
    with Pool(processes, initializer=_init, initargs=(terrain, detail)) as pool:
        for i, path in enumerate(pool.imap_unordered(_render, jobs, chunksize=8), 1):
            if path:
                written += 1
            if progress and i % 50 == 0:
                progress(i / len(jobs))
    with open(os.path.join(tmp, "done.json"), "w") as f:
        json.dump({"tiles": written, "maxZoom": MAX_ZOOM}, f)
    shutil.rmtree(out_dir, ignore_errors=True)
    os.replace(tmp, out_dir)
    if progress:
        progress(1.0)
    return written


def main():
    """python3 tiles.py terrain.json detail.json out_dir [processes] -- writes out_dir.progress"""
    import sys

    terrain_path, detail_path, out_dir = sys.argv[1:4]
    processes = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    with open(terrain_path) as f:
        terrain = json.load(f)
    with open(detail_path) as f:
        detail = json.load(f)
    progress_path = out_dir + ".progress"

    def progress(p):
        with open(progress_path, "w") as f:
            f.write(f"{p:.3f}")

    n = render_all(terrain, detail, out_dir, processes=processes, progress=progress)
    try:
        os.remove(progress_path)
    except FileNotFoundError:
        pass
    print(f"rendered {n} land tiles into {out_dir}", flush=True)


if __name__ == "__main__":
    main()
