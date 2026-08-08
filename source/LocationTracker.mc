import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;

//! Where the watch thinks you are, and which way you are facing.
//!
//! Heading comes from two places: the GPS course (only meaningful once you are
//! moving) and the magnetometer (works standing still, but not every device
//! exposes it). We prefer the compass and fall back to course.
class LocationTracker {

    //! Ignore GPS course below this speed, in m/s -- it is noise when still.
    const MIN_SPEED_FOR_COURSE = 1.0;

    hidden var _lat;
    hidden var _lon;
    hidden var _hasFix;
    hidden var _heading;
    hidden var _hasHeading;
    hidden var _onFix;
    hidden var _running;

    function initialize(onFix) {
        _lat = 0.0d;
        _lon = 0.0d;
        _hasFix = false;
        _heading = 0.0;
        _hasHeading = false;
        _onFix = onFix;
        _running = false;
    }

    function lat() { return _lat; }
    function lon() { return _lon; }
    function hasFix() { return _hasFix; }
    function hasHeading() { return _hasHeading; }
    function heading() { return _heading; }

    function start() {
        if (_running) { return; }
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
            _running = true;
        } catch (ex) {
            System.println("LocationTracker: positioning unavailable");
        }
        seedFromLastKnown();
    }

    //! Take the fix the watch already has, before waiting for a new one.
    //!
    //! `enableLocationEvents` only calls back when the receiver produces a
    //! *fresh* fix, which from cold is tens of seconds. The watch is almost
    //! always holding a recent one from another app or the last activity, and
    //! `getInfo` hands it over immediately. Without this the map sits on
    //! "Searching for GPS" for a minute on every launch while the answer was
    //! available the whole time.
    //!
    //! It is routed through `onPosition` rather than assigning the fields here,
    //! so a cached fix and a live one cannot drift apart in how they are
    //! handled.
    hidden function seedFromLastKnown() {
        try {
            var info = Position.getInfo();
            // QUALITY_NOT_AVAILABLE means the fields are unset rather than
            // stale, and would put the marker on null island.
            if (info != null && info.position != null
                && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
                var degrees = info.position.toDegrees();
                // Sanity-check before believing it. A watch with no usable fix
                // can still hand back a position: the simulator returns one out
                // at the corner of the world, and feeding that in recentred the
                // map off the packed area, so a downloaded city opened blank.
                // Latitude beyond the Mercator limit is not somewhere anyone is
                // standing.
                if (degrees[0] > Mercator.MAX_LAT || degrees[0] < -Mercator.MAX_LAT) {
                    System.println("LocationTracker: ignoring implausible cached fix "
                        + degrees[0] + "," + degrees[1]);
                    return;
                }
                onPosition(info);
            }
        } catch (ex) {
            // No positioning on this device, or none granted. The live
            // callback is still the main path.
        }
    }

    function stop() {
        if (!_running) { return; }
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        } catch (ex) {
            // nothing useful to do
        }
        _running = false;
    }

    //! Annotated because `Position.enableLocationEvents` types its callback
    //! parameter exactly; an untyped signature is rejected. See the note on
    //! API-boundary annotations in docs/DEVELOPMENT.md.
    function onPosition(info as Position.Info) as Void {
        if (info == null || info.position == null) { return; }
        var degrees = info.position.toDegrees();
        _lat = degrees[0];
        _lon = degrees[1];
        _hasFix = true;

        // Keep taking the GPS course while moving. Gating this on !_hasHeading
        // would latch the very first course forever on any watch whose compass
        // never reports.
        if (info.heading != null && info.speed != null
            && info.speed > MIN_SPEED_FOR_COURSE) {
            _heading = info.heading;
            _hasHeading = true;
        }

        if (_onFix != null) {
            _onFix.invoke();
        }
    }

    //! Push a position in as though the receiver had produced one.
    //!
    //! Exists for `DevTools`, which is the only caller: the simulator emits no
    //! fix at all, so the follow path cannot otherwise be exercised without a
    //! wrist outdoors. Goes through the same `_onFix` callback a real fix does,
    //! which is the point -- a harness that bypassed it would prove nothing.
    function injectFix(newLat, newLon) {
        _lat = newLat;
        _lon = newLon;
        _hasFix = true;
        if (_onFix != null) { _onFix.invoke(); }
    }

    //! Push a heading in, in radians. See `injectFix`.
    //!
    //! Sets `_hasHeading` so `pollHeading` compares against it and reports a
    //! change, which is what drives the heading-up redraw path.
    function injectHeading(radians) {
        _heading = radians;
        _hasHeading = true;
    }

    //! Poll the compass. Called on a timer rather than via sensor events so we
    //! are not woken up more often than the map can redraw.
    //! Returns true when the heading moved enough to be worth a repaint.
    function pollHeading() {
        var info = null;
        try {
            info = Sensor.getInfo();
        } catch (ex) {
            return false;
        }
        if (info == null || !(info has :heading) || info.heading == null) {
            return false;
        }
        var next = info.heading;
        var changed = !_hasHeading || angleDelta(next, _heading) > 0.087; // ~5 degrees
        _heading = next;
        _hasHeading = true;
        return changed;
    }

    hidden function angleDelta(a, b) {
        var d = a - b;
        while (d > Math.PI) { d -= 2 * Math.PI; }
        while (d < -Math.PI) { d += 2 * Math.PI; }
        return d < 0 ? -d : d;
    }
}
