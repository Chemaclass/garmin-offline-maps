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
    //! The segment counts above are a proxy for time, and on a downloaded city
    //! the proxy broke: the watchdog killed the app inside `drawPolyline`,
    //! decoding varints, with the segment budget not yet spent. Two reasons it
    //! could not save us. The budget is only tested between features, so one
    //! dense feature runs to its end whatever the cost; and a segment is not a
    //! fixed amount of work, so 2600 of them is a different length of frame in
    //! Berlin than in the demo pack.
    //!
    //! Time is what the watchdog actually measures, so measure the same thing.
    //! It fires around 5 s (docs/DEVICES.md); this leaves room for the blit and
    //! everything else in the frame.
    //! 1200 was not enough of a cut: the watchdog still fired inside
    //! `drawPolyline`. A frame this long is wrong anyway. The design target in
    //! docs/RENDERING.md is a redraw well under a second, and the map is
    //! re-rendered until the store has fed in every block, so a slow frame is
    //! not paid once but on every pass.
    const FRAME_BUDGET_MS = 250;

    //! Checked every 16 points rather than every point: `getTimer` in the inner
    //! loop of the hot path would itself cost more than it saves. Each point is
    //! a `drawLine`, so 16 of them is already real work.
    const TIME_CHECK_MASK = 0x0F;

    const PASS_AREAS = 0;
    const PASS_LINES = 1;

    hidden var _segments;
    hidden var _passSegments;
    //! Points processed this pass, drawn or not. This is what the budget
    //! actually limits; see the note in `drawPolyline`.
    hidden var _passWork;
    hidden var _tilesDrawn;
    hidden var _passTruncated;
    //! `System.getTimer()` value past which this render stops.
    hidden var _deadline;
    //! True when a render ended on the clock rather than on its budget.
    hidden var _timedOut;

    function initialize() {
        _segments = 0;
        _passSegments = 0;
        _passWork = 0;
        _tilesDrawn = 0;
        _passTruncated = false;
    }

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

    function render(dc, camera, store) {
        _segments = 0;
        _passSegments = 0;
        _passWork = 0;
        _tilesDrawn = 0;
        _passTruncated = false;
        _deadline = System.getTimer() + FRAME_BUDGET_MS;
        _timedOut = false;

        store.beginFrame();

        var colours = Palette.colours(camera.night);
        var background = colours[Palette.SLOT_BACKGROUND];
        dc.setColor(background, background);
        dc.clear();

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

        for (var pass = PASS_AREAS; pass <= PASS_LINES; pass += 1) {
            var budget = (pass == PASS_AREAS) ? AREA_SEGMENTS : MAX_SEGMENTS;
            _passSegments = 0;
            _passWork = 0;
            _passTruncated = false;
            for (var tileY = minTileY; tileY <= maxTileY && !_passTruncated; tileY += 1) {
                for (var tileX = minTileX; tileX <= maxTileX && !_passTruncated; tileX += 1) {
                    drawTile(dc, store, colours, camera, pass, dataZoom, log2,
                             tileX, tileY, centreX, centreY, scale,
                             halfW, halfH, cosT, sinT, width, height, budget);
                }
            }
        }
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

            if (layerId < 0 || layerId >= Palette.LAYER_COUNT) {
                // A pack built by a newer packer than this app knows about.
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
                if (_passWork > budget || outOfTime()) {
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
            // Inside the point loop, not just around it. This is the frame the
            // watchdog killed: one polyline long enough to run out the clock on
            // its own, with the caller's budget check never reached.
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
            // something is on screen.
            //
            // Counting drawn lines alone left the budget unable to fire at all
            // when the geometry was off screen. Nothing was inside, so nothing
            // incremented, so the cap was never reached, and the renderer
            // walked every feature of every tile drawing nothing until the
            // watchdog killed the app. A map that is merely off centre must not
            // be more expensive than one that is not.
            _passWork += 1;
            if (i > 0 && (inside || prevInside)) {
                dc.drawLine(prevSx.toNumber(), prevSy.toNumber(), sx.toNumber(), sy.toNumber());
                _segments += 1;
                _passSegments += 1;
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
            _passSegments += at;
        }
    }
}
