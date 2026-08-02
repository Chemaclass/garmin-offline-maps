import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! Persisted view state.
//!
//! Application.Storage on these devices is small (about 128 KB total, 8 KB per
//! value) and `setValue` transiently needs several times the payload in free
//! heap, so we keep this to a handful of scalars. Map data never goes here --
//! it lives in compiled-in resources.
module Settings {

    const KEY_NIGHT = "night";
    const KEY_HEADING_UP = "headingUp";
    const KEY_ZOOM = "zoom";
    const KEY_LAT = "lat";
    const KEY_LON = "lon";
    const KEY_PACK = "pack";

    function load(camera) {
        try {
            var night = Application.Storage.getValue(KEY_NIGHT);
            if (night != null) { camera.night = night; }

            var headingUp = Application.Storage.getValue(KEY_HEADING_UP);
            if (headingUp != null) { camera.headingUp = headingUp; }

            // toNumber(), because zoom reaches `1 << zoom` in Mercator and a
            // Float operand there raises an uncatchable UnexpectedTypeError.
            // Versions 0.3.0 to 0.3.2 could persist a Float here: defaultZoom
            // read it from a downloaded pack's JSON before Pack coerced its
            // fields. Upgrading from one of those would otherwise reproduce the
            // crash from a value already in storage.
            var zoom = Application.Storage.getValue(KEY_ZOOM);
            if (zoom != null && zoom >= Pack.minZoom() && zoom <= Pack.maxZoom()) {
                camera.zoom = zoom.toNumber();
            }

            // Only restore the centre if it belongs to the pack that is
            // currently compiled in -- otherwise we would start off the map.
            var pack = Application.Storage.getValue(KEY_PACK);
            if (pack != null && pack.equals(Pack.name())) {
                var lat = Num.decimal(Application.Storage.getValue(KEY_LAT));
                var lon = Num.decimal(Application.Storage.getValue(KEY_LON));
                // Inside the pack, not merely saved under its name.
                //
                // Matching the name only says the centre belongs to this map.
                // It does not say the value is usable, and a bad one is sticky:
                // whatever the camera held gets saved on exit and restored on
                // the next launch, so one implausible GPS fix parks the map off
                // the packed area for good and the city opens blank every time.
                // Out of range, keep the pack centre `Camera` already chose.
                if (lat >= Pack.south() && lat <= Pack.north()
                    && lon >= Pack.west() && lon <= Pack.east()) {
                    camera.centreOn(lat, lon);
                } else {
                    System.println("Settings: stored centre " + lat + "," + lon
                        + " is outside " + Pack.name() + ", using pack centre");
                }
            }
        } catch (ex) {
            System.println("Settings: could not read stored state");
        }
    }

    function save(camera) {
        try {
            Application.Storage.setValue(KEY_NIGHT, camera.night);
            Application.Storage.setValue(KEY_HEADING_UP, camera.headingUp);
            Application.Storage.setValue(KEY_ZOOM, camera.zoom);
            Application.Storage.setValue(KEY_LAT, camera.lat.toFloat());
            Application.Storage.setValue(KEY_LON, camera.lon.toFloat());
            Application.Storage.setValue(KEY_PACK, Pack.name());
        } catch (ex) {
            // Storage full or unavailable: the map still works, we just forget
            // where we were.
            System.println("Settings: could not persist state");
        }
    }
}
