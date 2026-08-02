import Toybox.Graphics;
import Toybox.Lang;

//! Colours and stroke widths.
//!
//! Sixteen entries is the app's whole colour vocabulary: everything the
//! renderer draws comes from an array below, and slots 0..9 are a contract
//! with the packer. Sixteen is also what a paletted BufferedBitmap needs to
//! stay at 4 bits per pixel, but the off-screen buffer carries no palette,
//! that being the only way it can be drawn to at all, so the count no longer
//! decides the buffer's bit depth. docs/RENDERING.md has both halves.
module Palette {

    // Slots. Layer ids 0..9 come straight from the packer (see
    // tools/mappack/mappack/classify.py) and must line up with the first ten
    // entries of each palette.
    const SLOT_WATER = 0;
    const SLOT_GREEN = 1;
    const SLOT_BUILDING = 2;
    const SLOT_WATERWAY = 3;
    const SLOT_RAIL = 4;
    const SLOT_PATH = 5;
    const SLOT_MINOR = 6;
    const SLOT_TERTIARY = 7;
    const SLOT_PRIMARY = 8;
    const SLOT_MOTORWAY = 9;
    const SLOT_BACKGROUND = 10;
    const SLOT_TEXT = 11;
    const SLOT_DIM = 12;
    const SLOT_POSITION = 13;
    const SLOT_PANEL = 14;
    const SLOT_ACCENT = 15;

    const LAYER_COUNT = 10;

    //! AMOLED-friendly default: a black background costs almost no power.
    const NIGHT = [
        0x0A3055, // water
        0x123D1B, // green
        0x2B2B2B, // building
        0x1E5C8C, // waterway
        0x5A5A5A, // rail
        0x7A6440, // path
        0x8C8C8C, // minor road
        0xD4C27A, // tertiary / secondary
        0xFFAA00, // primary
        0xFF5500, // motorway
        0x000000, // background
        0xFFFFFF, // text
        0x999999, // dim text
        0x00B0FF, // position
        0x1A1A1A, // panel
        0x00FF88  // accent
    ];

    //! Daylight palette. Minor roads are mid-grey rather than the white a
    //! desktop map would use -- without casings, white on cream is invisible
    //! at arm's length in sunlight.
    const DAY = [
        0x9FC6E8, // water
        0xBFE0A8, // green
        0xD8D2C8, // building
        0x5B98C8, // waterway
        0x7A7A7A, // rail
        0xA07040, // path
        0x8C8C8C, // minor road
        0xE0B84C, // tertiary / secondary
        0xF08C28, // primary
        0xE04A18, // motorway
        0xF2EFE7, // background
        0x000000, // text
        0x555555, // dim text
        0x0066CC, // position
        0xFFFFFF, // panel
        0xAA0000  // accent
    ];

    //! Stroke width per layer, indexed [layer][0..1] for (far, near) zoom.
    //! "near" applies from ZOOM_DETAIL upwards.
    const ZOOM_DETAIL = 15;

    const WIDTH_FAR = [1, 1, 1, 1, 1, 1, 1, 2, 3, 4];
    const WIDTH_NEAR = [1, 1, 1, 2, 1, 1, 2, 3, 4, 5];

    //! Layers 0..2 are filled areas; the rest are strokes.
    function isArea(layer) {
        return layer <= SLOT_BUILDING;
    }

    //! Typed because callers index the result. Everything downstream that
    //! passes this array on carries the same annotation, so the checker can
    //! see a container all the way to the `colours[slot]` at the far end.
    function colours(night) as Array<Number> {
        return night ? NIGHT : DAY;
    }

    function penWidth(layer, displayZoom) {
        if (layer < 0 || layer >= LAYER_COUNT) { return 1; }
        return displayZoom >= ZOOM_DETAIL ? WIDTH_NEAR[layer] : WIDTH_FAR[layer];
    }
}
