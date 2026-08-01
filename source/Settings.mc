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

            var zoom = Application.Storage.getValue(KEY_ZOOM);
            if (zoom != null && zoom >= Pack.minZoom() && zoom <= Pack.maxZoom()) {
                camera.zoom = zoom;
            }

            // Only restore the centre if it belongs to the pack that is
            // currently compiled in -- otherwise we would start off the map.
            var pack = Application.Storage.getValue(KEY_PACK);
            if (pack != null && pack.equals(Pack.name())) {
                var lat = Application.Storage.getValue(KEY_LAT);
                var lon = Application.Storage.getValue(KEY_LON);
                if (lat != null && lon != null) {
                    camera.centreOn(lat.toDouble(), lon.toDouble());
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
