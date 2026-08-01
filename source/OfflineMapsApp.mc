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
        _camera = new Camera();
        Settings.load(_camera);
        _store = new TileStore(null);
        _tracker = new LocationTracker(method(:onFix));
    }

    function getInitialView() {
        _view = new MapView(_camera, _store, _tracker);
        _tracker.start();

        _timer = new Timer.Timer();
        _timer.start(method(:onTick), HEADING_POLL_MS, true);

        return [_view, new MapDelegate(_view, _camera, _tracker)];
    }

    //! A new GPS fix arrived.
    function onFix() {
        if (_camera == null || _view == null) { return; }
        if (_camera.follow && _tracker.hasFix()) {
            _camera.centreOn(_tracker.lat(), _tracker.lon());
            _view.invalidate();
            WatchUi.requestUpdate();
        }
    }

    //! Annotated because `Timer.start` requires a `Method() as Void`.
    function onTick() as Void {
        if (_camera == null || _view == null || !_camera.headingUp) { return; }
        if (_tracker.pollHeading()) {
            _camera.heading = _tracker.heading();
            _view.invalidate();
            WatchUi.requestUpdate();
        }
    }

    function onStop(state) {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        if (_tracker != null) {
            _tracker.stop();
        }
        if (_camera != null) {
            Settings.save(_camera);
        }
    }
}
