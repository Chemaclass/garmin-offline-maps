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

    //! The active downloaded city, unpacked into fields `Num` has already
    //! made safe to compute with. Why that matters is in `Num`; where each
    //! one lands is here:
    //!
    //!     Mercator.worldSize   1 << zoom          <- dataZooms
    //!     MapRenderer.drawTile tileX >> log2      <- blockLog2
    //!     blockKey             1 << keyShift      <- keyShift
    //!
    //! Fields rather than dictionary lookups at each use, for two reasons: the
    //! conversion happens once instead of once per frame, and a city that
    //! cannot supply one of these is rejected in `use` rather than halfway
    //! through a render.
    //!
    //! The compiled-in pack never needed any of this: `MapIndex` declares the
    //! same values as Monkey C integer literals.
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
    //! The keys this pack actually holds. Kept, not just counted: see
    //! `hasBlock`.
    var _blocks as Array<Number> = [];
    var _dataBytes = 0;
    var _west = 0.0d;
    var _south = 0.0d;
    var _east = 0.0d;
    var _north = 0.0d;
    var _centerLat = 0.0d;
    var _centerLon = 0.0d;

    //! Adopt a downloaded city. Pass null to fall back to the built-in pack.
    //!
    //! Null and "not a dictionary" are separated on purpose. Null is how the
    //! app asks for the built-in map and is not a fault; anything else that is
    //! not a dictionary is one, and gets said out loud. Both are possible
    //! because this comes back out of Storage, and subscripting a String would
    //! throw here, in a path `onCityChosen` does not wrap in a try.
    function use(meta) {
        if (meta == null) {
            _downloaded = false;
            return;
        }
        if (!(meta instanceof Lang.Dictionary)) {
            refuse("not a map description");
            return;
        }
        var m = meta as Dictionary;
        _name = Num.text(m["name"], "");
        _attribution = Num.text(m["attribution"], "");
        _minZoom = Num.integer(m["minZoom"], 13);
        _maxZoom = Num.integer(m["maxZoom"], 15);
        _zooms = Num.integers(m["dataZooms"]);
        _log2s = Num.integers(m["blockLog2"]);
        _originX = Num.integers(m["originX"]);
        _originY = Num.integers(m["originY"]);
        _keyShift = Num.integer(m["keyShift"], 10);
        _west = Num.decimal(m["west"]);
        _south = Num.decimal(m["south"]);
        _east = Num.decimal(m["east"]);
        _north = Num.decimal(m["north"]);
        _centerLat = Num.decimal(m["centerLat"]);
        _centerLon = Num.decimal(m["centerLon"]);
        _dataBytes = Num.integer(m["storedBytes"], 0);
        var keys = m["blocks"];
        _blocks = Num.integers(keys);
        _blockCount = _blocks.size();
        // The four per-zoom arrays are read by slot, and `dataZoomFor` and
        // `blockLog2` read element 0 without checking, so a set that is empty
        // or shorter than dataZooms is an out-of-bounds read later rather than
        // a bad map now. Later means `Camera.initialize`, which `onStart` runs
        // outside the try that guards adopting the city -- so refuse it here.
        if (_zooms.size() == 0 || _log2s.size() < _zooms.size()
                || _originX.size() < _zooms.size()
                || _originY.size() < _zooms.size()) {
            refuse("zoom tables do not line up");
            return;
        }
        Diag.trace("pack.use " + _name + " z" + _zooms.size()
                   + " blocks:" + _blockCount);
        // Only now, so a malformed meta cannot leave the app half-switched.
        _downloaded = true;
    }

    //! Fall back to the built-in map, and say so.
    //!
    //! Silence here is the failure this module exists to avoid: the user picked
    //! a city, waited for it to download, and would otherwise get the sample
    //! map back with no explanation. `Diag` puts the reason on screen.
    function refuse(why) {
        _downloaded = false;
        Diag.note("city", why);
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
    //!
    //! Membership in the pack's own list, not merely a key in range. `blockKey`
    //! only checks that the block falls inside the `keyShift` grid, which is
    //! 1024x1024 keys; Berlin holds 20. Answer "yes" for the million that do
    //! not exist and each phantom costs `TileStore` a load slot from its
    //! per-frame budget before `blockBase64` returns null; with the budget
    //! spent on nothing the store reports itself throttled, `MapView` stays
    //! dirty and asks to be drawn again, and the next frame does the same. The
    //! app spins without ever yielding, which is what the watchdog kills:
    //! "Code Executed Too Long", every frame quick, the loop endless.
    function hasBlock(z, blockX, blockY) {
        if (!_downloaded) {
            return MapIndex.blockResource(z, blockX, blockY) != null;
        }
        var key = blockKey(z, blockX, blockY);
        if (key < 0) { return false; }
        for (var i = 0; i < _blocks.size(); i += 1) {
            if (_blocks[i] == key) { return true; }
        }
        return false;
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
