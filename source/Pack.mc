import Toybox.Application;
import Toybox.Lang;

//! The map the app is currently showing, whichever way it got here.
//!
//! There are two kinds of pack and the rest of the app must not care which is
//! in play:
//!
//!  * the **built-in** pack, compiled into the `.prg` as jsonData resources and
//!    described by the generated `MapIndex`; and
//!  * a **downloaded** city, fetched over the phone and kept in
//!    `Application.Storage` (see `CityStore`).
//!
//! Everything else asks `Pack` rather than `MapIndex`, so switching city is one
//! call to `use()` and a cache flush. `MapIndex` is still the source of truth
//! for the built-in pack and for format constants that never vary.
module Pack {

    //! Meta of the active downloaded city, or null when the built-in pack is
    //! in use. Shape is `<slug>/meta.json`; see tools/mappack/mappack/citypack.py.
    //!
    //! Plain `var` rather than `hidden var`: `hidden` is a class modifier and
    //! the compiler rejects it inside a module. The leading underscore still
    //! says "do not touch this from outside".
    //!
    //! Kept non-null, with `_downloaded` saying whether it means anything. A
    //! `Dictionary?` would be honest but the type checker cannot subscript a
    //! nullable, and every accessor below is a subscript.
    var _meta as Dictionary = {};
    var _downloaded = false;

    //! Adopt a downloaded city. Pass null to fall back to the built-in pack.
    function use(meta) {
        if (meta == null) {
            _meta = {};
            _downloaded = false;
        } else {
            _meta = meta as Dictionary;
            _downloaded = true;
        }
    }

    function isDownloaded() {
        return _downloaded;
    }

    function name() {
        return !_downloaded ? MapIndex.PACK_NAME : _meta["name"];
    }

    function attribution() {
        return !_downloaded ? MapIndex.ATTRIBUTION : _meta["attribution"];
    }

    function minZoom() {
        return !_downloaded ? MapIndex.MIN_ZOOM : _meta["minZoom"];
    }

    function maxZoom() {
        return !_downloaded ? MapIndex.MAX_ZOOM : _meta["maxZoom"];
    }

    function dataZooms() as Array<Number> {
        return !_downloaded ? MapIndex.DATA_ZOOMS : _meta["dataZooms"];
    }

    function west()  { return !_downloaded ? MapIndex.WEST  : _meta["west"]; }
    function south() { return !_downloaded ? MapIndex.SOUTH : _meta["south"]; }
    function east()  { return !_downloaded ? MapIndex.EAST  : _meta["east"]; }
    function north() { return !_downloaded ? MapIndex.NORTH : _meta["north"]; }

    function centerLat() {
        return !_downloaded ? MapIndex.CENTER_LAT : _meta["centerLat"];
    }

    function centerLon() {
        return !_downloaded ? MapIndex.CENTER_LON : _meta["centerLon"];
    }

    function blockCount() {
        if (!_downloaded) { return MapIndex.BLOCK_COUNT; }
        var keys = _meta["blocks"] as Array<Number>;
        return keys.size();
    }

    //! Bytes the map occupies. Compiled in that is resource bytes; downloaded
    //! it is what sits in Storage, which is base64 and so about a third larger.
    function dataBytes() {
        return !_downloaded ? MapIndex.DATA_BYTES : _meta["storedBytes"];
    }

    //! Index of z in dataZooms(), or -1.
    function zoomSlot(z) {
        var zooms = dataZooms();
        for (var i = 0; i < zooms.size(); i += 1) {
            if (zooms[i] == z) { return i; }
        }
        return -1;
    }

    //! Best available data zoom for a display zoom.
    function dataZoomFor(displayZoom) {
        if (!_downloaded) { return MapIndex.dataZoomFor(displayZoom); }
        var zooms = _meta["dataZooms"] as Array<Number>;
        var best = zooms[0];
        for (var i = 0; i < zooms.size(); i += 1) {
            if (zooms[i] <= displayZoom) { best = zooms[i]; }
        }
        return best;
    }

    function blockLog2(z) {
        if (!_downloaded) { return MapIndex.blockLog2(z); }
        var slot = zoomSlot(z);
        var log2s = _meta["blockLog2"] as Array<Number>;
        return slot < 0 ? log2s[0] : log2s[slot];
    }

    //! Decoded bytes of the block owning (blockX, blockY) at zoom z, or null.
    //!
    //! The built-in path hands back a jsonData resource for `TileStore` to
    //! decode; the downloaded path reads the same base64 out of Storage. Both
    //! end up as the identical MapPack block, which is why `TileReader` needs
    //! no idea where it came from.
    function blockBase64(z, blockX, blockY) {
        if (!_downloaded) {
            var resource = MapIndex.blockResource(z, blockX, blockY);
            return resource == null ? null : Application.loadResource(resource);
        }
        var key = blockKey(z, blockX, blockY);
        return key < 0 ? null : CityStore.blockBase64(key);
    }

    //! Is anything packed here? Cheap, and separate from `blockBase64` so the
    //! tile cache can make room *before* paying for the load rather than after.
    function hasBlock(z, blockX, blockY) {
        if (!_downloaded) {
            return MapIndex.blockResource(z, blockX, blockY) != null;
        }
        return blockKey(z, blockX, blockY) >= 0;
    }

    //! (relX << keyShift) | relY, matching what the packer wrote. -1 when the
    //! block is outside this pack.
    function blockKey(z, blockX, blockY) {
        if (!_downloaded) { return -1; }
        var slot = zoomSlot(z);
        if (slot < 0) { return -1; }
        var originX = _meta["originX"] as Array<Number>;
        var originY = _meta["originY"] as Array<Number>;
        var rx = blockX - originX[slot];
        var ry = blockY - originY[slot];
        var shift = _meta["keyShift"];
        var limit = (1 << shift) - 1;
        if (rx < 0 || ry < 0 || rx > limit || ry > limit) { return -1; }
        return (rx << shift) | ry;
    }
}
