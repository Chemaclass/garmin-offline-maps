import Toybox.Application;
import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.System;

//! Loads map blocks out of compiled-in jsonData resources and keeps a few
//! decoded ones around.
//!
//! Why this is careful: `Application.loadResource` is lazy, so a block only
//! costs heap while we hold it, but decoding one transiently needs the base64
//! String *and* the ByteArray at the same time. With 768 KB total on a Venu 3
//! the cache is capped by bytes, not by entry count, and eviction happens
//! before the next load rather than after.
class TileStore {

    //! Total decoded block bytes we are willing to hold.
    const DEFAULT_BUDGET = 90000;
    //! Headroom kept free for the next load: the packer targets 24 KB blocks,
    //! and decoding one needs the base64 String plus the ByteArray at once.
    const RESERVE_BYTES = 36000;

    //! Five parallel arrays, one cache entry per index. Typed because the hot
    //! paths below subscript them, and the checker will not index an untyped
    //! value; the counters underneath stay untyped like the rest of the app.
    hidden var _zoom as Array<Number>;
    hidden var _blockX as Array<Number>;
    hidden var _blockY as Array<Number>;
    hidden var _data as Array<ByteArray>;
    hidden var _used as Array<Number>;
    hidden var _tick;
    hidden var _bytes;
    hidden var _budget;

    function initialize(budget) {
        _zoom = [];
        _blockX = [];
        _blockY = [];
        _data = [];
        _used = [];
        _tick = 0;
        _bytes = 0;
        _budget = budget == null ? DEFAULT_BUDGET : budget;
    }


    //! Decoded block for these coordinates, or null when nothing is packed
    //! there (or when it would not fit in memory).
    function block(zoom, blockX, blockY) {
        for (var i = 0; i < _data.size(); i += 1) {
            if (_zoom[i] == zoom && _blockX[i] == blockX && _blockY[i] == blockY) {
                _tick += 1;
                _used[i] = _tick;
                return _data[i];
            }
        }

        if (!Pack.hasBlock(zoom, blockX, blockY)) {
            return null;
        }

        // Make room *before* loading. Decoding needs the base64 String and the
        // ByteArray alive at the same time, so arriving at the load with a full
        // cache is how you get a mid-pan out-of-memory.
        evictFor(RESERVE_BYTES);

        // The breadcrumb goes here rather than after the load, because the load
        // is the step that can kill the app outright: base64 decode needs the
        // String and the ByteArray alive together, and running out of memory
        // doing it is a Lang.Error that no catch below will see.
        if (Diag.tracing) {
            Diag.trace("block " + zoom + "/" + blockX + "/" + blockY);
        }

        var decoded = null;
        try {
            var payload = Pack.blockBase64(zoom, blockX, blockY);
            if (payload == null) {
                return null;
            }
            // A compiled-in block arrives as the one-element JSON array the
            // packer wrote; a downloaded one is the bare base64 string that
            // was stored. loadResource is also typed as a union of every
            // resource kind, hence the casts.
            var encoded = (payload instanceof Lang.Array)
                ? payload[0] as String
                : payload as String;
            decoded = StringUtil.convertEncodedString(encoded, {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
            });
        } catch (ex) {
            System.println("TileStore: could not load block " + zoom + "/" + blockX + "/" + blockY);
            return null;
        }

        if (!TileReader.isValid(decoded)) {
            return null;
        }

        evictFor(decoded.size());
        _zoom.add(zoom);
        _blockX.add(blockX);
        _blockY.add(blockY);
        _data.add(decoded);
        _tick += 1;
        _used.add(_tick);
        _bytes += decoded.size();
        return decoded;
    }

    //! Find the payload offset of one tile, or -1.
    function tileOffset(blockBytes, tileX, tileY, log2) {
        var localX = tileX - ((tileX >> log2) << log2);
        var localY = tileY - ((tileY >> log2) << log2);
        return TileReader.tileOffset(blockBytes, localX, localY);
    }

    hidden function evictFor(incoming) {
        while (_data.size() > 0 && _bytes + incoming > _budget) {
            var oldest = 0;
            for (var i = 1; i < _used.size(); i += 1) {
                if (_used[i] < _used[oldest]) { oldest = i; }
            }
            _bytes -= _data[oldest].size();
            _zoom = removeAt(_zoom, oldest);
            _blockX = removeAt(_blockX, oldest);
            _blockY = removeAt(_blockY, oldest);
            _data = removeAt(_data, oldest);
            _used = removeAt(_used, oldest);
        }
    }

    //! Array.remove() deletes by value, which is wrong when two blocks share a
    //! zoom or index, so rebuild by position instead.
    hidden function removeAt(list as Array, index) as Array {
        var out = new [list.size() - 1];
        var at = 0;
        for (var i = 0; i < list.size(); i += 1) {
            if (i != index) {
                out[at] = list[i];
                at += 1;
            }
        }
        return out;
    }

    function clear() {
        _zoom = [];
        _blockX = [];
        _blockY = [];
        _data = [];
        _used = [];
        _bytes = 0;
    }
}
