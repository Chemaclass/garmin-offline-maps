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

    //! Long enough to leave the web-request callback and let its response go,
    //! short enough that the map appears to come back straight away.
    const SWITCH_DELAY_MS = 150;

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
    //! A downloaded city waiting to be adopted on the next tick. See
    //! `onDownloadDone` for why it is not adopted in the callback.
    hidden var _pendingAdopt;
    hidden var _switchTimer;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        // First, before anything that could fail again: if the previous run
        // died, its breadcrumb is still in storage and names the step. Reading
        // it here is the only chance to, because `Diag.arm` below starts
        // overwriting it.
        Diag.recoverCrash();

        // Safe mode. The crumb says the last run was killed, so do not walk
        // back into whatever killed it: leave the downloaded city alone and
        // start on the built-in map.
        //
        // Without this the diagnostic cannot work at all: the step that dies is
        // reached from `onStart`, so every launch dies in the same place and
        // the message naming the cause never survives to be drawn.
        //
        // The city stays in storage. It is not deleted, because the user paid
        // for that download and may want to retry it from the menu; it is only
        // not adopted automatically.
        if (Diag.lastCrash != null) {
            _pendingCity = null;
            _pendingAdopt = false;
            Pack.use(null);
            System.println("safe mode after: " + Diag.lastCrash);
        } else {
            Diag.arm();
            Diag.trace("startup.adopt");
            // Choose the pack before the camera: `Camera.initialize` reads the
            // pack's centre and zoom range.
            //
            // Guarded for the same reason as `onDownloadDone`: a stored city
            // that cannot be adopted must not stop the app starting. Without
            // this, one bad download bricks every launch until the app is
            // reinstalled.
            try {
                _pendingCity = adoptStoredCity();
            } catch (ex) {
                // Recorded, not just printed: this silently replaces the city
                // the user chose with the built-in map, and println only
                // reaches a machine running monkeydo.
                Diag.record("startup", ex);
                _pendingCity = null;
                Pack.use(null);
                // No guard: `CityStore.clear` handles its own Storage failures
                // and returns nothing to check.
                CityStore.clear();
            }
        }
        _pendingAdopt = false;
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

        // `pickCity` goes down with the delegate, the same way `onFix` goes to
        // the tracker and `onCityChosen` to the picker. Handed down rather than
        // reached up for: `MapMenuDelegate.onSelect` names the cycle this
        // avoids, and is where the temptation to close it lives.
        return [_view, new MapDelegate(_view, _camera, _tracker, method(:pickCity))];
    }

    // ---- choosing a city -------------------------------------------------

    //! The city the settings ask for, or null for the built-in map.
    //!
    //! Two guards rather than one around both calls. Syncing the phone dropdown
    //! and reading the city id fail independently, and a failure in the first
    //! must not discard the second: null here means "run the built-in map", so
    //! one unreadable dropdown property used to throw away a downloaded city
    //! that was perfectly readable.
    hidden function wantedCity() {
        try {
            adoptPhoneChoice();
        } catch (ex) {
            Diag.record("settings", ex);
        }
        try {
            // Normalised because the watch may have written this, and because
            // older builds exposed it as free text: typing "Berlin" would
            // otherwise 404 with nothing to explain why.
            var id = CityStore.normalize(Application.Properties.getValue("cityId"));
            if (id == null || id.equals(CITY_BUILT_IN)) { return null; }
            return id;
        } catch (ex) {
            // Silence here is a mystery on the wrist: the chosen city is
            // ignored and the built-in map appears with nothing said.
            Diag.record("settings", ex);
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
        // before these properties existed throws InvalidKeyException here
        // instead, which the caller records and steps over -- the city id is
        // still read, so the map does not change.
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
            // Not fatal: the download still happens, the phone just disagrees
            // about which city is active. Printed rather than recorded --
            // `Diag` has one slot and is drawn on the map, and a cosmetic
            // phone/watch mismatch is not worth the space a real failure needs.
            System.println("could not write cityId: " + ex.getErrorMessage());
        }
        // Guarded because this is a callback. Nothing above a picker callback
        // catches anything, so a throw here ends the app rather than the
        // action: black screen, Connect IQ error icon, from choosing a city.
        // Adopting the city is the risky half; falling through to download it
        // again is always survivable.
        try {
            if (CityStore.isComplete(slug)) {
                Pack.use(CityStore.meta());
                refreshAfterPackChange();
                return;
            }
        } catch (ex) {
            Diag.record("city", ex);
        }
        startDownload(slug);
    }

    //! Where the catalogue lives, or null when there is nowhere to fetch from.
    //!
    //! There is no default in code to fall back on: the working one lives in
    //! `resources/settings/properties.xml`, so getting null here means the
    //! setting is missing or blank. Both callers then do nothing at all, and a
    //! menu entry that does nothing needs to say why -- hence the record.
    hidden function baseUrl() {
        try {
            var url = Application.Properties.getValue("packBaseUrl");
            if (url instanceof Lang.String && url.length() > 0) {
                return url;
            }
        } catch (ex) {
            Diag.record("catalogue", ex);
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
            Diag.record("settings", ex);
            revertToBuiltIn();
        }
    }

    hidden function startDownload(city) {
        var url = baseUrl();
        if (url == null || _downloader != null) { return; }

        // Crumbs from here until a frame is drawn: this is the stretch every
        // reported crash has fallen inside.
        Diag.arm();
        Diag.trace("dl.start " + city);

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
        // Deferred out of this callback rather than done in it.
        //
        // This runs inside the web-request callback that delivered the last
        // block, so the HTTP response, that block's base64 string and the
        // download view are all still referenced. Adopting the city allocates
        // the metadata, and the render straight after allocates the off-screen
        // buffer plus every visible block at once. That is the heaviest moment
        // in the app's life, and doing it here stacks it on top of the
        // download's own peak.
        //
        // `docs/DEVICES.md` records a 90 KB store needing roughly 400 KB free,
        // so the headroom this costs is not a rounding error. An
        // `OutOfMemoryError` is a `Lang.Error`: no catch sees it, and the watch
        // shows the Connect IQ error screen. Popping the view first and
        // switching on a short timer lets the response and the view go before
        // any of it is asked for.
        if (_downloadView != null) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _downloadView = null;
        }
        _pendingAdopt = true;
        _switchTimer = new Timer.Timer();
        _switchTimer.start(method(:onSwitchTick), SWITCH_DELAY_MS, false);
    }

    //! Adopt the freshly downloaded city, one tick after the download callback.
    //!
    //! Annotated because `Timer.start` requires a `Method() as Void`.
    function onSwitchTick() as Void {
        _switchTimer = null;
        if (!_pendingAdopt) { return; }
        _pendingAdopt = false;
        Diag.trace("switch.adopt");
        try {
            adoptStoredCity();
            refreshAfterPackChange();
        } catch (ex) {
            // The download view is already gone, so the message goes on the map
            // rather than on the download screen.
            Diag.record("city", ex);
            revertToBuiltIn();
        }
    }

    //! Go back to the map compiled into the app, and forget the city that
    //! would not load. Leaving it stored would reproduce the failure on every
    //! launch, which is worse than losing the download.
    hidden function revertToBuiltIn() {
        // `CityStore.clear` handles its own Storage failures, so only the
        // property write can throw and only it is guarded.
        CityStore.clear();
        try {
            Application.Properties.setValue("cityId", "");
        } catch (ex) {
            // The failing city stays in the settings and gets adopted again on
            // the next launch, so this is worth saying. Printed, not recorded:
            // every caller has already put the cause that brought us here in
            // `Diag`, and there is only one slot.
            System.println("could not clear cityId: " + ex.getErrorMessage());
        }
        Pack.use(null);
        // Reverting *is* a pack change, so it takes the same path. It used to
        // repeat those four steps here minus the `requestUpdate`, which meant
        // the map only caught up on the next tick.
        refreshAfterPackChange();
    }

    //! The map underneath changed, so nothing cached still applies.
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
        if (_pendingCity != null) {
            var city = _pendingCity;
            _pendingCity = null;
            startDownload(city);
            return;
        }
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
        if (_switchTimer != null) {
            _switchTimer.stop();
            _switchTimer = null;
        }
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
        if (_downloader != null) {
            _downloader.cancel();
            _downloader = null;
        }
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
        _downloadView = null;
    }
}
