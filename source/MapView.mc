import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The map screen.
//!
//! The expensive part (decoding tiles and drawing thousands of segments) runs
//! once into an off-screen BufferedBitmap whenever the camera changes. Every
//! frame after that just blits the buffer and paints the small overlay on top,
//! which is what keeps dragging smooth: while your finger is down we simply
//! blit the same buffer at an offset and re-render when you let go.
class MapView extends WatchUi.View {

    //! Gap before the frame that carries on filling the map in.
    //!
    //! `TileStore` decodes one block a frame, so a screenful arrives over
    //! several. Asking for those with `WatchUi.requestUpdate` from inside
    //! `onUpdate` does not reliably produce one: measured, the map stopped
    //! after three frames with blocks still outstanding. A timer does produce
    //! one. Short enough that the map fills in while you look at it.
    const FILL_GAP_MS = 40;

    //! How far the buffer may be blitted off-centre before it is redrawn.
    //!
    //! Following you does not need a redraw. The buffer holds the map drawn
    //! about one centre, and blitting it a few pixels over shows the same map
    //! about a different one, exactly: a world point lands at
    //! `(P - C1) + half + (C1 - C2)`, which is `(P - C2) + half`. That is what
    //! dragging already does with `_dragX`/`_dragY` while a finger is down.
    //!
    //! The cost is an unpainted band along the trailing edge, at most this
    //! wide, and it is the same artefact a drag shows. On a 390 px round screen
    //! 24 px of it sits largely outside the bezel.
    //!
    //! The gain runs both ways. Following used to demand a restart, which the
    //! renderer answers over many frames, so it was rationed to moves worth
    //! paying for: 17 m at a time, in jumps. Now a fix slides the map at once
    //! and a redraw waits until the offset has built up, which at zoom 16 is
    //! about 60 m. Smoother *and* fewer redraws.
    const FOLLOW_REDRAW_PX = 24;

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
    //! A rotation that arrived mid-render and is waiting for it to finish.
    //! See `redrawWhenIdle`.
    hidden var _rotationPending;

    hidden var _dragX;
    hidden var _dragY;
    hidden var _dragging;
    //! Pixels between where the buffer was drawn and where the camera now is.
    //! Added to the drag offset at blit time. See `FOLLOW_REDRAW_PX`.
    hidden var _followX;
    hidden var _followY;
    //! Pending timer for the next fill-in frame. See `FILL_GAP_MS`.
    hidden var _fillTimer;

    hidden var _width;
    hidden var _height;
    hidden var _renderMs;
    hidden var _showDebug;
    //! The diagnostic message this view has actually drawn. See `onShow`.
    hidden var _diagShown;

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
        _diagShown = null;
        _rotationPending = false;
        _followX = 0;
        _followY = 0;
        _fillTimer = null;
    }

    //! Ask for the next fill-in frame, through a timer. See `FILL_GAP_MS`.
    hidden function scheduleFill() {
        if (_fillTimer != null) { return; }
        _fillTimer = new Timer.Timer();
        _fillTimer.start(method(:onFillTimer), FILL_GAP_MS, false);
    }

    //! Annotated because `Timer.start` requires a `Method() as Void`.
    function onFillTimer() as Void {
        _fillTimer = null;
        WatchUi.requestUpdate();
    }

    //! Stop filling in. Called wherever the view leaves the screen, so a timer
    //! cannot outlive it.
    hidden function stopFill() {
        if (_fillTimer != null) {
            _fillTimer.stop();
            _fillTimer = null;
        }
    }

    //! The camera moved a little; slide the buffer instead of redrawing it.
    //!
    //! Takes a screen-pixel delta. Returns true when it absorbed the move, so
    //! the caller knows no redraw is needed. Once the accumulated offset passes
    //! `FOLLOW_REDRAW_PX` it gives up and asks for a real redraw, because the
    //! unpainted trailing band would start to show.
    //!
    //! Only for north-up. Under heading-up the buffer is drawn rotated, so a
    //! world delta is not a screen delta, and a turn of the wrist is going to
    //! force a redraw anyway.
    function shiftBy(dx, dy) {
        if (_camera.headingUp || !_useBuffer) { return false; }
        var nx = _followX + dx;
        var ny = _followY + dy;
        if (nx > FOLLOW_REDRAW_PX || nx < -FOLLOW_REDRAW_PX
                || ny > FOLLOW_REDRAW_PX || ny < -FOLLOW_REDRAW_PX) {
            return false;
        }
        _followX = nx;
        _followY = ny;
        return true;
    }

    //! Throw away the picture and draw it again from nothing.
    //!
    //! Named for what it costs. The map is built over many frames, areas before
    //! lines, and this restarts at the first of them: everything drawn so far
    //! goes. That is right for a view that actually moved (a zoom, a pan, a new
    //! pack) and wrong for anything that repeats, because a restart arriving
    //! faster than the map completes means it never completes. Twice this month
    //! that shipped as a map of water with no streets on it.
    //!
    //! If your caller fires on a timer, a sensor or a fix, you want
    //! `redrawWhenIdle` instead.
    function redrawFromScratch() {
        _dirty = true;
        // The buffer is about to be drawn about the current centre, so the
        // offset that was standing in for that is spent.
        _followX = 0;
        _followY = 0;
    }

    //! Redraw, but never at the cost of finishing the picture.
    //!
    //! For a change that is only worth showing once the map is drawn, which is
    //! what a turn of the wrist is. The passes run in order, areas then lines,
    //! and a restart throws away everything drawn so far and begins again at
    //! areas. A city needs many frames to get through both. So a restart
    //! arriving more often than the map can finish means the areas pass runs
    //! for ever and the lines pass never starts: water and parks on screen,
    //! and no streets at all.
    //!
    //! `pollHeading` fires on a five degree change, once a second, and an arm
    //! moves more than that just walking, so heading-up used to guarantee that
    //! outcome on a wrist. A simulator never sees it: nothing there turns.
    //!
    //! Deferring costs a stale rotation for the rest of the current render,
    //! which is a second or two of the map pointing where you were facing
    //! rather than where you are. Losing the streets costs the map.
    function redrawWhenIdle() {
        if (_renderer.complete()) {
            _dirty = true;
        } else {
            _rotationPending = true;
        }
    }

    //! Give the off-screen buffer back.
    //!
    //! It is the largest thing this app holds, roughly a byte per pixel of the
    //! screen, and it lives in the graphics pool rather than the heap. Dropping
    //! the reference on the way out means the next app to run is not waiting on
    //! a collector to notice. `onShow` takes a new one, so the view still works
    //! if it comes back.
    function release() {
        stopFill();
        _bufferRef = null;
        _useBuffer = false;
        _dirty = true;
    }
    function toggleDebug() { _showDebug = !_showDebug; WatchUi.requestUpdate(); }

    function onLayout(dc) {
        _width = dc.getWidth();
        _height = dc.getHeight();
        createBuffer();
    }

    function onShow() {
        _dirty = true;
        // Try the off-screen buffer again if we are drawing direct.
        //
        // Losing the buffer is survivable but permanent otherwise: the app
        // flickers while panning for the rest of the session even once memory
        // frees up. Coming back to the map is the natural moment to retry,
        // because whatever pushed us over (a menu, a download, another app's
        // graphics) has usually just gone away.
        if (!_useBuffer) {
            createBuffer();
        }
        // Clear the diagnostic, but only the one that has been on screen: a
        // failure the user has seen is done with, and keeping it forever makes
        // a transient fault look permanent.
        //
        // Clearing unconditionally threw away every failure recorded while the
        // map was *not* the top view, and this view is the only thing that
        // draws them. A download error is recorded by `CityDownloader` behind
        // the download screen, and this ran on the way back and erased it
        // before a single frame could show it. Same for anything `onStart`
        // records, which happens before the first `onShow`.
        if (_diagShown != null && _diagShown.equals(Diag.message())) {
            Diag.clear();
            _diagShown = null;
        }
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

    //! Guarded end to end.
    //!
    //! A throw anywhere in a View's onUpdate takes the app down, and after a
    //! city download that is exactly what a watch showed: black screen, Connect
    //! IQ error icon. Recording the failure and dropping back to the built-in
    //! map turns a dead app into a readable message.
    //!
    //! It does not cover the fault it was written for, and the next reader
    //! should not assume it does: a Float in a downloaded pack's metadata
    //! raises a `Lang.Error`, which no `catch` takes. Coercing the metadata in
    //! `Pack` is what fixed that. What is left here is what the renderer can
    //! genuinely throw, which is worth catching on its own account.
    function onUpdate(dc) {
        try {
            drawEverything(dc);
            // Keep leaving crumbs for as long as a downloaded map is on
            // screen, and stop only once we are back on the built-in one.
            //
            // Not "after the first successful frame": throttled loading means
            // the first frame *does* succeed, and the watchdog fires whenever a
            // frame runs long, which is just as easily the third one, mid-pan,
            // as the map fills in. Disarming early leaves that kill no crumb.
            //
            // The cost is one storage write per block actually decoded, and
            // blocks are only decoded on a cache miss. `onStop` clears the
            // crumb, so a clean exit leaves none and anything still there was
            // a kill.
            if (!Pack.isDownloaded()) { Diag.disarm(); }
        } catch (ex) {
            Diag.record("render", ex);
            // The pack that failed to draw must not be drawn again, or this
            // repeats every frame.
            Pack.use(null);
            _store.clear();
            _camera.resetToPack();
            _dirty = true;
            try {
                drawEverything(dc);
            } catch (fatal) {
                // The built-in map cannot draw either. Nothing left but a
                // blank screen with the reason on it.
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
                dc.clear();
                drawDiagnostic(dc, Palette.colours(true));
            }
        }
    }

    hidden function drawEverything(dc) {
        if (_width == null) {
            _width = dc.getWidth();
            _height = dc.getHeight();
            createBuffer();
        }

        var colours = Palette.colours(_camera.night);

        if (_useBuffer) {
            var bitmap = bufferBitmap();
            if (bitmap != null) {
                try {
                    if (_dirty || !_renderer.complete()) {
                        var started = System.getTimer();
                        // `_dirty` means the view moved, so start the picture
                        // again. Otherwise carry on adding to the one already
                        // in the buffer.
                        _renderer.render(bitmap.getDc(), _camera, _store, _dirty);
                        _renderMs = System.getTimer() - started;
                        _dirty = false;
                        // A rotation that arrived while this was drawing gets
                        // its restart now that there is a finished picture to
                        // replace. Deferred rather than dropped: dropping it
                        // would leave the map pointing the wrong way until
                        // something else happened to trigger a redraw.
                        if (_rotationPending && _renderer.complete()) {
                            _rotationPending = false;
                            _dirty = true;
                            WatchUi.requestUpdate();
                        }
                        // Keep asking until the whole view has been drawn.
                        //
                        // Each frame is deliberately short, and a city needs
                        // more drawing than fits in one, so the picture is built
                        // up over several. This used to stop as soon as a frame
                        // ran out of time, which is why a downloaded city drew
                        // its left half and nothing else. Progress is real
                        // between frames now, so asking again is not a spin: the
                        // renderer resumes where it stopped and eventually says
                        // it is done.
                        if (!_renderer.complete()) { scheduleFill(); }
                    }
                    Ui.clear(dc, colours);
                    dc.drawBitmap(_dragX + _followX, _dragY + _followY, bitmap);
                } catch (ex) {
                    // Deliberately wide -- the blit is as likely to run out of
                    // graphics memory as the render -- so a real drawing bug
                    // lands here wearing a memory fallback's clothes. That is
                    // not hypothetical: the paletted buffer threw on every
                    // frame and the app quietly direct-drew instead, and it
                    // took a simulator log to notice (docs/RENDERING.md).
                    // `Diag` puts the reason on the watch; println needs a
                    // cable, which is no use to whoever is wearing it.
                    Diag.record("draw", ex);
                    _bufferRef = null;
                    _useBuffer = false;
                    _dirty = true;
                }
            } else {
                _useBuffer = false;
            }
        }

        if (!_useBuffer) {
            // Always from scratch here, and never resumed. Without a buffer we
            // are drawing straight to a screen that is cleared for us each
            // frame, so there is nothing to accumulate into: a partial pass
            // would show as the map losing whatever it drew last time. This
            // path is the memory fallback and is already the degraded one.
            _renderer.render(dc, _camera, _store, true);
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
        stopFill();
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

    //! The last recorded failure, wrapped onto a panel at the bottom.
    //!
    //! Without this a caught exception is invisible: the map silently reverts
    //! to the built-in one and nobody can say why. Shown until the app is
    //! restarted, because a fault worth catching is worth reporting.
    //!
    //! Wrapped over four lines rather than held on one `FONT_XTINY` line, which
    //! clips away the part that names the fault -- and being read off the watch
    //! and repeated back is the whole reason it is on screen. A message
    //! reaching here has already cost the user a failed download; the map can
    //! spare the space.
    hidden function drawDiagnostic(dc, colours as Array<Number>) {
        var text = Diag.message();
        if (text == null) { return; }

        var font = Graphics.FONT_XTINY;
        var lineHeight = dc.getFontHeight(font);
        // 0.70 of the width, and sitting just past the middle of the screen.
        //
        // Both numbers are about the display being round. Near the bottom the
        // usable chord is far narrower than the screen: at 86% of the height on
        // a 454 px round face it is about 316 px, not the 408 that 90% of the
        // width suggests. Wrapping to that 408 produced a line clipped at
        // *both* ends, losing the word that names the failure.
        var lines = wrapText(dc, text, font, _width * 0.70);
        var top = (_height * 0.56).toNumber();

        // A panel behind it: red on a rendered map is not reliably legible, and
        // this text only appears when something is already wrong.
        dc.setColor(colours[Palette.SLOT_PANEL], colours[Palette.SLOT_PANEL]);
        dc.fillRectangle(0, top - 2, _width, lineHeight * lines.size() + 4);

        dc.setColor(colours[Palette.SLOT_MOTORWAY], Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < lines.size(); i += 1) {
            dc.drawText(_width / 2, top + i * lineHeight, font,
                        lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
        // Remembered so `onShow` can tell a failure the user has read from one
        // recorded while some other view was on top.
        _diagShown = text;
    }

    //! Greedy character wrap, capped at four lines.
    //!
    //! By character rather than by word on purpose: these messages are mostly
    //! unspaced ("render.block 14/4400/2686", "UnexpectedTypeError"), and a
    //! word wrapper would leave most of each line empty.
    //!
    //! Typed return because `drawDiagnostic` indexes the result; the literal
    //! below needs no cast of its own, the declared type carries it.
    hidden function wrapText(dc, text, font, maxWidth) as Array<String> {
        var lines = [];
        var start = 0;
        while (start < text.length() && lines.size() < 4) {
            var end = text.length();
            while (end > start + 1
                   && dc.getTextWidthInPixels(text.substring(start, end), font) > maxWidth) {
                end -= 1;
            }
            lines.add(text.substring(start, end));
            start = end;
        }
        return lines;
    }

    //! The overlay helpers all index `colours`, so it is annotated the whole
    //! way down from `Palette.colours()`. A parameter defaults to `Object?`,
    //! which the checker cannot index, and an unannotated hop anywhere in the
    //! chain puts the warning back.
    hidden function drawOverlay(dc, colours as Array<Number>) {
        drawDiagnostic(dc, colours);
        if (Onboarding.shouldShow()) {
            // The card and nothing else. It covers the button orbit, so the
            // usual chrome would only survive as slivers along its edges.
            Onboarding.draw(dc, colours, _width, _height);
            return;
        }
        drawWaypoints(dc, colours);
        drawPositionMarker(dc, colours);
        drawButtons(dc, colours);
        drawScaleBar(dc, colours);
        drawNearestPin(dc, colours);
        drawPositionStatus(dc, colours);
        drawStatus(dc, colours);
        if (_showDebug) {
            drawDebug(dc, colours);
        }
    }

    //! Pins, and the way back to the nearest one.
    //!
    //! Drawn in the overlay rather than into the map buffer, which is the whole
    //! reason this is cheap: dropping a pin repaints the chrome and leaves the
    //! rendered map alone, so it costs no restart. See
    //! `MapRenderer` on what a restart costs.
    hidden function drawWaypoints(dc, colours as Array<Number>) {
        var pins = Waypoints.all();
        if (pins.size() < 2) { return; }

        var zoom = _camera.zoom;
        var theta = _camera.rotation();
        var c = 1.0;
        var sn = 0.0;
        if (theta != 0.0) {
            c = Math.cos(theta);
            sn = Math.sin(theta);
        }
        var centreX = Mercator.lonToWorldX(_camera.lon, zoom);
        var centreY = Mercator.latToWorldY(_camera.lat, zoom);
        var r = (_width * 0.018).toNumber();

        for (var i = 0; i < pins.size() / 2; i += 1) {
            var dx = (Mercator.lonToWorldX(Waypoints.lonAt(pins, i), zoom)
                      - centreX).toFloat();
            var dy = (Mercator.latToWorldY(Waypoints.latAt(pins, i), zoom)
                      - centreY).toFloat();
            var sx;
            var sy;
            if (theta != 0.0) {
                sx = _width / 2.0 + dx * c + dy * sn;
                sy = _height / 2.0 - dx * sn + dy * c;
            } else {
                sx = _width / 2.0 + dx;
                sy = _height / 2.0 + dy;
            }
            if (sx < -10 || sy < -10 || sx > _width + 10 || sy > _height + 10) {
                continue;
            }
            // Outlined, like the position marker: a flat dot disappears into
            // whatever it lands on, and it lands on roads by definition.
            dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(sx.toNumber(), sy.toNumber(), r + 2);
            dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(sx.toNumber(), sy.toNumber(), r);
        }
    }

    //! How far and which way to the nearest pin, from where you are.
    //!
    //! Needs a fix: the distance is from *you*, not from the middle of the
    //! screen, and saying otherwise while panning around would be a lie in the
    //! one place the app is meant to be trustworthy.
    hidden function drawNearestPin(dc, colours as Array<Number>) {
        if (!_tracker.hasFix() || Waypoints.count() == 0) { return; }
        var pins = Waypoints.all();
        var i = Waypoints.nearest(_tracker.lat(), _tracker.lon());
        if (i < 0) { return; }

        var metres = Waypoints.distance(_tracker.lat(), _tracker.lon(),
                                        Waypoints.latAt(pins, i),
                                        Waypoints.lonAt(pins, i));
        var label = metres < 1000
            ? metres.format("%.0f") + " m"
            : (metres / 1000.0).format("%.1f") + " km";

        var bearingRad = Waypoints.bearing(_tracker.lat(), _tracker.lon(),
                                           Waypoints.latAt(pins, i),
                                           Waypoints.lonAt(pins, i));
        // Relative to the map's own rotation, so the arrow points at the pin on
        // screen rather than at a compass bearing the map is not drawn to.
        var screenBearing = bearingRad - _camera.rotation();

        var cx = _width / 2;
        var y = (_height * 0.80).toNumber();
        var size = _width * 0.022;
        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        var arrowX = cx - dc.getTextWidthInPixels(label, Graphics.FONT_XTINY) / 2
                     - size * 2;
        dc.fillPolygon([
            rotatePoint(arrowX, y, 0, -size, screenBearing),
            rotatePoint(arrowX, y, -size * 0.8, size * 0.7, screenBearing),
            rotatePoint(arrowX, y, size * 0.8, size * 0.7, screenBearing)
        ]);
        dc.drawText(cx, y - size * 1.6, Graphics.FONT_XTINY, label,
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Say why the position marker is not on screen.
    //!
    //! `drawPositionMarker` returns silently in both of these cases, and a
    //! missing dot is indistinguishable from a broken app: the first time this
    //! ran on a watch, the map was a demo pack of Madrid and the user was in
    //! Berlin, so the marker was culled 2300 km off-screen with nothing said.
    hidden function drawPositionStatus(dc, colours as Array<Number>) {
        var message = null;
        if (!_tracker.hasFix()) {
            message = WatchUi.loadResource(Rez.Strings.WaitingForGps) as String;
        } else if (!Camera.contains(_tracker.lat(), _tracker.lon())) {
            message = WatchUi.loadResource(Rez.Strings.OutsideMap) as String;
        } else {
            return;     // the marker itself is on screen, nothing to explain
        }

        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        dc.drawText(_width / 2, (_height * 0.72).toNumber(), Graphics.FONT_XTINY,
                    message, Graphics.TEXT_JUSTIFY_CENTER);
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
                        Pack.name(), Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! Two lines: where you are, and whether the render is keeping up.
    //!
    //! Pitch is a fraction of the screen rather than a fixed 18 px, which
    //! collides on a 454 px face. Two lines and not more: tile and cache
    //! counters are for tuning the packer, not for wearing.
    hidden function drawDebug(dc, colours as Array<Number>) {
        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        // "done" versus "..." is the line worth having. A map that is still
        // building looks exactly like a map that has finished and is missing
        // half its layers, and only one of those is a bug. Without it, a report
        // from a wrist cannot tell the two apart, and the simulator will not
        // reproduce either.
        var lines = [
            _camera.lat.format("%.5f") + ", " + _camera.lon.format("%.5f"),
            "z" + _camera.zoom + "   " + _renderer.segmentsDrawn() + " seg   "
                + _renderMs + " ms",
            _renderer.tilesDrawn() + " tiles   "
                + (_renderer.complete() ? "done" : "..."),
            // Restarts climbing while the map sits still is the signature of
            // the bug this renderer keeps having. See MapRenderer._restarts.
            _renderer.restarts() + " restarts" 
        ];
        var pitch = _height * 0.075;
        var top = _height * 0.30;
        for (var i = 0; i < lines.size(); i += 1) {
            dc.drawText(_width / 2, (top + i * pitch).toNumber(), Graphics.FONT_XTINY,
                        lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
