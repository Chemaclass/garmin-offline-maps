//
// GENERATED FILE -- DO NOT EDIT.
// Produced by tools/mappack. Re-run `make pack` to regenerate.
//

import Toybox.Lang;

module MapIndex {
    // --- format ---
    const FORMAT_VERSION = 1;
    const EXTENT = 1024;
    const CLIP_BUFFER = 64;

    // --- this pack ---
    const PACK_NAME = "Demo City";
    const ATTRIBUTION = "(c) OpenStreetMap contributors";
    const MIN_ZOOM = 11;
    const MAX_ZOOM = 17;
    const DATA_ZOOMS = [12, 14, 16];
    const BLOCK_LOG2 = [3, 3, 3];
    const BLOCK_ORIGIN_X = [250, 1002, 4011];
    const BLOCK_ORIGIN_Y = [193, 772, 3088];
    const KEY_SHIFT = 10;

    const WEST = -3.7338000d;
    const SOUTH = 40.3996000d;
    const EAST = -3.6738000d;
    const NORTH = 40.4363988d;
    const CENTER_LON = -3.7038000d;
    const CENTER_LAT = 40.4179994d;

    const BLOCK_COUNT = 7;
    const DATA_BYTES = 8280;

    //! Index of z in DATA_ZOOMS, or -1.
    function zoomSlot(z) {
        for (var i = 0; i < DATA_ZOOMS.size(); i += 1) {
            if (DATA_ZOOMS[i] == z) { return i; }
        }
        return -1;
    }

    //! Best available data zoom for a display zoom.
    function dataZoomFor(displayZoom) {
        var best = DATA_ZOOMS[0];
        for (var i = 0; i < DATA_ZOOMS.size(); i += 1) {
            if (DATA_ZOOMS[i] <= displayZoom) { best = DATA_ZOOMS[i]; }
        }
        return best;
    }

    //! Tiles per block axis, as a power of two, for a data zoom.
    function blockLog2(z) {
        var slot = zoomSlot(z);
        return slot < 0 ? BLOCK_LOG2[0] : BLOCK_LOG2[slot];
    }

    //! Resource holding the block that owns (blockX, blockY) at zoom z,
    //! or null when nothing was packed there.
    function blockResource(z, blockX, blockY) {
        var slot = zoomSlot(z);
        if (slot < 0) { return null; }
        var rx = blockX - BLOCK_ORIGIN_X[slot];
        var ry = blockY - BLOCK_ORIGIN_Y[slot];
        if (rx < 0 || ry < 0 || rx > 1023 || ry > 1023) { return null; }
        var key = (rx << KEY_SHIFT) | ry;
        if (z == 12) {
            switch (key) {
                case 0: return Rez.JsonData.b12_250_193;
            }
        } else if (z == 14) {
            switch (key) {
                case 0: return Rez.JsonData.b14_1002_772;
                case 1024: return Rez.JsonData.b14_1003_772;
            }
        } else if (z == 16) {
            switch (key) {
                case 0: return Rez.JsonData.b16_4011_3088;
                case 1: return Rez.JsonData.b16_4011_3089;
                case 1024: return Rez.JsonData.b16_4012_3088;
                case 1025: return Rez.JsonData.b16_4012_3089;
            }
        }
        return null;
    }
}
