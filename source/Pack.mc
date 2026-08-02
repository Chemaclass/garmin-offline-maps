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

    //! The active downloaded city, unpacked into typed fields.
    //!
    //! **Everything integral is coerced with `toNumber()` here, and that is the
    //! whole point of this module.** Values arriving from JSON may be Float,
    //! and every one of them ends up in a shift:
    //!
    //!     Mercator.worldSize   1 << zoom          <- dataZooms
    //!     MapRenderer.drawTile tileX >> log2      <- blockLog2
    //!     blockKey             1 << keyShift      <- keyShift
    //!
    //! A shift with a Float operand raises `UnexpectedTypeError`, which is a
    //! `Lang.Error` rather than a `Lang.Exception`: no `catch` can stop it, and
    //! the watch shows the Connect IQ error screen. That is exactly what a
    //! downloaded city did on hardware, and no amount of guarding fixed it,
    //! because the error was never catchable.
    //!
    //! The compiled-in pack never had this problem: `MapIndex` declares these
    //! as Monkey C integer literals.
    //!
    //! Coercing once here rather than at each use also keeps the dictionary
    //! lookups out of the render loop.
    //!
    //! Plain `var`: `hidden` is a class modifier and the compiler rejects it
    //! inside a module.
    var _downloaded = false;
    var _name = "";
    var _attribution = "";
    var _minZoom = 0;
    var _maxZoom = 0;
    var _zooms as Array<Number> = [];
    var _log2s as Array<Number> = [];
    var _originX as Array<Number> = [];
    var _originY as Array<Number> = [];
    var _keyShift = 10;
    var _blockCount = 0;
    var _dataBytes = 0;
    var _west = 0.0d;
    var _south = 0.0d;
    var _east = 0.0d;
    var _north = 0.0d;
    var _centerLat = 0.0d;
    var _centerLon = 0.0d;

    //! Adopt a downloaded city. Pass null to fall back to the built-in pack.
    function use(meta) {
        if (meta == null) {
            _downloaded = false;
            return;
        }
        var m = meta as Dictionary;
        _name = m["name"];
        _attribution = m["attribution"];
        _minZoom = numberOf(m["minZoom"], 13);
        _maxZoom = numberOf(m["maxZoom"], 15);
        _zooms = numbersOf(m["dataZooms"]);
        _log2s = numbersOf(m["blockLog2"]);
        _originX = numbersOf(m["originX"]);
        _originY = numbersOf(m["originY"]);
        _keyShift = numberOf(m["keyShift"], 10);
        _west = doubleOf(m["west"]);
        _south = doubleOf(m["south"]);
        _east = doubleOf(m["east"]);
        _north = doubleOf(m["north"]);
        _centerLat = doubleOf(m["centerLat"]);
        _centerLon = doubleOf(m["centerLon"]);
        _dataBytes = numberOf(m["storedBytes"], 0);
        var keys = m["blocks"] as Array;
        _blockCount = keys == null ? 0 : keys.size();
        // Only now, so a malformed meta cannot leave the app half-switched.
        _downloaded = true;
    }

    //! Integer or the fallback. Never returns a Float: see the note above.
    function numberOf(value, fallback) {
        if (value == null) { return fallback; }
        return value.toNumber();
    }

    function doubleOf(value) {
        return value == null ? 0.0d : value.toDouble();
    }

    function numbersOf(value) {
        var out = [] as Array<Number>;
        if (value == null) { return out; }
        var list = value as Array;
        for (var i = 0; i < list.size(); i += 1) {
            out.add(list[i].toNumber());
        }
        return out;
    }

    function isDownloaded() {
        return _downloaded;
    }

    function name() {
        return !_downloaded ? MapIndex.PACK_NAME : _name;
    }

    function attribution() {
        return !_downloaded ? MapIndex.ATTRIBUTION : _attribution;
    }

    function minZoom() {
        return !_downloaded ? MapIndex.MIN_ZOOM : _minZoom;
    }

    function maxZoom() {
        return !_downloaded ? MapIndex.MAX_ZOOM : _maxZoom;
    }

    function dataZooms() as Array<Number> {
        return !_downloaded ? MapIndex.DATA_ZOOMS : _zooms;
    }

    function west()  { return !_downloaded ? MapIndex.WEST  : _west; }
    function south() { return !_downloaded ? MapIndex.SOUTH : _south; }
    function east()  { return !_downloaded ? MapIndex.EAST  : _east; }
    function north() { return !_downloaded ? MapIndex.NORTH : _north; }

    function centerLat() {
        return !_downloaded ? MapIndex.CENTER_LAT : _centerLat;
    }

    function centerLon() {
        return !_downloaded ? MapIndex.CENTER_LON : _centerLon;
    }

    function blockCount() {
        return !_downloaded ? MapIndex.BLOCK_COUNT : _blockCount;
    }

    //! Bytes the map occupies. Compiled in that is resource bytes; downloaded
    //! it is what sits in Storage, which is base64 and so about a third larger.
    function dataBytes() {
        return !_downloaded ? MapIndex.DATA_BYTES : _dataBytes;
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
        var best = _zooms[0];
        for (var i = 0; i < _zooms.size(); i += 1) {
            if (_zooms[i] <= displayZoom) { best = _zooms[i]; }
        }
        return best;
    }

    function blockLog2(z) {
        if (!_downloaded) { return MapIndex.blockLog2(z); }
        var slot = zoomSlot(z);
        return slot < 0 ? _log2s[0] : _log2s[slot];
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
        var rx = blockX - _originX[slot];
        var ry = blockY - _originY[slot];
        var limit = (1 << _keyShift) - 1;
        if (rx < 0 || ry < 0 || rx > limit || ry > limit) { return -1; }
        return (rx << _keyShift) | ry;
    }
}
