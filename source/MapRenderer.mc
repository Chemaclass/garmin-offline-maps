import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! Draws the visible tiles into a device context.
//!
//! Performance notes, because they drove every decision here:
//!  * Each `drawLine` is an interpreted call, and a full redraw has to stay
//!    well under a second to feel like a map rather than a slideshow. (The
//!    watchdog itself only fires around 5 s -- see docs/DEVICES.md -- so this
//!    is a usability ceiling, not a crash one.) Rendering therefore happens
//!    once into an off-screen buffer when the view changes, never per frame,
//!    and the total segment count is hard-capped.
//!  * Geometry is decoded straight into draw calls -- no intermediate feature
//!    objects -- because allocation is the other thing that hurts on a 768 KB
//!    heap.
//!  * Two passes (areas everywhere, then strokes everywhere) stop a lake in
//!    one tile from painting over a road in the tile next door.
class MapRenderer {

    //! Hard ceiling on primitives per render, to stay clear of the watchdog.
    const MAX_SEGMENTS = 400;
    //! Areas get their own, smaller budget. They are drawn first, and without
    //! a separate allowance a city full of parks and buildings could spend the
    //! whole frame before a single road is drawn.
    const AREA_SEGMENTS = 150;
    const MAX_POLYGON_POINTS = 64;

    //! Milliseconds a single render may spend before it gives up and draws
    //! what it has.
    //!
    //! Time, not the segment counts above, because time is what the watchdog
    //! measures. The counts are a poor proxy for it twice over: they are only
    //! tested between features, so one dense feature runs to its end whatever
    //! the cost, and a segment is not a fixed amount of work, so 2600 of them
    //! is a different length of frame in Berlin than in the demo pack.
    //!
    //! 80 is measured. Frames get heavier as blocks arrive and the view keeps
    //! re-rendering while they do: a downloaded Berlin at zoom 13 climbed
    //! 42 -> 76 -> 86 -> 125 ms before the app was killed, so a cap much above
    //! 100 never bites while the churn still adds up. At 80 it does: 198
    //! renders panning Alexanderplatz to Wedding across zooms 13 to 15 peaked
    //! at 81 ms with nothing killed. The watchdog fires around 5 s
    //! (docs/DEVICES.md); the rest of that is the blit and the overlay.
    const FRAME_BUDGET_MS = 80;

    //! Checked every 16 points rather than every point: `getTimer` in the inner
    //! loop of the hot path would itself cost more than it saves. Each point is
    //! a `drawLine`, so 16 of them is already real work.
    const TIME_CHECK_MASK = 0x0F;

    const PASS_AREAS = 0;
    const PASS_LINES = 1;

    hidden var _segments;
    //! Points processed this pass, drawn or not. This is what the budget
    //! actually limits; see the note in `drawPolyline`.
    hidden var _passWork;
    hidden var _tilesDrawn;
    hidden var _passTruncated;
    //! `System.getTimer()` value past which this render stops.
    hidden var _deadline;
    //! True when a render ended on the clock rather than on its budget.
    hidden var _timedOut;
    //! Where the next frame resumes: pass, then row, then column. Null means
    //! the start of a pass.
    hidden var _cursorPass;
    hidden var _cursorTileY;
    hidden var _cursorTileX;
    //! True once every pass has run to the end for the current view.
    hidden var _complete;
    //! True while drawing the one tile a frame owes the map regardless of the
    //! clock. See the note in `render`.
    hidden var _atomicTile;

    function initialize() {
        _segments = 0;
        _passWork = 0;
        _tilesDrawn = 0;
        _passTruncated = false;
        _cursorPass = PASS_AREAS;
        _cursorTileY = null;
        _cursorTileX = null;
        _complete = false;
        _atomicTile = false;
    }

    //! Has the whole view been drawn? False means the buffer holds a partial
    //! picture and the view should ask for another frame.
    function complete() { return _complete; }

    function segmentsDrawn() { return _segments; }
    function tilesDrawn() { return _tilesDrawn; }

    //! Did the last render stop on the clock? Worth knowing: it means the map
    //! on screen is missing detail it had time to find but not to draw.
    function timedOut() { return _timedOut; }

    //! Past the deadline for this frame. Latches `_timedOut`, so the answer
    //! survives the unwinding that follows.
    hidden function outOfTime() {
        if (_timedOut) { return true; }
        if (System.getTimer() >= _deadline) {
            _timedOut = true;
            return true;
        }
        return false;
    }

    //! Draw as much of the map as fits in one frame, and remember where it got
    //! to so the next frame carries on.
    //!
    //! `restart` clears the buffer and begins again, which is what a changed
    //! view wants. Without it the buffer is left alone and drawing resumes from
    //! the saved cursor, so the picture accumulates rather than being redrawn
    //! and thrown away.
    //!
    //! This is what makes the map complete at all. A frame has to be short or
    //! the watchdog kills the app, but a city needs far more drawing than fits
    //! in one short frame, and truncating to fit meant a screen with its right
    //! half empty. Spreading the same work over several frames costs a moment
    //! of the map filling in and gets the whole of it.
    function render(dc, camera, store, restart) {
        _deadline = System.getTimer() + FRAME_BUDGET_MS;
        _timedOut = false;
        _passWork = 0;
        _passTruncated = false;

        store.beginFrame();

        var colours = Palette.colours(camera.night);
        if (restart) {
            _segments = 0;
            _tilesDrawn = 0;
            _complete = false;
            _cursorPass = PASS_AREAS;
            _cursorTileY = null;
            _cursorTileX = null;
            Ui.clear(dc, colours);
        } else if (_complete) {
            return;
        }

        var width = dc.getWidth();
        var height = dc.getHeight();
        var halfW = width / 2.0;
        var halfH = height / 2.0;

        var dataZoom = Pack.dataZoomFor(camera.zoom);
        var scale = Mercator.pow2(camera.zoom - dataZoom);
        var log2 = Pack.blockLog2(dataZoom);
        // Guarded at the call site, not inside `trace`: the concatenation
        // happens before the call either way, and this is once per frame.
        if (Diag.tracing) {
            Diag.trace("render z" + camera.zoom + " data" + dataZoom
                       + " log2:" + log2);
        }

        var centreX = Mercator.lonToWorldX(camera.lon, dataZoom);
        var centreY = Mercator.latToWorldY(camera.lat, dataZoom);

        // Rotation means the corners can pull in geometry from further out, so
        // work with the circumscribed radius rather than the half-extents.
        var radius = Math.sqrt(halfW * halfW + halfH * halfH) / scale;
        var minTileX = ((centreX - radius) / Mercator.TILE_SIZE).toNumber();
        var maxTileX = ((centreX + radius) / Mercator.TILE_SIZE).toNumber();
        var minTileY = ((centreY - radius) / Mercator.TILE_SIZE).toNumber();
        var maxTileY = ((centreY + radius) / Mercator.TILE_SIZE).toNumber();
        if (centreX - radius < 0) { minTileX -= 1; }
        if (centreY - radius < 0) { minTileY -= 1; }

        // Clip the scan to the tiles the pack actually covers.
        //
        // Zooming out does not show more map, it shows more emptiness around
        // it, and every empty tile still costs a cache scan and a key lookup.
        // A pack a few kilometres across sits inside a handful of tiles while
        // the viewport at the widest zoom asks about thirty-six, so most of
        // that loop is spent proving there is nothing there. Cheap on a laptop
        // and not on a watch, which is the gap this closes.
        var packMinX = (Mercator.lonToWorldX(Pack.west(), dataZoom)
                        / Mercator.TILE_SIZE).toNumber();
        var packMaxX = (Mercator.lonToWorldX(Pack.east(), dataZoom)
                        / Mercator.TILE_SIZE).toNumber();
        // Latitude runs the other way: north is the smaller world Y.
        var packMinY = (Mercator.latToWorldY(Pack.north(), dataZoom)
                        / Mercator.TILE_SIZE).toNumber();
        var packMaxY = (Mercator.latToWorldY(Pack.south(), dataZoom)
                        / Mercator.TILE_SIZE).toNumber();
        if (minTileX < packMinX) { minTileX = packMinX; }
        if (maxTileX > packMaxX) { maxTileX = packMaxX; }
        if (minTileY < packMinY) { minTileY = packMinY; }
        if (maxTileY > packMaxY) { maxTileY = packMaxY; }

        var theta = camera.rotation();
        var cosT = 1.0;
        var sinT = 0.0;
        if (theta != 0.0) {
            cosT = Math.cos(theta);
            sinT = Math.sin(theta);
        }

        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }

        // Pick up where the last frame stopped. Null means "start of a pass",
        // which is also the state after a restart.
        if (_cursorTileY == null) { _cursorTileY = minTileY; }
        if (_cursorTileX == null) { _cursorTileX = minTileX; }

        // A whole tile is the unit of progress, and at least one gets drawn per
        // frame whatever the clock says.
        //
        // That guarantee is what makes resuming terminate. Stopping partway
        // through a tile means resuming at the same tile, redrawing it from the
        // start, and stopping in the same place: the map never advances and the
        // app renders for ever. Measured, before this: 575 frames, 15,000
        // segments, never once complete.
        //
        // Overrunning the budget by one tile is affordable because a tile is
        // bounded work. The packer caps points per tile in the hundreds, so the
        // worst tile is nothing like the multi-second budget the watchdog
        // allows.
        var drewOne = false;
        for (var pass = _cursorPass; pass <= PASS_LINES; pass += 1) {
            var budget = (pass == PASS_AREAS) ? AREA_SEGMENTS : MAX_SEGMENTS;
            _passWork = 0;
            _passTruncated = false;
            for (var tileY = _cursorTileY; tileY <= maxTileY; tileY += 1) {
                for (var tileX = _cursorTileX; tileX <= maxTileX; tileX += 1) {
                    if (drewOne && outOfTime()) {
                        // Resume at this tile, which has not been drawn.
                        _cursorPass = pass;
                        _cursorTileY = tileY;
                        _cursorTileX = tileX;
                        return;
                    }
                    // The first tile of a frame finishes whatever the clock
                    // says; the rest may stop partway and be resumed.
                    _atomicTile = !drewOne;
                    drawTile(dc, store, colours, camera, pass, dataZoom, log2,
                             tileX, tileY, centreX, centreY, scale,
                             halfW, halfH, cosT, sinT, width, height, budget);
                    drewOne = true;
                    if (_passTruncated) {
                        // Stopped inside this tile. Come back to it: next frame
                        // it will be the atomic one and will finish.
                        _cursorPass = pass;
                        _cursorTileY = tileY;
                        _cursorTileX = tileX;
                        return;
                    }
                }
                _cursorTileX = minTileX;
            }
            // Pass finished. The next one starts at the top again.
            _cursorTileY = minTileY;
            _cursorTileX = minTileX;
        }
        _complete = true;
    }

    //! `colours` is annotated for the same reason as in MapView: it is indexed
    //! here, and a plain parameter is `Object?`, which the checker will not
    //! index. It comes from `Palette.colours()`, which is typed at the source.
    hidden function drawTile(dc, store, colours as Array<Number>, camera, pass, dataZoom, log2,
                             tileX, tileY, centreX, centreY, scale,
                             halfW, halfH, cosT, sinT, width, height, budget) {
        var block = store.block(dataZoom, tileX >> log2, tileY >> log2);
        if (block == null) {
            return;
        }
        var offset = store.tileOffset(block, tileX, tileY, log2);
        if (offset < 0) {
            return;
        }
        if (pass == PASS_AREAS) { _tilesDrawn += 1; }

        // Screen position of this tile's top-left corner, relative to centre.
        var originX = (tileX * Mercator.TILE_SIZE - centreX) * scale;
        var originY = (tileY * Mercator.TILE_SIZE - centreY) * scale;
        var unitsToPixels = scale * Mercator.TILE_SIZE / MapIndex.EXTENT;
        var rotated = (cosT != 1.0) || (sinT != 0.0);

        var reader = new TileReader(block, offset);
        var layerCount = reader.u8();

        for (var l = 0; l < layerCount; l += 1) {
            var layerId = reader.u8();
            var layerBytes = reader.u16();
            var layerEnd = reader.pos + layerBytes;
            var isArea = Palette.isArea(layerId);
            var wanted = (pass == PASS_AREAS) ? isArea : !isArea;

            if (!wanted) {
                reader.pos = layerEnd;
                if (pass == PASS_AREAS) {
                    // Layers ascend, so once we are past the areas we are done.
                    return;
                }
                continue;
            }

            if (layerId >= Palette.LAYER_COUNT) {
                // A pack built by a newer packer than this app knows about.
                // No `< 0` half: `u8` reads a ByteArray element, which cannot
                // be negative. `pointCount` below can, because a five-byte
                // varint overflows into the sign bit, and is checked for it.
                reader.pos = layerEnd;
                continue;
            }

            var colour = colours[layerId];
            dc.setColor(colour, colour);
            if (!isArea) {
                dc.setPenWidth(Palette.penWidth(layerId, camera.zoom));
            }

            var featureCount = reader.u8();
            for (var f = 0; f < featureCount; f += 1) {
                var geomType = reader.u8();
                var pointCount = reader.uvarint();
                // A count this size did not come from the packer, which caps
                // points per tile in the hundreds. It came from reading at an
                // offset that is not a feature boundary, and the loop below
                // would spend the frame on it. Abandon the tile: the rest of
                // this payload cannot be trusted either.
                if (pointCount < 0 || pointCount > MapFormat.MAX_FEATURE_POINTS
                        || reader.pos > layerEnd) {
                    Diag.note("tile", "bad feature at " + tileX + "/" + tileY);
                    return;
                }
                if (geomType == MapFormat.GEOM_POLYGON) {
                    drawPolygon(dc, reader, pointCount, originX, originY, unitsToPixels,
                                halfW, halfH, cosT, sinT, rotated);
                } else {
                    drawPolyline(dc, reader, pointCount, originX, originY, unitsToPixels,
                                 halfW, halfH, cosT, sinT, rotated, width, height);
                }
                // Only a runaway count stops a tile now, not the clock and not
                // the segment budget.
                //
                // A tile is drawn whole or the map gets holes in it. Stopping
                // partway leaves the rest of that tile undrawn, and the frame
                // loop has already moved the cursor past it, so nothing ever
                // comes back for it. Frames are kept short between tiles
                // instead, where stopping costs nothing. `budget` survives as
                // the guard against a single tile being absurd.
                if (!_atomicTile && (_passWork > budget || outOfTime())) {
                    _passTruncated = true;
                    return;
                }
            }
            reader.pos = layerEnd;
        }
    }

    hidden function drawPolyline(dc, reader, pointCount, originX, originY, unitsToPixels,
                                 halfW, halfH, cosT, sinT, rotated, width, height) {
        var x = 0;
        var y = 0;
        var prevSx = 0.0;
        var prevSy = 0.0;
        var prevInside = false;

        for (var i = 0; i < pointCount; i += 1) {
            // Inside the point loop, not just around it: one polyline can be
            // long enough to run out the clock on its own, and the caller's
            // budget check is not reached until the whole feature is done.
            //
            // No need to consume the remaining varints to keep the reader in
            // step: `drawTile` builds a fresh one per tile and returns as soon
            // as it sees the truncation, so this one is thrown away. Reading
            // them would spend exactly the time we are trying to save.
            if ((i & TIME_CHECK_MASK) == 0 && outOfTime()) {
                _passTruncated = true;
                return;
            }
            x += reader.svarint();
            y += reader.svarint();

            var ux = originX + x * unitsToPixels;
            var uy = originY + y * unitsToPixels;
            var sx;
            var sy;
            if (rotated) {
                sx = halfW + ux * cosT + uy * sinT;
                sy = halfH - ux * sinT + uy * cosT;
            } else {
                sx = halfW + ux;
                sy = halfH + uy;
            }
            var inside = sx >= -8 && sy >= -8 && sx <= width + 8 && sy <= height + 8;

            // Every point costs, drawn or not: decoding the varints and
            // projecting is most of the work, and `drawLine` only happens when
            // something is on screen. Count drawn lines instead and the budget
            // cannot fire at all with the geometry off screen -- nothing is
            // inside, so nothing increments, and the renderer walks every
            // feature of every tile drawing nothing until the watchdog kills
            // the app. A map that is merely off centre must not cost more than
            // one that is not.
            _passWork += 1;
            if (i > 0 && (inside || prevInside)) {
                dc.drawLine(prevSx.toNumber(), prevSy.toNumber(), sx.toNumber(), sy.toNumber());
                _segments += 1;
            }
            prevSx = sx;
            prevSy = sy;
            prevInside = inside;
        }
    }

    hidden function drawPolygon(dc, reader, pointCount, originX, originY, unitsToPixels,
                                halfW, halfH, cosT, sinT, rotated) {
        var keep = pointCount < MAX_POLYGON_POINTS ? pointCount : MAX_POLYGON_POINTS;
        var points = new [keep];
        var x = 0;
        var y = 0;
        var at = 0;

        for (var i = 0; i < pointCount; i += 1) {
            if ((i & TIME_CHECK_MASK) == 0 && outOfTime()) {
                _passTruncated = true;
                return;
            }
            // Counted here for the same reason as in `drawPolyline`: the
            // decode is the cost, and a polygon off screen still pays it.
            _passWork += 1;
            x += reader.svarint();
            y += reader.svarint();
            if (at >= keep) {
                continue; // still have to consume the varints
            }
            var ux = originX + x * unitsToPixels;
            var uy = originY + y * unitsToPixels;
            if (rotated) {
                points[at] = [(halfW + ux * cosT + uy * sinT).toNumber(),
                              (halfH - ux * sinT + uy * cosT).toNumber()];
            } else {
                points[at] = [(halfW + ux).toNumber(), (halfH + uy).toNumber()];
            }
            at += 1;
        }

        if (at >= 3) {
            if (at < keep) {
                var trimmed = new [at];
                for (var i = 0; i < at; i += 1) { trimmed[i] = points[i]; }
                points = trimmed;
            }
            dc.fillPolygon(points);
            _segments += at;
        }
    }
}
