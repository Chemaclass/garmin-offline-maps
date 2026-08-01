import Toybox.Lang;

//! Constants shared by the reader and the renderer.
//!
//! These live in a module rather than in the class so that `TileReader`'s
//! static helpers can see them without depending on how Monkey C scopes class
//! constants.
module MapFormat {
    const MAGIC = 0x4D;             // 'M'
    const VERSION = 1;
    const HEADER_BYTES = 9;
    const DIRECTORY_ENTRY_BYTES = 4;

    const GEOM_POLYLINE = 0;
    const GEOM_POLYGON = 1;
}

//! Cursor over a MapPack block.
//!
//! This is the exact counterpart of `tools/mappack/mappack/decode.py`; the
//! Python test suite proves the two agree on every fixture byte. If you change
//! one, change the other.
//!
//! Block layout:
//!   u8  magic 'M'      u8 version   u8 zoom   u8 blockLog2
//!   u16 blockX         u16 blockY   u8 tileCount
//!   tileCount x (u8 localX, u8 localY, u16 payloadOffset)
//!   ... tile payloads ...
//!
//! Tile payload:
//!   u8 layerCount
//!   layerCount x (u8 layerId, u16 layerBytes, u8 featureCount, features...)
//!   feature: u8 geomType, uvarint pointCount, pointCount x (svarint dx, dy)
//!
//! Layer ids ascend in draw order and `layerBytes` lets the renderer jump over
//! a layer without decoding it, which is what makes the two-pass draw (all
//! areas, then all strokes) affordable.
class TileReader {

    //! `bytes` and the `block` parameters below are the one typed thing in this
    //! file. Every read here is a subscript, and the checker cannot index an
    //! untyped value -- one annotation per container kills the warning for the
    //! whole reader. The arithmetic stays untyped, as everywhere else.
    var bytes as ByteArray;
    var pos;

    function initialize(byteArray as ByteArray, offset) {
        bytes = byteArray;
        pos = offset;
    }

    function u8() {
        var value = bytes[pos];
        pos += 1;
        return value;
    }

    function u16() {
        var value = bytes[pos] | (bytes[pos + 1] << 8);
        pos += 2;
        return value;
    }

    //! LEB128: seven payload bits per byte, high bit means "more follows".
    //!
    //! Written with the continuation bit as the loop condition rather than a
    //! `while (true)` with an inner return: the compiler cannot prove the latter
    //! ever returns, and rejects it.
    function uvarint() {
        var result = 0;
        var shift = 0;
        var more = true;
        while (more) {
            var b = bytes[pos];
            pos += 1;
            result = result | ((b & 0x7F) << shift);
            more = (b & 0x80) != 0;
            shift += 7;
        }
        return result;
    }

    //! Zigzag: small negative deltas stay one byte wide.
    function svarint() {
        var value = uvarint();
        return (value >> 1) ^ -(value & 1);
    }

    // ---- static helpers over a whole block ------------------------------

    static function isValid(block as ByteArray?) {
        return block != null
            && block.size() > MapFormat.HEADER_BYTES
            && block[0] == MapFormat.MAGIC
            && block[1] == MapFormat.VERSION;
    }

    static function blockZoom(block as ByteArray) {
        return block[2];
    }

    static function blockLog2(block as ByteArray) {
        return block[3];
    }

    static function tileCount(block as ByteArray) {
        return block[8];
    }

    //! Byte offset of one tile's payload inside the block, or -1 when the
    //! packer wrote nothing for that tile (open water, say).
    static function tileOffset(block as ByteArray, localX, localY) {
        var count = block[8];
        var at = MapFormat.HEADER_BYTES;
        for (var i = 0; i < count; i += 1) {
            if (block[at] == localX && block[at + 1] == localY) {
                return block[at + 2] | (block[at + 3] << 8);
            }
            at += MapFormat.DIRECTORY_ENTRY_BYTES;
        }
        return -1;
    }
}
