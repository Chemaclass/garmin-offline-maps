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
    hidden var _startX;
    hidden var _startY;

    function initialize(view, camera, tracker) {
        InputDelegate.initialize();
        _view = view;
        _camera = camera;
        _tracker = tracker;
        _startX = 0;
        _startY = 0;
    }

    function onDrag(event) {
        var coordinates = event.getCoordinates();
        var type = event.getType();

        if (type == WatchUi.DRAG_TYPE_START) {
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
        openMenu();
        return true;
    }

    function onKey(event) {
        var key = event.getKey();

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

    //! No Settings.save() here on purpose. Zoom presses repeat, and every save
    //! is six Storage writes that each need transient heap; MapView.onHide()
    //! and the app's onStop() persist instead.
    hidden function refresh() {
        _view.invalidate();
        WatchUi.requestUpdate();
    }

    hidden function openMenu() {
        WatchUi.pushView(MapMenu.build(_camera), new MapMenuDelegate(_view, _camera),
                         WatchUi.SLIDE_UP);
    }
}
