import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! The map screen.
//!
//! The expensive part (decoding tiles and drawing thousands of segments) runs
//! once into an off-screen BufferedBitmap whenever the camera changes. Every
//! frame after that just blits the buffer and paints the small overlay on top,
//! which is what keeps dragging smooth: while your finger is down we simply
//! blit the same buffer at an offset and re-render when you let go.
class MapView extends WatchUi.View {

    //! Fraction of the screen radius at which the round buttons sit.
    const BUTTON_ORBIT = 0.345;
    const BUTTON_RADIUS = 0.095;

    hidden var _camera;
    hidden var _store;
    hidden var _renderer;
    hidden var _tracker;

    hidden var _bufferRef;
    hidden var _useBuffer;
    hidden var _dirty;

    hidden var _dragX;
    hidden var _dragY;
    hidden var _dragging;

    hidden var _width;
    hidden var _height;
    hidden var _renderMs;
    hidden var _showDebug;

    function initialize(camera, store, tracker) {
        View.initialize();
        _camera = camera;
        _store = store;
        _tracker = tracker;
        _renderer = new MapRenderer();
        _bufferRef = null;
        _useBuffer = true;
        _dirty = true;
        _dragX = 0;
        _dragY = 0;
        _dragging = false;
        _renderMs = 0;
        _showDebug = false;
    }

    function camera() { return _camera; }
    function invalidate() { _dirty = true; }
    function toggleDebug() { _showDebug = !_showDebug; WatchUi.requestUpdate(); }

    function onLayout(dc) {
        _width = dc.getWidth();
        _height = dc.getHeight();
        createBuffer();
    }

    function onShow() {
        _dirty = true;
    }

    //! Drop the buffer and rebuild it -- needed when the palette changes.
    function rebuild() {
        _bufferRef = null;
        createBuffer();
        _dirty = true;
    }

    hidden function createBuffer() {
        if (_width == null || _height == null) { return; }
        try {
            // No `:palette`. A paletted buffer refuses every primitive
            // MapRenderer draws -- drawLine above pen width 1 and fillPolygon
            // are both anti-aliased, and the API rejects those outright:
            // "Anti aliased primitives cannot be drawn to a paletted buffer".
            // The cost is 8 bpp instead of 4; see docs/RENDERING.md.
            _bufferRef = Graphics.createBufferedBitmap({
                :width => _width,
                :height => _height
            });
            _useBuffer = (_bufferRef != null);
        } catch (ex) {
            // Not enough heap for an off-screen buffer: fall back to drawing
            // straight to the screen. Slower and it flickers while panning,
            // but it works rather than crashing.
            System.println("MapView: buffered bitmap unavailable, drawing direct");
            _bufferRef = null;
            _useBuffer = false;
        }
    }

    //! Graphics.OutOfGraphicsMemoryException is thrown by the reference
    //! accessors, not by createBufferedBitmap, so the try has to be here.
    hidden function bufferBitmap() {
        if (_bufferRef == null) { return null; }
        try {
            var bitmap = _bufferRef.get();
            if (bitmap == null) {
                // The system reclaimed it while we were in the background.
                createBuffer();
                if (_bufferRef == null) { return null; }
                bitmap = _bufferRef.get();
                _dirty = true;
            }
            return bitmap;
        } catch (ex) {
            System.println("MapView: graphics pool exhausted, drawing direct");
            _bufferRef = null;
            return null;
        }
    }

    function onUpdate(dc) {
        if (_width == null) {
            _width = dc.getWidth();
            _height = dc.getHeight();
            createBuffer();
        }

        var colours = Palette.colours(_camera.night);
        var background = colours[Palette.SLOT_BACKGROUND];

        if (_useBuffer) {
            var bitmap = bufferBitmap();
            if (bitmap != null) {
                try {
                    if (_dirty) {
                        var started = System.getTimer();
                        _renderer.render(bitmap.getDc(), _camera, _store);
                        _renderMs = System.getTimer() - started;
                        _dirty = false;
                    }
                    dc.setColor(background, background);
                    dc.clear();
                    dc.drawBitmap(_dragX, _dragY, bitmap);
                } catch (ex) {
                    // Name the exception: this catch covers the whole render,
                    // so swallowing it silently hides real drawing bugs behind
                    // what looks like a memory fallback.
                    System.println("MapView: buffered draw failed, drawing direct: "
                        + ex.getErrorMessage());
                    _bufferRef = null;
                    _useBuffer = false;
                    _dirty = true;
                }
            } else {
                _useBuffer = false;
            }
        }

        if (!_useBuffer) {
            _renderer.render(dc, _camera, _store);
            _dirty = false;
        }

        drawOverlay(dc, colours);
    }

    // ---- panning --------------------------------------------------------

    function beginDrag() {
        _dragging = true;
        _dragX = 0;
        _dragY = 0;
    }

    function dragBy(dx, dy) {
        _dragX = dx;
        _dragY = dy;
        WatchUi.requestUpdate();
    }

    function endDrag() {
        // Clear the offset before the guard. A STOP without a matching START --
        // which happens when a drag begins over a view we then pop -- would
        // otherwise leave the buffer blitted at a stale offset forever.
        var dx = _dragX;
        var dy = _dragY;
        _dragX = 0;
        _dragY = 0;

        if (_dragging) {
            _dragging = false;
            if (dx != 0 || dy != 0) {
                _camera.follow = false;
                _camera.panPixels(dx, dy);
                _dirty = true;
            }
        }
        WatchUi.requestUpdate();
    }

    //! Persist here rather than on every zoom press: Storage writes are
    //! expensive and need transient heap well beyond the payload size.
    function onHide() {
        Settings.save(_camera);
    }

    // ---- hit testing ----------------------------------------------------

    function buttonRadius() { return (_width * BUTTON_RADIUS).toNumber(); }

    //! [x, y] centre of a button, placed on a circle so it stays on-screen on
    //! round displays.
    //!
    //! Typed because every caller indexes it; see the note above `drawOverlay`.
    function buttonCentre(degrees) as Array<Number> {
        var orbit = _width * BUTTON_ORBIT;
        var radians = degrees * Math.PI / 180.0;
        return [(_width / 2.0 + orbit * Math.cos(radians)).toNumber(),
                (_height / 2.0 + orbit * Math.sin(radians)).toNumber()];
    }

    function hitTest(x, y) {
        var radius = buttonRadius() + 6;
        var targets = [[:zoomIn, -38], [:zoomOut, 38], [:follow, 142]];
        for (var i = 0; i < targets.size(); i += 1) {
            var centre = buttonCentre(targets[i][1]);
            var dx = x - centre[0];
            var dy = y - centre[1];
            if (dx * dx + dy * dy <= radius * radius) {
                return targets[i][0];
            }
        }
        return null;
    }

    // ---- overlay --------------------------------------------------------

    //! The overlay helpers all index `colours`, so `colours` is annotated the
    //! whole way down from `Palette.colours()`. A parameter defaults to
    //! `Object?`, which the checker cannot index, and an unannotated hop
    //! anywhere in the chain puts the warning back.
    hidden function drawOverlay(dc, colours as Array<Number>) {
        drawPositionMarker(dc, colours);
        drawButtons(dc, colours);
        drawScaleBar(dc, colours);
        drawStatus(dc, colours);
        if (_showDebug) {
            drawDebug(dc, colours);
        }
    }

    hidden function drawPositionMarker(dc, colours as Array<Number>) {
        if (!_tracker.hasFix()) { return; }

        var zoom = _camera.zoom;
        var dx = (Mercator.lonToWorldX(_tracker.lon(), zoom)
                  - Mercator.lonToWorldX(_camera.lon, zoom)).toFloat();
        var dy = (Mercator.latToWorldY(_tracker.lat(), zoom)
                  - Mercator.latToWorldY(_camera.lat, zoom)).toFloat();

        var theta = _camera.rotation();
        var sx;
        var sy;
        if (theta != 0.0) {
            var c = Math.cos(theta);
            var s = Math.sin(theta);
            sx = _width / 2.0 + dx * c + dy * s;
            sy = _height / 2.0 - dx * s + dy * c;
        } else {
            sx = _width / 2.0 + dx;
            sy = _height / 2.0 + dy;
        }
        if (sx < -20 || sy < -20 || sx > _width + 20 || sy > _height + 20) { return; }

        var x = sx.toNumber();
        var y = sy.toNumber();
        var r = (_width * 0.024).toNumber();

        dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, r + 2);
        dc.setColor(colours[Palette.SLOT_POSITION], Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, r);

        // Heading wedge, drawn relative to the map's own rotation.
        if (_tracker.hasHeading()) {
            var bearing = _tracker.heading() - theta;
            var tip = r * 3.2;
            var side = r * 1.5;
            var points = [
                rotatePoint(x, y, 0, -tip, bearing),
                rotatePoint(x, y, -side, side * 0.5, bearing),
                rotatePoint(x, y, side, side * 0.5, bearing)
            ];
            dc.fillPolygon(points);
        }
    }

    hidden function rotatePoint(cx, cy, dx, dy, angle) {
        var c = Math.cos(angle);
        var s = Math.sin(angle);
        return [(cx + dx * c - dy * s).toNumber(), (cy + dx * s + dy * c).toNumber()];
    }

    hidden function drawButtons(dc, colours as Array<Number>) {
        var r = buttonRadius();
        drawButton(dc, colours, buttonCentre(-38), r, "+", false);
        drawButton(dc, colours, buttonCentre(38), r, "-", false);
        drawButton(dc, colours, buttonCentre(142), r, null, _camera.follow);
    }

    hidden function drawButton(dc, colours as Array<Number>, centre as Array<Number>,
                               r, glyph, active) {
        dc.setColor(colours[Palette.SLOT_PANEL], Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centre[0], centre[1], r);
        var ink = active ? colours[Palette.SLOT_ACCENT] : colours[Palette.SLOT_TEXT];
        dc.setColor(ink, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(centre[0], centre[1], r);

        if (glyph != null) {
            dc.drawText(centre[0], centre[1], Graphics.FONT_MEDIUM, glyph,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            // Crosshair = "centre on me".
            var arm = (r * 0.55).toNumber();
            dc.drawLine(centre[0] - arm, centre[1], centre[0] + arm, centre[1]);
            dc.drawLine(centre[0], centre[1] - arm, centre[0], centre[1] + arm);
            dc.fillCircle(centre[0], centre[1], (r * 0.22).toNumber());
        }
    }

    hidden function drawScaleBar(dc, colours as Array<Number>) {
        var metresPerPixel = _camera.metresPerPixel();
        var target = _width * 0.28;
        var metres = niceDistance(metresPerPixel * target);
        var pixels = (metres / metresPerPixel).toNumber();
        if (pixels < 8 || pixels > _width) { return; }

        var y = (_height * 0.855).toNumber();
        var x = ((_width - pixels) / 2).toNumber();

        dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(x, y, x + pixels, y);
        dc.drawLine(x, y - 4, x, y + 4);
        dc.drawLine(x + pixels, y - 4, x + pixels, y + 4);
        dc.drawText(_width / 2, y + 4, Graphics.FONT_XTINY, formatDistance(metres),
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    hidden function niceDistance(raw) {
        var steps = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000];
        for (var i = 0; i < steps.size(); i += 1) {
            if (raw <= steps[i]) { return steps[i]; }
        }
        return steps[steps.size() - 1];
    }

    hidden function formatDistance(metres) {
        if (metres >= 1000) {
            return (metres / 1000).format("%d") + " km";
        }
        return metres.format("%d") + " m";
    }

    hidden function drawStatus(dc, colours as Array<Number>) {
        if (_camera.headingUp) {
            // North arrow, so you can still tell which way is up.
            var cx = (_width * 0.5).toNumber();
            var cy = (_height * 0.115).toNumber();
            var theta = -_camera.rotation();
            dc.setColor(colours[Palette.SLOT_ACCENT], Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon([
                rotatePoint(cx, cy, 0, -11, theta),
                rotatePoint(cx, cy, -7, 8, theta),
                rotatePoint(cx, cy, 7, 8, theta)
            ]);
        }

        if (_renderer.tilesDrawn() == 0 && !_dragging) {
            dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
            dc.drawText(_width / 2, _height / 2 - 12, Graphics.FONT_SMALL,
                        WatchUi.loadResource(Rez.Strings.NoDataHere),
                        Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
            dc.drawText(_width / 2, _height / 2 + 16, Graphics.FONT_XTINY,
                        MapIndex.PACK_NAME, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    hidden function drawDebug(dc, colours as Array<Number>) {
        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        var lines = [
            "z" + _camera.zoom + " -> data z" + MapIndex.dataZoomFor(_camera.zoom),
            _renderer.tilesDrawn() + " tiles  " + _renderer.segmentsDrawn() + " seg",
            _renderMs + " ms  cache " + (_store.cachedBytes() / 1024) + " KB",
            _camera.lat.format("%.4f") + ", " + _camera.lon.format("%.4f")
        ];
        for (var i = 0; i < lines.size(); i += 1) {
            dc.drawText(_width / 2, (_height * 0.30 + i * 18).toNumber(), Graphics.FONT_XTINY,
                        lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
