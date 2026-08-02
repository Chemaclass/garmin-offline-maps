"""Interactive harness for the map, in a browser.

The Connect IQ simulator is the intended way to drive the app end to end. When
it is unavailable -- it segfaults on some macOS versions, on Garmin's own sample
apps as well as this one -- there is otherwise no way to *use* the map without
flashing a watch.

This serves `preview.render` over HTTP and drives it with the same interaction
model as `MapView`/`MapDelegate`: drag blits the existing image at an offset and
only re-renders on release, taps hit zoom targets, and the camera is the same
lat/lon/zoom/heading/night state `Camera.mc` holds.

What it does test: the pack, the block/tile decode, the projection, draw order,
the palette, and the renderer's segment budgets -- everything the Python mirror
covers, which is everything except Monkey C execution and device memory.

What it does not test: whether the watch has the heap for the off-screen buffer,
and how long a render actually takes on the hardware. Those need a real device.

    python3 -m mappack.serve            # then open http://127.0.0.1:8765
"""

import argparse
import io
import json
import math
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import geom
from .preview import MapIndexFile, add_pack_arguments, render

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>Offline Maps -- virtual watch</title>
<style>
 :root { color-scheme: dark; }
 body { margin:0; background:#141414; color:#ddd;
        font:14px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
        display:flex; gap:28px; padding:28px; flex-wrap:wrap; }
 #bezel { width:466px; height:466px; border-radius:50%; background:#000;
          border:6px solid #2a2a2a; box-shadow:0 0 0 2px #000,0 14px 40px #0009;
          overflow:hidden; position:relative; flex:none; touch-action:none;
          cursor:grab; }
 #bezel.dragging { cursor:grabbing; }
 #map { position:absolute; left:0; top:0; width:454px; height:454px;
        image-rendering:pixelated; user-select:none; -webkit-user-drag:none; }
 #panel { min-width:280px; max-width:360px; }
 h1 { font-size:15px; margin:0 0 4px; letter-spacing:.02em; }
 .sub { color:#888; margin:0 0 18px; font-size:12px; }
 fieldset { border:1px solid #333; border-radius:8px; margin:0 0 14px; padding:12px 14px; }
 legend { color:#999; font-size:11px; text-transform:uppercase; letter-spacing:.09em; padding:0 4px; }
 button { background:#242424; color:#eee; border:1px solid #3a3a3a; border-radius:6px;
          padding:6px 12px; font:inherit; cursor:pointer; margin:0 6px 6px 0; }
 button:hover { background:#303030; }
 button[aria-pressed="true"] { background:#2d4a63; border-color:#3f6a8e; }
 table { width:100%; border-collapse:collapse; font-size:12px; }
 td { padding:2px 0; }
 td:last-child { text-align:right; color:#aaa; font-variant-numeric:tabular-nums; }
 .warn { color:#e8a33d; }
 .ok { color:#6fbf73; }
 input[type=range] { width:100%; }
 code { background:#222; padding:1px 5px; border-radius:4px; font-size:12px; }
</style>
<div id="bezel"><img id="map" alt="map"></div>
<div id="panel">
  <h1 id="packname">&nbsp;</h1>
  <p class="sub" id="attribution">&nbsp;</p>

  <fieldset><legend>Zoom</legend>
    <button id="zoomout">&minus;</button>
    <button id="zoomin">+</button>
    <button id="recentre">Recentre</button>
  </fieldset>

  <fieldset><legend>View</legend>
    <button id="theme" aria-pressed="false">Day theme</button>
    <button id="headingup" aria-pressed="false">Heading&#8209;up</button>
    <div id="headingrow" hidden>
      <label>Heading <span id="headingval">0&deg;</span></label>
      <input type="range" id="heading" min="0" max="359" value="0">
    </div>
  </fieldset>

  <fieldset><legend>Render stats</legend>
    <table>
      <tr><td>Zoom</td><td id="s-zoom"></td></tr>
      <tr><td>Centre</td><td id="s-centre"></td></tr>
      <tr><td>Tiles drawn</td><td id="s-tiles"></td></tr>
      <tr><td>Segments</td><td id="s-seg"></td></tr>
      <tr><td>Blocks missing</td><td id="s-missing"></td></tr>
      <tr><td>Segment budget</td><td id="s-trunc"></td></tr>
      <tr><td>Render time</td><td id="s-ms"></td></tr>
      <tr><td>In pack</td><td id="s-inpack"></td></tr>
    </table>
  </fieldset>

  <p class="sub">Drag the face to pan &mdash; the image slides while you drag and
  re-renders on release, exactly as <code>MapView</code> blits the buffer at an
  offset. Segment budgets are the real ones, scraped from
  <code>MapRenderer.mc</code>.</p>
</div>
<script>
const cam = { lat:0, lon:0, zoom:0, heading:0, night:true, headingUp:false };
let meta = null, dragging = false, sx = 0, sy = 0, dx = 0, dy = 0, busy = false;

const $ = id => document.getElementById(id);
const img = $('map'), bezel = $('bezel');

async function boot() {
  meta = await (await fetch('/meta')).json();
  cam.lat = meta.center_lat; cam.lon = meta.center_lon; cam.zoom = meta.default_zoom;
  $('packname').textContent = meta.pack_name;
  $('attribution').textContent = meta.attribution;
  draw();
}

function query() {
  return new URLSearchParams({
    lat: cam.lat, lon: cam.lon, zoom: cam.zoom,
    heading: cam.headingUp ? cam.heading : 0,
    day: cam.night ? '0' : '1'
  }).toString();
}

async function draw() {
  if (busy) return;
  busy = true;
  const t0 = performance.now();
  const res = await fetch('/render?' + query());
  const stats = JSON.parse(res.headers.get('X-Stats'));
  const blob = await res.blob();
  img.src = URL.createObjectURL(blob);
  img.style.transform = '';
  const ms = Math.round(performance.now() - t0);
  $('s-zoom').textContent = cam.zoom + (meta ? ' (data z' + stats.data_zoom + ')' : '');
  $('s-centre').textContent = cam.lat.toFixed(5) + ', ' + cam.lon.toFixed(5);
  $('s-tiles').textContent = stats.tiles;
  $('s-seg').textContent = stats.segments;
  $('s-missing').textContent = stats.missing;
  const tr = $('s-trunc');
  tr.textContent = stats.truncated ? 'TRUNCATED' : 'within budget';
  tr.className = stats.truncated ? 'warn' : 'ok';
  $('s-ms').textContent = ms + ' ms (desktop)';
  const inp = $('s-inpack');
  inp.textContent = stats.in_pack ? 'yes' : 'outside pack';
  inp.className = stats.in_pack ? 'ok' : 'warn';
  busy = false;
}

bezel.addEventListener('pointerdown', e => {
  dragging = true; bezel.classList.add('dragging');
  bezel.setPointerCapture(e.pointerId);
  sx = e.clientX; sy = e.clientY; dx = 0; dy = 0;
});
bezel.addEventListener('pointermove', e => {
  if (!dragging) return;
  dx = e.clientX - sx; dy = e.clientY - sy;
  img.style.transform = `translate(${dx}px, ${dy}px)`;
});
bezel.addEventListener('pointerup', async e => {
  if (!dragging) return;
  dragging = false; bezel.classList.remove('dragging');
  if (!dx && !dy) return;
  const p = new URLSearchParams({
    lat: cam.lat, lon: cam.lon, zoom: cam.zoom, dx, dy,
    heading: cam.headingUp ? cam.heading : 0
  });
  const moved = await (await fetch('/pan?' + p)).json();
  cam.lat = moved.lat; cam.lon = moved.lon;
  draw();
});

$('zoomin').onclick  = () => { if (cam.zoom < meta.max_zoom) { cam.zoom++; draw(); } };
$('zoomout').onclick = () => { if (cam.zoom > meta.min_zoom) { cam.zoom--; draw(); } };
$('recentre').onclick = () => { cam.lat = meta.center_lat; cam.lon = meta.center_lon; draw(); };
$('theme').onclick = e => {
  cam.night = !cam.night;
  e.target.setAttribute('aria-pressed', String(!cam.night));
  e.target.textContent = cam.night ? 'Day theme' : 'Night theme';
  draw();
};
$('headingup').onclick = e => {
  cam.headingUp = !cam.headingUp;
  e.target.setAttribute('aria-pressed', String(cam.headingUp));
  $('headingrow').hidden = !cam.headingUp;
  draw();
};
$('heading').oninput = e => {
  cam.heading = Number(e.target.value);
  $('headingval').textContent = cam.heading + '\\u00b0';
  if (cam.headingUp) draw();
};
boot();
</script>
"""


class _Handler(BaseHTTPRequestHandler):
    """One renderer per request; the camera lives in the browser."""

    paths = None  # set by serve()

    def log_message(self, fmt, *args):  # quieter than the default
        pass

    def do_GET(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/":
                return self._send(200, "text/html; charset=utf-8", PAGE.encode())
            if url.path == "/meta":
                return self._json(self._meta())
            if url.path == "/pan":
                return self._json(self._pan(query))
            if url.path == "/render":
                return self._render(query)
            self._send(404, "text/plain", b"not found")
        except Exception as exc:  # a broken request should not kill the server
            self._send(500, "text/plain", str(exc).encode())

    # -- endpoints --------------------------------------------------------

    def _meta(self):
        index = MapIndexFile(self.paths["index"])
        # Mirrors Camera.defaultZoom: the middle data zoom, clamped.
        mid = index.data_zooms[len(index.data_zooms) // 2]
        mid = max(index.min_zoom, min(index.max_zoom, mid))
        return {
            "pack_name": index.pack_name,
            "attribution": index.attribution,
            "center_lat": index.center_lat,
            "center_lon": index.center_lon,
            "min_zoom": index.min_zoom,
            "max_zoom": index.max_zoom,
            "data_zooms": index.data_zooms,
            "default_zoom": mid,
        }

    def _pan(self, query):
        """Mirror of Camera.panPixels: content follows the finger."""
        lat = float(query["lat"])
        lon = float(query["lon"])
        zoom = int(query["zoom"])
        screen_dx = float(query.get("dx", 0))
        screen_dy = float(query.get("dy", 0))
        theta = math.radians(float(query.get("heading", 0)))
        world_dx, world_dy = screen_dx, screen_dy
        if theta:
            c, s = math.cos(theta), math.sin(theta)
            world_dx = screen_dx * c - screen_dy * s
            world_dy = screen_dx * s + screen_dy * c
        x = geom.lon_to_world_x(lon, zoom) - world_dx
        y = geom.lat_to_world_y(lat, zoom) - world_dy
        lon = geom.world_x_to_lon(x, zoom)
        lat = geom.world_y_to_lat(y, zoom)
        lat = max(-85.0, min(85.0, lat))
        if lon > 180.0:
            lon -= 360.0
        if lon < -180.0:
            lon += 360.0
        return {"lat": lat, "lon": lon}

    def _render(self, query):
        lat = float(query["lat"])
        lon = float(query["lon"])
        zoom = int(query["zoom"])
        heading = math.radians(float(query.get("heading", 0)))
        night = query.get("day", "0") != "1"

        image, stats = render(
            self.paths["pack"], self.paths["index"], self.paths["palette"],
            size=self.paths["size"], zoom=zoom, lat=lat, lon=lon,
            heading=heading, night=night)

        index = MapIndexFile(self.paths["index"])
        stats = dict(stats)
        stats["data_zoom"] = index.data_zoom_for(zoom)
        stats["in_pack"] = index.contains(lat, lon)

        buffer = io.BytesIO()
        image.save(buffer, "PNG")
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Stats", json.dumps(stats))
        self.end_headers()
        self.wfile.write(buffer.getvalue())

    # -- plumbing ---------------------------------------------------------

    def _json(self, payload):
        self._send(200, "application/json", json.dumps(payload).encode())

    def _send(self, code, content_type, body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="mappack.serve",
        description="Drive the map interactively in a browser.")
    add_pack_arguments(parser)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args(argv)

    try:
        import PIL  # noqa: F401
    except ImportError:
        parser.error("the interactive demo needs Pillow: pip install pillow")

    _Handler.paths = {
        "pack": args.pack, "index": args.index,
        "palette": args.palette, "size": args.size,
    }
    server = ThreadingHTTPServer((args.host, args.port), _Handler)
    # Read the index before serving, and say so plainly if it will not parse.
    #
    # `MapIndexFile` now raises on a missing constant rather than quietly
    # assuming everything is inside the pack, which is right: a wrong answer
    # about where the map is costs more than a stopped server. But an
    # unhandled traceback at startup reads like a bug in the tool rather than
    # a bad file, and the file is generated, so the fix is to regenerate it.
    try:
        index = MapIndexFile(args.index)
    except (OSError, ValueError) as exc:
        parser.error("could not read %s: %s\nRegenerate it with `make demo`."
                     % (args.index, exc))
    print("serving %s on http://%s:%d  (Ctrl-C to stop)"
          % (index.pack_name, args.host, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
