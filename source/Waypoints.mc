import Toybox.Application;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! Pins you drop on the map, and the way back to them.
//!
//! The offline case this serves: you parked somewhere, or pitched a tent, and
//! want to find it again without a phone.
//!
//! **Stored as scaled integers, not degrees.** A value coming back out of
//! `Application.Storage` is exactly the boundary `Num` exists for: a `Float`
//! reaching `<<` or `>>` raises a `Lang.Error`, which no `catch` receives.
//! Fixed point at 1e-6 degrees keeps everything a `Number` end to end, is worth
//! about 11 cm, and lets `Num.integers` do the checking, which is all-or-nothing
//! and therefore cannot marry one pin's latitude to another's longitude.
//!
//! The list is flat: `[lat, lon, lat, lon, ...]`. A list of pairs would be a
//! nested array to validate and allocate, and this is read on every frame that
//! draws the overlay.
module Waypoints {

    //! Its own key, deliberately not one of CityStore's. `CityStore.clear()`
    //! runs when a download fails and deletes `cb*`, `cityMeta` and `citySlug`
    //! by name, so pins survive a city that did not. They are the one thing in
    //! storage the user made rather than downloaded.
    const KEY = "waypoints";

    //! Degrees per stored unit: 1e-6, about 11 cm. Well inside GPS error, and
    //! a latitude of 90 scales to 90,000,000, comfortably inside a 32-bit
    //! signed `Number`.
    const SCALE = 1000000;

    //! Pins kept, oldest dropped first past this.
    //!
    //! Storage is ~128 KB shared with a downloaded city, and Berlin already
    //! takes ~91 KB of it, so this stays small on purpose. 24 pins is 48
    //! numbers, which is nothing; the cap is really about the overlay, which
    //! walks the whole list every frame it draws.
    const MAX = 24;

    //! Metres per radian of latitude.
    const EARTH_RADIUS_M = 6371000.0;

    //! The list, held in memory between writes.
    //!
    //! Not an optimisation for its own sake. The overlay asks for pins on every
    //! frame it draws, and through more than one path: the markers, the nearest
    //! one, and the distance to it. Reading storage each time would be four
    //! reads a frame for data that changes when you press a button, on a device
    //! where storage access is among the most expensive things an app can do.
    //!
    //! Null means "not read yet", which is distinct from an empty list meaning
    //! "read, and there are none".
    var _cache = null;

    //! Every stored pin, flat. Empty when there are none, or when what came
    //! back was not a list of numbers.
    function all() as Array<Number> {
        if (_cache != null) { return _cache as Array<Number>; }
        try {
            _cache = Num.integers(Application.Storage.getValue(KEY));
        } catch (ex) {
            // Storage can throw on a corrupt value. No pins is a survivable
            // answer; taking the app down over it is not. Cached as empty so
            // the failing read is not repeated every frame.
            System.println("Waypoints: could not read");
            _cache = [];
        }
        return _cache as Array<Number>;
    }

    function count() {
        return all().size() / 2;
    }

    //! Drop a pin. Returns false when it could not be stored.
    function add(lat, lon) {
        var pins = all();
        // Drop from the front so the newest always survives: someone at the cap
        // who drops a pin means the new one, not a refusal.
        while (pins.size() >= MAX * 2) {
            pins = pins.slice(2, null) as Array<Number>;
        }
        pins.add((lat * SCALE).toNumber());
        pins.add((lon * SCALE).toNumber());
        try {
            Application.Storage.setValue(KEY, pins);
            _cache = pins;
            return true;
        } catch (ex) {
            // Full storage is the likely cause, and a downloaded city is what
            // filled it. Worth saying rather than failing silently, because the
            // pin simply not appearing looks like a broken button.
            //
            // Drop the cache rather than keeping the list that failed to store:
            // it would show a pin on the map that is not saved, and would be
            // gone at the next launch with no explanation.
            System.println("Waypoints: could not save");
            _cache = null;
            return false;
        }
    }

    function clear() {
        try {
            Application.Storage.deleteValue(KEY);
            _cache = [];
        } catch (ex) {
            System.println("Waypoints: could not clear");
            _cache = null;
        }
    }

    function latAt(pins as Array<Number>, index) {
        return pins[index * 2] / (SCALE * 1.0d);
    }

    function lonAt(pins as Array<Number>, index) {
        return pins[index * 2 + 1] / (SCALE * 1.0d);
    }

    //! Metres between two positions, flat-earth.
    //!
    //! Equirectangular rather than haversine on purpose. Over the few
    //! kilometres a pack covers the error is under half a percent, and this is
    //! four trig calls fewer on a watch whose watchdog counts interpreted
    //! instructions.
    function distance(fromLat, fromLon, toLat, toLon) {
        var latRad = fromLat * Math.PI / 180.0;
        var dy = (toLat - fromLat) * Math.PI / 180.0 * EARTH_RADIUS_M;
        var dx = (toLon - fromLon) * Math.PI / 180.0 * EARTH_RADIUS_M
                 * Math.cos(latRad);
        return Math.sqrt(dx * dx + dy * dy);
    }

    //! Compass bearing to a position, in radians clockwise from north.
    function bearing(fromLat, fromLon, toLat, toLon) {
        var latRad = fromLat * Math.PI / 180.0;
        var dy = (toLat - fromLat);
        var dx = (toLon - fromLon) * Math.cos(latRad);
        return Math.atan2(dx, dy);
    }

    //! Index of the pin closest to a position, or -1 when there are none.
    function nearest(lat, lon) {
        var pins = all();
        var best = -1;
        var bestDistance = 0.0;
        for (var i = 0; i < pins.size() / 2; i += 1) {
            var d = distance(lat, lon, latAt(pins, i), lonAt(pins, i));
            if (best < 0 || d < bestDistance) {
                best = i;
                bestDistance = d;
            }
        }
        return best;
    }
}
