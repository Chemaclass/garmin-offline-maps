import Toybox.Lang;
import Toybox.WatchUi;

//! Touch and key handling for the map screen.
//!
//! This extends `InputDelegate` rather than `BehaviorDelegate` on purpose: a
//! BehaviorDelegate turns swipes into page/back behaviours, which would eat
//! exactly the gestures we need for panning.
class MapDelegate extends WatchUi.InputDelegate {

    hidden var _view;
    hidden var _camera;
    hidden var _tracker;
    //! Passed straight through to the menu. Held rather than resolved there so
    //! that nothing below the app has to name the app; see `MapMenuDelegate`.
    hidden var _onPickCity;
    hidden var _startX;
    hidden var _startY;

    function initialize(view, camera, tracker, onPickCity) {
        InputDelegate.initialize();
        _view = view;
        _camera = camera;
        _tracker = tracker;
        _onPickCity = onPickCity;
        _startX = 0;
        _startY = 0;
    }

    function onDrag(event) {
        var coordinates = event.getCoordinates();
        var type = event.getType();

        if (type == WatchUi.DRAG_TYPE_START) {
            // Dismiss and carry on: the map is revealed under the finger and
            // pans, which is a better answer to a swipe than swallowing it.
            dismissTip();
            _startX = coordinates[0];
            _startY = coordinates[1];
            _view.beginDrag();
        } else if (type == WatchUi.DRAG_TYPE_CONTINUE) {
            _view.dragBy(coordinates[0] - _startX, coordinates[1] - _startY);
        } else {
            _view.dragBy(coordinates[0] - _startX, coordinates[1] - _startY);
            _view.endDrag();
        }
        return true;
    }

    function onTap(event) {
        // Before hitTest: the card sits over the buttons, so a tap that lands
        // on one of them was aimed at the card, not at the zoom control.
        if (dismissTip()) { return true; }

        var coordinates = event.getCoordinates();
        var target = _view.hitTest(coordinates[0], coordinates[1]);

        if (target == :zoomIn) {
            if (_camera.zoomIn()) { refresh(); }
            return true;
        }
        if (target == :zoomOut) {
            if (_camera.zoomOut()) { refresh(); }
            return true;
        }
        if (target == :follow) {
            recentre();
            return true;
        }
        return false;
    }

    function onHold(event) {
        // Holding is what the card asks for, so it opens the menu as well as
        // dismissing: following the instruction has to work the first time.
        dismissTip();
        openMenu();
        return true;
    }

    function onKey(event) {
        var key = event.getKey();

        // Anything pressed while the card is up means "read it". KEY_ESC is
        // excluded so it still falls through and closes the app.
        if (key != WatchUi.KEY_ESC && dismissTip()) { return true; }

        if (key == WatchUi.KEY_ENTER) {
            recentre();
            return true;
        }
        if (key == WatchUi.KEY_MENU) {
            openMenu();
            return true;
        }
        if (key == WatchUi.KEY_UP) {
            if (_camera.zoomIn()) { refresh(); }
            return true;
        }
        if (key == WatchUi.KEY_DOWN) {
            if (_camera.zoomOut()) { refresh(); }
            return true;
        }
        // KEY_ESC falls through so the system can close the app.
        return false;
    }

    hidden function recentre() {
        if (_tracker.hasFix()) {
            _camera.follow = true;
            _camera.centreOn(_tracker.lat(), _tracker.lon());
        } else {
            // No fix yet: at least put the packed region back on screen.
            _camera.jumpToPackCentre();
        }
        refresh();
    }

    //! Take down the first-run card if it is up. True when it was, so callers
    //! can spend the gesture on that instead of on whatever it covers.
    //!
    //! No `_view.invalidate()`: the map buffer underneath is already rendered
    //! and unchanged, so this is only the overlay going away.
    hidden function dismissTip() {
        if (!Onboarding.shouldShow()) { return false; }
        Onboarding.dismiss();
        WatchUi.requestUpdate();
        return true;
    }

    //! No Settings.save() here on purpose. Zoom presses repeat, and every save
    //! is six Storage writes that each need transient heap; MapView.onHide()
    //! and the app's onStop() persist instead.
    hidden function refresh() {
        _view.invalidate();
        WatchUi.requestUpdate();
    }

    hidden function openMenu() {
        WatchUi.pushView(MapMenu.build(_camera),
                         new MapMenuDelegate(_view, _camera, _onPickCity),
                         WatchUi.SLIDE_UP);
    }
}
