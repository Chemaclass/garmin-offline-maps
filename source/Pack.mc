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
    //! The keys this pack actually holds. Kept, not just counted: see
    //! `hasBlock`.

    //! Fall back to the built-in map, and say so.
    //!
    //! Silence here is the failure this module exists to avoid: the user picked
    function name() {
        return MapIndex.PACK_NAME;
    }

    function attribution() {
        return MapIndex.ATTRIBUTION;
    }

    function minZoom() {
        return MapIndex.MIN_ZOOM;
    }

    function maxZoom() {
        return MapIndex.MAX_ZOOM;
    }

    function dataZooms() as Array<Number> {
        return MapIndex.DATA_ZOOMS;
    }

    function west()  { return MapIndex.WEST; }
    function south() { return MapIndex.SOUTH; }
    function east()  { return MapIndex.EAST; }
    function north() { return MapIndex.NORTH; }

    function centerLat() {
        return MapIndex.CENTER_LAT;
    }

    function centerLon() {
        return MapIndex.CENTER_LON;
    }

    function blockCount() {
        return MapIndex.BLOCK_COUNT;
    }

    //! Bytes the map occupies. Compiled in that is resource bytes; downloaded
    //! it is what sits in Storage, which is base64 and so about a third larger.
    function dataBytes() {
        return MapIndex.DATA_BYTES;
    }

    //! Best available data zoom for a display zoom.
    function dataZoomFor(displayZoom) {
        return MapIndex.dataZoomFor(displayZoom);
    }

    function blockLog2(z) {
        return MapIndex.blockLog2(z);
    }

    //! Decoded bytes of the block owning (blockX, blockY) at zoom z, or null.
    //!
    //! A jsonData resource for `TileStore` to decode.
    function blockBase64(z, blockX, blockY) {
        var resource = MapIndex.blockResource(z, blockX, blockY);
        return resource == null ? null : Application.loadResource(resource);
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
        return MapIndex.blockResource(z, blockX, blockY) != null;
    }

}
