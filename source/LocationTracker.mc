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
    hidden var _accuracy;
    hidden var _heading;
    hidden var _hasHeading;
    hidden var _onFix;
    hidden var _running;

    function initialize(onFix) {
        _lat = 0.0d;
        _lon = 0.0d;
        _hasFix = false;
        _accuracy = Position.QUALITY_NOT_AVAILABLE;
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
    function accuracy() { return _accuracy; }

    function start() {
        if (_running) { return; }
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
            _running = true;
        } catch (ex) {
            System.println("LocationTracker: positioning unavailable");
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
        if (info.accuracy != null) {
            _accuracy = info.accuracy;
        }

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
