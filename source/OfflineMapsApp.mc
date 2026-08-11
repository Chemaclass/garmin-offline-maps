import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Offline Maps -- a pannable, zoomable vector map that needs no phone,
//! no network and no subscription.
//!
//! The map itself is compiled into the app as jsonData resources by
//! `tools/mappack`; see docs/FORMAT.md for the layout and README.md for how to
//! build a pack for your own area.
class OfflineMapsApp extends Application.AppBase {

    //! How often to re-read the compass while in heading-up mode.
    const HEADING_POLL_MS = 1000;



    hidden var _camera;
    hidden var _store;
    hidden var _tracker;
    hidden var _view;
    hidden var _timer;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        // First, before anything that could fail again: if the previous run
        // died, its breadcrumb is still in storage and names the step. Reading
        // it here is the only chance to, because `Diag.arm` below starts
        // overwriting it.
        Diag.recoverCrash();

        // Safe mode still earns its keep with one map compiled in: the crumb
        // says the last run was killed, and saying so beats launching into
        // whatever did it and dying in the same place with nothing drawn.
        if (Diag.lastCrash != null) {
            System.println("safe mode after: " + Diag.lastCrash);
        } else {
            Diag.arm();
        }
        Diag.trace("startup.camera");
        _camera = new Camera();
        Settings.load(_camera);
        _store = new TileStore();
        _tracker = new LocationTracker(method(:onFix));
    }

    function getInitialView() {
        _view = new MapView(_camera, _store, _tracker);
        _tracker.start();

        _timer = new Timer.Timer();
        _timer.start(method(:onTick), HEADING_POLL_MS, true);

        // No-op unless DevTools.ENABLED. Feeds synthetic fixes and headings so
        // the follow path can be exercised at all; see DevTools.mc for why the
        // simulator cannot.
        DevTools.start(_tracker);

        return [_view, new MapDelegate(_view, _camera, _tracker)];
    }

    hidden function refreshAfterPackChange() {
        if (_store != null) { _store.clear(); }
        if (_camera != null) { _camera.resetToPack(); }
        if (_view != null) {
            _view.redrawFromScratch();
            WatchUi.requestUpdate();
        }
    }

    //! A new GPS fix arrived.
    //!
    //! Following it only while it is on the map. Otherwise downloading a city
    //! you are not standing in gives you a blank screen: the first fix drags
    //! the camera hundreds of kilometres off the packed area, and with the dark
    //! theme that is a black screen with one dim line of explanation on it. The
    //! map you asked for is right there, so show it. `drawPositionStatus` still
    //! says the marker is elsewhere.
    //! Standing still still produces a fix a second, and each one used to
    //! recentre the map and restart the render from scratch. The map is built
    //! over many frames, areas before lines, so a restart every second meant the
    //! areas pass finished and the lines pass never started: water and parks on
    //! screen and not one street, for as long as you stood there.
    //!
    //! No simulator run shows this. There is no fix there, so `onFix` returns at
    //! `hasFix` and the map completes in 18 frames with its roads on it. It
    //! needs a real receiver and a pack you are actually standing in, which is
    //! to say a wrist in Berlin.
    //!
    //! About 2 m. Jitter while standing still sits inside it, so a watch on a
    //! table stops touching the map at all.
    //!
    //! It used to be 17 m, because following meant a full redraw and one was
    //! rationed. It does not any more: `MapView.shiftBy` slides the buffer and
    //! only redraws once the offset has built up, so tracking can be as fine as
    //! the receiver is without costing anything.
    const FOLLOW_MIN_DEGREES = 0.00002;

    function onFix() {
        if (_camera == null || _view == null) { return; }
        if (!_camera.follow || !_tracker.hasFix()) { return; }
        if (!Camera.contains(_tracker.lat(), _tracker.lon())) { return; }
        var newLat = _tracker.lat();
        var newLon = _tracker.lon();
        if (!movedEnough(newLat, newLon)) { return; }

        // How far the map has to slide to keep showing the same ground under a
        // new centre. World units at the display zoom are screen pixels, which
        // is the same identity `Camera.panPixels` relies on.
        var dx = Mercator.lonToWorldX(_camera.lon, _camera.zoom)
                 - Mercator.lonToWorldX(newLon, _camera.zoom);
        var dy = Mercator.latToWorldY(_camera.lat, _camera.zoom)
                 - Mercator.latToWorldY(newLat, _camera.zoom);

        _camera.centreOn(newLat, newLon);

        // Slide if it fits, and only fall back to a redraw when it does not.
        // Deferred even then, for the same reason as the compass: a fix landing
        // mid-draw waits rather than throwing the picture away. See
        // `MapView.shiftBy` and `MapView.redrawWhenIdle`.
        if (!_view.shiftBy(dx, dy)) {
            _view.redrawWhenIdle();
        }
        WatchUi.requestUpdate();
    }

    //! Is the new fix far enough from where the map is already centred to be
    //! worth redrawing for? Longitude is not scaled by latitude on purpose:
    //! that makes the threshold tighter as you go north, which errs towards
    //! redrawing rather than towards a map that will not follow you.
    hidden function movedEnough(newLat, newLon) {
        var dLat = _camera.lat - newLat;
        var dLon = _camera.lon - newLon;
        if (dLat < 0) { dLat = -dLat; }
        if (dLon < 0) { dLon = -dLon; }
        return dLat > FOLLOW_MIN_DEGREES || dLon > FOLLOW_MIN_DEGREES;
    }

    //! Annotated because `Timer.start` requires a `Method() as Void`.
    function onTick() as Void {
        if (_camera == null || _view == null || !_camera.headingUp) { return; }
        if (_tracker.pollHeading()) {
            _camera.heading = _tracker.heading();
            // Not `redrawFromScratch`: this fires once a second on five degrees
            // change, which a wrist clears just by moving, and restarting the
            // render that often means it never reaches the pass that draws the
            // streets. See `MapView.redrawWhenIdle`.
            _view.redrawWhenIdle();
            WatchUi.requestUpdate();
        }
    }

    function onStop(state) {
        // A clean shutdown is not a crash: drop the breadcrumb so the next
        // launch does not report one.
        Diag.disarm();
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        DevTools.stop();
        // The GPS receiver is the one that costs real battery, so it goes off
        // first and unconditionally.
        if (_tracker != null) {
            _tracker.stop();
        }
        // A download still in flight holds a web request and its callbacks
        // open. Cancelling also clears the half-written city, which is what we
        // want: an incomplete pack must never be adopted on the next launch.
        // Before releasing anything the camera needs, and while it still holds
        // where you were looking.
        if (_camera != null) {
            Settings.save(_camera);
        }
        // Decoded blocks and the off-screen buffer, in that order. Neither
        // survives the app, but letting go explicitly means the next thing to
        // run is not waiting on a collector to work that out.
        if (_store != null) {
            _store.clear();
        }
        if (_view != null) {
            _view.release();
        }
    }
}
