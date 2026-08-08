import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;

//! Synthetic sensors, for the paths the simulator does not execute.
//!
//! **The simulator produces no GPS fix and no compass heading.**
//! `LocationTracker.onPosition` never fires, `hasFix()` stays false, `onFix`
//! returns at its first guard, and `pollHeading` never reports a change. So the
//! whole follow path is dead code under `make sim`, however many frames you
//! run, and "verified in the simulator" says nothing at all about it.
//!
//! Two bugs shipped through that gap in one month, both the same shape: a
//! repeating event calling `redrawFromScratch()`, which discards a
//! part-drawn map and begins again at the areas pass. The map then never
//! reaches the lines pass, and what you get is water and parks with no streets,
//! for as long as you stand there. Neither reproduced without a receiver.
//!
//! Both were found by patching `LocationTracker` by hand, running, and
//! reverting. This is that patch, kept, so the next one is a one-line change
//! rather than an act of archaeology.
//!
//! Watch `restarts` on the Stats overlay while this runs. Standing still it
//! must stay put. Climbing once a second is the bug.
module DevTools {

    //! Flip to true, rebuild, run. Off in anything shipped.
    //!
    //! A build constant rather than a menu item on purpose: a control that
    //! fakes your position is not something to leave within reach on a watch
    //! you might navigate with. If the bytes ever matter, the same code
    //! annotated `(:devtools)` and stripped with `monkeyc -x devtools` on the
    //! release build would cost nothing at all.
    const ENABLED = false;

    //! Matches `Position.LOCATION_CONTINUOUS`, which is what the app asks for.
    const FIX_INTERVAL_MS = 1000;

    //! Metres of wander, as degrees of latitude, roughly. Small on purpose:
    //! this is a watch sitting on a wrist that is not going anywhere, which is
    //! the case that broke. A fix that never moves would let a "has it moved
    //! far enough" guard suppress everything and hide the very thing under
    //! test.
    const JITTER_DEGREES = 0.00002d;

    //! Degrees of heading wander per tick. `pollHeading` reports a change past
    //! about five, and an arm clears that without trying.
    //!
    //! A whole number, and it has to be: `%` takes Number/Long, and a Float
    //! reaching it raises `UnexpectedTypeException`. This harness hit that on
    //! its first run, which is the trap docs/DEVELOPMENT.md describes, so the
    //! modulo stays in integer space and only the conversion to radians is
    //! floating point.
    const HEADING_STEP_DEGREES = 7;

    // Module state. Monkey C has no `hidden` at module scope, so the leading
    // underscore is the whole convention, as in Diag and Pack.
    var _timer = null;
    var _tracker = null;
    var _tick = 0;
    var _lat = 0.0d;
    var _lon = 0.0d;

    //! Begin feeding synthetic fixes centred on wherever the pack is.
    //!
    //! Centred on the pack, not on a hardcoded city: `onFix` drops any fix
    //! outside the packed area (`Camera.contains`), so a position somewhere
    //! else leaves the path just as dead as no position at all. That is a real
    //! trap; the first attempt at this harness used a fixed Berlin coordinate
    //! against a demo pack of somewhere else and looked exactly like success.
    function start(tracker) {
        if (!ENABLED || _timer != null) { return; }
        _tracker = tracker;
        _tick = 0;
        _lat = (Pack.north() + Pack.south()) / 2.0;
        _lon = (Pack.west() + Pack.east()) / 2.0;
        System.println("DevTools: synthetic fixes at "
                       + _lat.format("%.5f") + "," + _lon.format("%.5f"));
        _timer = new Timer.Timer();
        // `method(:x)` needs a class receiver; at module scope the callback has
        // to name its module explicitly.
        _timer.start(new Lang.Method(DevTools, :onTick), FIX_INTERVAL_MS, true);
    }

    function stop() {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        _tracker = null;
    }

    //! Annotated because `Timer.start` requires a `Method() as Void`.
    function onTick() as Void {
        if (_tracker == null) { return; }
        _tick += 1;
        // A three-step cycle rather than a random walk, so two runs are
        // comparable. Wandering off would eventually leave the pack and the
        // fixes would start being dropped, which looks like the harness
        // failing.
        var phase = _tick % 3;
        _tracker.injectFix(_lat + phase * JITTER_DEGREES,
                           _lon + phase * JITTER_DEGREES);
        var degrees = (_tick * HEADING_STEP_DEGREES) % 360;
        _tracker.injectHeading(degrees * Math.PI / 180.0);
    }
}
