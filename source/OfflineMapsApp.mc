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

    //! `cityId` values meaning "use the map compiled into the app".
    const CITY_BUILT_IN = "builtin";

    hidden var _camera;
    hidden var _store;
    hidden var _tracker;
    hidden var _view;
    hidden var _timer;
    hidden var _downloader;
    hidden var _downloadView;
    //! A city asked for in the settings that is not on the watch yet. Started
    //! from `onTick` rather than `getInitialView`, because a view cannot be
    //! pushed before the initial one exists.
    hidden var _pendingCity;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        // Choose the pack before the camera: `Camera.initialize` reads the
        // pack's centre and zoom range.
        _pendingCity = adoptStoredCity();
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

    // ---- choosing a city -------------------------------------------------

    hidden function wantedCity() {
        try {
            var id = Application.Properties.getValue("cityId");
            if (id == null || !(id instanceof Lang.String)) { return null; }
            var trimmed = id as String;
            if (trimmed.length() == 0 || trimmed.equals(CITY_BUILT_IN)) {
                return null;
            }
            return trimmed;
        } catch (ex) {
            return null;
        }
    }

    hidden function baseUrl() {
        try {
            var url = Application.Properties.getValue("packBaseUrl");
            if (url instanceof Lang.String && (url as String).length() > 0) {
                return url;
            }
        } catch (ex) {
            // fall through to the built-in default
        }
        return null;
    }

    //! Point `Pack` at whatever is already on the watch. Returns the city that
    //! still needs downloading, or null when nothing does.
    hidden function adoptStoredCity() {
        var wanted = wantedCity();
        if (wanted == null) {
            Pack.use(null);
            return null;
        }
        if (CityStore.isComplete(wanted)) {
            Pack.use(CityStore.meta());
            return null;
        }
        // Asked for a city we do not have. Keep drawing the built-in map until
        // the download finishes rather than showing nothing.
        Pack.use(null);
        return wanted;
    }

    //! Garmin Connect wrote new settings. The city may have changed.
    function onSettingsChanged() {
        _pendingCity = adoptStoredCity();
        refreshAfterPackChange();
    }

    hidden function startDownload(city) {
        var url = baseUrl();
        if (url == null || _downloader != null) { return; }

        _downloadView = new DownloadView(city);
        _downloader = new CityDownloader(url, city, method(:onDownloadProgress),
                                         method(:onDownloadDone));
        WatchUi.pushView(_downloadView, new DownloadDelegate(_downloader),
                         WatchUi.SLIDE_UP);
        _downloader.start();
    }

    function onDownloadProgress(done, total) {
        if (_downloadView != null) { _downloadView.onProgress(done, total); }
    }

    function onDownloadDone(ok) {
        _downloader = null;
        if (ok) {
            adoptStoredCity();
            refreshAfterPackChange();
            if (_downloadView != null) {
                WatchUi.popView(WatchUi.SLIDE_DOWN);
                _downloadView = null;
            }
        } else if (_downloadView != null) {
            _downloadView.onFailed();
        }
    }

    //! The map underneath changed, so nothing cached still applies.
    hidden function refreshAfterPackChange() {
        if (_store != null) { _store.clear(); }
        if (_camera != null) {
            _camera.zoom = Camera.defaultZoom();
            _camera.jumpToPackCentre();
        }
        if (_view != null) {
            _view.invalidate();
            WatchUi.requestUpdate();
        }
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
        if (_pendingCity != null) {
            var city = _pendingCity;
            _pendingCity = null;
            startDownload(city);
            return;
        }
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
