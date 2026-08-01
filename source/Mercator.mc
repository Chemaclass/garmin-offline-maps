import Toybox.Lang;
import Toybox.Math;

//! Spherical Web Mercator (EPSG:3857) in slippy-map pixel space.
//!
//! The world at zoom z is `256 * 2^z` pixels across, origin top-left at
//! (-180, +85.0511). This is the same convention the packer uses, so a tile
//! index here always names the same tile the packer wrote.
module Mercator {

    const TILE_SIZE = 256;
    const MAX_LAT = 85.05112878d;
    const E = 2.718281828459045d;
    //! Circumference of the earth divided by 256 px -- metres per pixel at z0.
    const METRES_PER_PIXEL_Z0 = 156543.03392804097d;

    function ln(value) {
        return Math.log(value, E);
    }

    function worldSize(zoom) {
        return TILE_SIZE * (1 << zoom);
    }

    function lonToWorldX(lon, zoom) {
        return (lon + 180.0d) / 360.0d * worldSize(zoom);
    }

    function latToWorldY(lat, zoom) {
        var clamped = lat;
        if (clamped > MAX_LAT) { clamped = MAX_LAT; }
        if (clamped < -MAX_LAT) { clamped = -MAX_LAT; }
        var s = Math.sin(clamped * Math.PI / 180.0d);
        var y = 0.5d - ln((1.0d + s) / (1.0d - s)) / (4.0d * Math.PI);
        return y * worldSize(zoom);
    }

    function worldXToLon(x, zoom) {
        return x / worldSize(zoom) * 360.0d - 180.0d;
    }

    function worldYToLat(y, zoom) {
        var n = Math.PI - 2.0d * Math.PI * y / worldSize(zoom);
        return 180.0d / Math.PI * Math.atan(sinh(n));
    }

    //! Toybox.Math has no sinh.
    function sinh(x) {
        var ex = Math.pow(E, x);
        return (ex - 1.0d / ex) / 2.0d;
    }

    function metresPerPixel(lat, zoom) {
        return METRES_PER_PIXEL_Z0 * Math.cos(lat * Math.PI / 180.0d) / (1 << zoom);
    }

    //! 2^exponent for small signed exponents, as a Float.
    function pow2(exponent) {
        if (exponent >= 0) {
            return (1 << exponent).toFloat();
        }
        return 1.0 / (1 << (-exponent));
    }
}
