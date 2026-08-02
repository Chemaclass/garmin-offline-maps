"""Web Mercator projection, simplification and clipping.

All "world pixel" coordinates use the standard slippy-map convention:
``world = 256 * 2**zoom`` pixels across, origin top-left at (-180, +85.0511).
"""

from __future__ import annotations

import math
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

Point = Tuple[float, float]

#: A (min_x, min_y, max_x, max_y) box, in whichever space its points are in --
#: the same dual life `Point` leads, and `osmread` explains.
#:
#: In degrees that reads west, south, east, north. In world pixels min_y is
#: *north*, because the y axis points down. Nothing here converts between the
#: two; `pack.clamp_bbox` is the one place that does, and swapping the two y
#: components is exactly what it has to remember to do.
BBox = Tuple[float, float, float, float]

TILE_SIZE = 256
MAX_LAT = 85.05112878


def lon_to_world_x(lon: float, zoom: int) -> float:
    return (lon + 180.0) / 360.0 * (TILE_SIZE << zoom)


def lat_to_world_y(lat: float, zoom: int) -> float:
    lat = max(-MAX_LAT, min(MAX_LAT, lat))
    s = math.sin(math.radians(lat))
    y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)
    return y * (TILE_SIZE << zoom)


def world_x_to_lon(x: float, zoom: int) -> float:
    return x / (TILE_SIZE << zoom) * 360.0 - 180.0


def world_y_to_lat(y: float, zoom: int) -> float:
    n = math.pi - 2.0 * math.pi * y / (TILE_SIZE << zoom)
    return math.degrees(math.atan(math.sinh(n)))


def meters_per_pixel(lat: float, zoom: int) -> float:
    return 156543.03392804097 * math.cos(math.radians(lat)) / (1 << zoom)


def project(points: Sequence[Point], zoom: int) -> List[Point]:
    return [(lon_to_world_x(lon, zoom), lat_to_world_y(lat, zoom)) for lon, lat in points]


# --------------------------------------------------------------------------
# Simplification
# --------------------------------------------------------------------------


def _perp_sq(p: Point, a: Point, b: Point) -> float:
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if dx == 0.0 and dy == 0.0:
        return (px - ax) ** 2 + (py - ay) ** 2
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    qx, qy = ax + t * dx, ay + t * dy
    return (px - qx) ** 2 + (py - qy) ** 2


def simplify(points: Sequence[Point], tolerance: float) -> List[Point]:
    """Iterative Douglas-Peucker (no recursion limit surprises on long ways)."""
    n = len(points)
    if n < 3 or tolerance <= 0:
        return list(points)
    tol_sq = tolerance * tolerance
    keep = [False] * n
    keep[0] = keep[n - 1] = True
    stack = [(0, n - 1)]
    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        max_d = -1.0
        index = first
        a, b = points[first], points[last]
        for i in range(first + 1, last):
            d = _perp_sq(points[i], a, b)
            if d > max_d:
                max_d = d
                index = i
        if max_d > tol_sq:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def polyline_length(points: Sequence[Point]) -> float:
    total = 0.0
    for i in range(1, len(points)):
        total += math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1])
    return total


def bbox(points: Iterable[Point]) -> BBox:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


# --------------------------------------------------------------------------
# Clipping
# --------------------------------------------------------------------------

_INSIDE, _LEFT, _RIGHT, _BOTTOM, _TOP = 0, 1, 2, 4, 8


def _outcode(x: float, y: float, xmin: float, ymin: float, xmax: float, ymax: float) -> int:
    code = _INSIDE
    if x < xmin:
        code |= _LEFT
    elif x > xmax:
        code |= _RIGHT
    if y < ymin:
        code |= _TOP
    elif y > ymax:
        code |= _BOTTOM
    return code


def clip_polyline(
    points: Sequence[Point], xmin: float, ymin: float, xmax: float, ymax: float
) -> List[List[Point]]:
    """Cohen-Sutherland per segment, stitching consecutive kept segments."""
    out: List[List[Point]] = []
    current: List[Point] = []
    for i in range(len(points) - 1):
        seg = _clip_segment(points[i], points[i + 1], xmin, ymin, xmax, ymax)
        if seg is None:
            if len(current) > 1:
                out.append(current)
            current = []
            continue
        a, b = seg
        if not current:
            current = [a, b]
        elif current[-1] == a:
            current.append(b)
        else:
            if len(current) > 1:
                out.append(current)
            current = [a, b]
    if len(current) > 1:
        out.append(current)
    return out


def _clip_segment(p0: Point, p1: Point, xmin: float, ymin: float,
                  xmax: float, ymax: float) -> Optional[Tuple[Point, Point]]:
    x0, y0 = p0
    x1, y1 = p1
    code0 = _outcode(x0, y0, xmin, ymin, xmax, ymax)
    code1 = _outcode(x1, y1, xmin, ymin, xmax, ymax)
    for _ in range(8):
        if not (code0 | code1):
            return (x0, y0), (x1, y1)
        if code0 & code1:
            return None
        code = code0 or code1
        if code & _BOTTOM:
            x = x0 + (x1 - x0) * (ymax - y0) / (y1 - y0)
            y = ymax
        elif code & _TOP:
            x = x0 + (x1 - x0) * (ymin - y0) / (y1 - y0)
            y = ymin
        elif code & _RIGHT:
            y = y0 + (y1 - y0) * (xmax - x0) / (x1 - x0)
            x = xmax
        else:
            y = y0 + (y1 - y0) * (xmin - x0) / (x1 - x0)
            x = xmin
        if code == code0:
            x0, y0 = x, y
            code0 = _outcode(x0, y0, xmin, ymin, xmax, ymax)
        else:
            x1, y1 = x, y
            code1 = _outcode(x1, y1, xmin, ymin, xmax, ymax)
    return None


def clip_polygon(
    points: Sequence[Point], xmin: float, ymin: float, xmax: float, ymax: float
) -> List[Point]:
    """Sutherland-Hodgman against an axis-aligned rectangle."""
    def clip_edge(poly: List[Point], inside: Callable[[Point], bool],
                  intersect: Callable[[Point, Point], Point]) -> List[Point]:
        if not poly:
            return []
        result: List[Point] = []
        prev = poly[-1]
        prev_in = inside(prev)
        for cur in poly:
            cur_in = inside(cur)
            if cur_in:
                if not prev_in:
                    result.append(intersect(prev, cur))
                result.append(cur)
            elif prev_in:
                result.append(intersect(prev, cur))
            prev, prev_in = cur, cur_in
        return result

    def ix_x(a: Point, b: Point, x: float) -> Point:
        t = (x - a[0]) / (b[0] - a[0]) if b[0] != a[0] else 0.0
        return (x, a[1] + t * (b[1] - a[1]))

    def ix_y(a: Point, b: Point, y: float) -> Point:
        t = (y - a[1]) / (b[1] - a[1]) if b[1] != a[1] else 0.0
        return (a[0] + t * (b[0] - a[0]), y)

    poly = list(points)
    if len(poly) > 1 and poly[0] == poly[-1]:
        poly = poly[:-1]
    poly = clip_edge(poly, lambda p: p[0] >= xmin, lambda a, b: ix_x(a, b, xmin))
    poly = clip_edge(poly, lambda p: p[0] <= xmax, lambda a, b: ix_x(a, b, xmax))
    poly = clip_edge(poly, lambda p: p[1] >= ymin, lambda a, b: ix_y(a, b, ymin))
    poly = clip_edge(poly, lambda p: p[1] <= ymax, lambda a, b: ix_y(a, b, ymax))
    return poly


def polygon_area(points: Sequence[Point]) -> float:
    """Absolute shoelace area."""
    n = len(points)
    if n < 3:
        return 0.0
    total = 0.0
    for i in range(n):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % n]
        total += x1 * y2 - x2 * y1
    return abs(total) * 0.5
