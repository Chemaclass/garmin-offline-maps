import Toybox.Lang;
import Toybox.Math;

//! Where we are looking: centre, zoom, orientation.
//!
//! The centre is kept as latitude/longitude rather than world pixels so that
//! changing zoom never accumulates rounding error, and so a saved position
//! survives a rebuild with a different pack.
class Camera {

    var lat;
    var lon;
    var zoom;
    //! true = map turns with you, false = north stays up
    var headingUp;
    //! radians, clockwise from north
    var heading;
    //! true = recentre on every GPS fix
    var follow;
    var night;

    function initialize() {
        lat = Pack.centerLat();
        lon = Pack.centerLon();
        zoom = defaultZoom();
        headingUp = false;
        heading = 0.0;
        follow = true;
        night = true;
    }

    //! Start in the middle of the packed zoom range rather than at the top:
    //! the highest zoom is the slowest to render and the least useful for
    //! getting your bearings when the app opens.
    static function defaultZoom() {
        var zooms = Pack.dataZooms();
        var mid = zooms[zooms.size() / 2];
        if (mid > Pack.maxZoom()) { mid = Pack.maxZoom(); }
        if (mid < Pack.minZoom()) { mid = Pack.minZoom(); }
        // Belt and braces: zoom ends up in `1 << zoom`, and a Float there is
        // an uncatchable error rather than a wrong number. Pack already
        // coerces, so this only matters if a future caller does not.
        return mid.toNumber();
    }

    //! Effective rotation applied to the map, in radians.
    function rotation() {
        return headingUp ? heading : 0.0;
    }

    function zoomIn() {
        if (zoom < Pack.maxZoom()) {
            zoom += 1;
            return true;
        }
        return false;
    }

    function zoomOut() {
        if (zoom > Pack.minZoom()) {
            zoom -= 1;
            return true;
        }
        return false;
    }

    function centreOn(newLat, newLon) {
        lat = newLat;
        lon = newLon;
    }

    //! Drag the map by a screen-pixel delta. The content follows the finger,
    //! so the centre moves the opposite way; the delta is un-rotated first so
    //! panning feels right in heading-up mode too.
    function panPixels(screenDx, screenDy) {
        var theta = rotation();
        var worldDx = screenDx;
        var worldDy = screenDy;
        if (theta != 0.0) {
            var c = Math.cos(theta);
            var s = Math.sin(theta);
            worldDx = screenDx * c - screenDy * s;
            worldDy = screenDx * s + screenDy * c;
        }
        var x = Mercator.lonToWorldX(lon, zoom) - worldDx;
        var y = Mercator.latToWorldY(lat, zoom) - worldDy;
        lon = Mercator.worldXToLon(x, zoom);
        lat = Mercator.worldYToLat(y, zoom);
        clampToWorld();
    }

    hidden function clampToWorld() {
        if (lat > 85.0d) { lat = 85.0d; }
        if (lat < -85.0d) { lat = -85.0d; }
        if (lon > 180.0d) { lon -= 360.0d; }
        if (lon < -180.0d) { lon += 360.0d; }
    }

    //! Is this position inside the packed region? Static because the overlay
    //! asks it about the GPS fix, not about the camera.
    static function contains(someLat, someLon) {
        return someLon >= Pack.west() && someLon <= Pack.east()
            && someLat >= Pack.south() && someLat <= Pack.north();
    }

    //! Is the centre inside the packed region?
    function insidePack() {
        return contains(lat, lon);
    }

    function jumpToPackCentre() {
        lat = Pack.centerLat();
        lon = Pack.centerLon();
    }

    function metresPerPixel() {
        return Mercator.metresPerPixel(lat, zoom);
    }
}
