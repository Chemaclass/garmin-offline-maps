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
        //
        // Guarded for the same reason as `onDownloadDone`: a stored city that
        // cannot be adopted must not stop the app starting. Without this, one
        // bad download bricks every launch until the app is reinstalled.
        try {
            _pendingCity = adoptStoredCity();
        } catch (ex) {
            System.println("stored city unusable: " + ex.getErrorMessage());
            _pendingCity = null;
            Pack.use(null);
            try { CityStore.clear(); } catch (inner) { }
        }
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
            adoptPhoneChoice();
            // Normalised because the watch may have written this, and because
            // older builds exposed it as free text: typing "Berlin" would
            // otherwise 404 with nothing to explain why.
            var id = CityStore.normalize(Application.Properties.getValue("cityId"));
            if (id == null || id.equals(CITY_BUILT_IN)) { return null; }
            return id;
        } catch (ex) {
            return null;
        }
    }

    //! Turn the phone's dropdown selection into the slug the app runs on.
    //!
    //! Connect IQ list settings store a number, so the dropdown gives an index
    //! into `CityList`. `citySeen` records the last index acted on, which is
    //! what distinguishes "the phone changed it" from "the watch picked a city
    //! that happens not to be in this build's dropdown". Without it, a city
    //! chosen on the watch would be reverted by the stale dropdown value on the
    //! next settings read.
    hidden function adoptPhoneChoice() {
        // No null guard: `Properties.getValue` is typed non-null for a declared
        // property and the checker rejects the dead branch. An install from
        // before these properties existed would throw here instead, which the
        // caller's try/catch turns into "keep the current map".
        var index = Application.Properties.getValue("cityIndex");
        var seen = Application.Properties.getValue("citySeen");
        if (index.equals(seen)) { return; }

        var slug = CityList.slugAt(index);
        Application.Properties.setValue("cityId", slug == null ? "" : slug);
        Application.Properties.setValue("citySeen", index);
    }

    //! Offer the published catalogue on the watch.
    function pickCity() {
        var url = baseUrl();
        if (url == null) { return; }
        var picker = new CityPicker(url, method(:onCityChosen));
        picker.start();
    }

    //! A city was chosen from the on-watch picker.
    function onCityChosen(slug) {
        // Keep the phone settings in step, so Garmin Connect shows what the
        // watch is actually using.
        try {
            Application.Properties.setValue("cityId", slug);
            // Keep the dropdown in step, and mark the index as already acted
            // on so `adoptPhoneChoice` does not undo this on the next read.
            // A city published since this build was made is not in the
            // dropdown, and indexOf gives 0 for it: the phone then shows the
            // built-in entry while the watch runs the downloaded city, which
            // is the least wrong of the available answers.
            var index = CityList.indexOf(slug);
            Application.Properties.setValue("cityIndex", index);
            Application.Properties.setValue("citySeen", index);
        } catch (ex) {
            // Not fatal: the download still happens, the phone just disagrees.
            System.println("could not write cityId");
        }
        if (CityStore.isComplete(slug)) {
            Pack.use(CityStore.meta());
            refreshAfterPackChange();
            return;
        }
        startDownload(slug);
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
        try {
            _pendingCity = adoptStoredCity();
            refreshAfterPackChange();
        } catch (ex) {
            System.println("settings change failed: " + ex.getErrorMessage());
            revertToBuiltIn();
        }
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
        if (!ok) {
            if (_downloadView != null) { _downloadView.onFailed(); }
            return;
        }
        // Everything from here runs inside a web-request callback and swaps the
        // map out from under a live view. An exception escaping a callback is
        // not caught by anything above it: the app dies and the watch shows the
        // Connect IQ error screen, which is what a first download did on real
        // hardware. Falling back to the built-in map is always survivable, so
        // prefer that to taking the whole app down.
        var switched = false;
        try {
            adoptStoredCity();
            refreshAfterPackChange();
            switched = true;
        } catch (ex) {
            System.println("switch to downloaded city failed: "
                + ex.getErrorMessage());
            revertToBuiltIn();
        }
        if (_downloadView != null) {
            if (switched) {
                WatchUi.popView(WatchUi.SLIDE_DOWN);
                _downloadView = null;
            } else {
                _downloadView.onFailed();
            }
        }
    }

    //! Go back to the map compiled into the app, and forget the city that
    //! would not load. Leaving it stored would reproduce the failure on every
    //! launch, which is worse than losing the download.
    hidden function revertToBuiltIn() {
        try {
            CityStore.clear();
            Application.Properties.setValue("cityId", "");
        } catch (ex) {
            // Nothing further to try.
        }
        Pack.use(null);
        if (_store != null) { _store.clear(); }
        if (_camera != null) {
            _camera.zoom = Camera.defaultZoom();
            _camera.jumpToPackCentre();
        }
        if (_view != null) { _view.invalidate(); }
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
