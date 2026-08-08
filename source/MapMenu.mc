import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

module MapMenu {

    //! Menu2 and MenuItem take a ResourceId directly. Passing the result of
    //! WatchUi.loadResource() instead would be a type error at gradual type
    //! checking, because loadResource is typed as a union of every resource
    //! kind rather than String.
    function build(camera) {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MenuTitle });

        menu.addItem(new WatchUi.ToggleMenuItem(
            Rez.Strings.MenuHeadingUp, Rez.Strings.MenuHeadingUpSub,
            :headingUp, camera.headingUp, null));

        menu.addItem(new WatchUi.ToggleMenuItem(
            Rez.Strings.MenuNight, Rez.Strings.MenuNightSub,
            :night, camera.night, null));

        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MenuCity, Pack.name(), :city, null));

        menu.addItem(new WatchUi.MenuItem(Rez.Strings.MenuStats, null, :stats, null));

        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MenuAbout, Pack.name(), :about, null));

        return menu;
    }
}

class MapMenuDelegate extends WatchUi.Menu2InputDelegate {

    hidden var _view;
    hidden var _camera;
    hidden var _onPickCity;

    function initialize(view, camera, onPickCity) {
        Menu2InputDelegate.initialize();
        _view = view;
        _camera = camera;
        _onPickCity = onPickCity;
    }

    function onSelect(item) {
        var id = item.getId();

        // `onSelect` receives the base MenuItem; these two entries are built as
        // ToggleMenuItems, and only that subtype carries isEnabled().
        if (id == :headingUp) {
            _camera.headingUp = (item as ToggleMenuItem).isEnabled();
            _view.redrawFromScratch();
        } else if (id == :night) {
            _camera.night = (item as ToggleMenuItem).isEnabled();
            // The buffer is unpaletted, so a theme change is a repaint: no
            // need to throw the allocation away and take it again.
            _view.redrawFromScratch();
        } else if (id == :city) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            // The app owns the downloader and the pack, so it drives this, but
            // the entry point is handed down rather than reached up for.
            // `Application.getApp() as OfflineMapsApp` here would name the app
            // from a menu the app's own delegate opened, closing the cycle
            // OfflineMapsApp -> MapDelegate -> MapMenuDelegate -> OfflineMapsApp.
            if (_onPickCity != null) { _onPickCity.invoke(); }
            return;
        } else if (id == :stats) {
            _view.toggleDebug();
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        } else if (id == :about) {
            WatchUi.pushView(new AboutView(), new AboutDelegate(), WatchUi.SLIDE_UP);
            return;
        }

        Settings.save(_camera);
        WatchUi.requestUpdate();
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

//! Pack provenance and the attribution the map data's licence requires.
class AboutView extends WatchUi.View {

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var lines = [
            WatchUi.loadResource(Rez.Strings.AppName) as String,
            // Directly under the name, because this is the line someone came
            // here to read: which build is actually on the watch.
            "v" + Version.APP,
            Pack.name(),
            Pack.blockCount() + " blocks, " + (Pack.dataBytes() / 1024) + " KB",
            "zoom " + Pack.minZoom() + "-" + Pack.maxZoom(),
            Pack.attribution(),
            WatchUi.loadResource(Rez.Strings.SourceRepo) as String
        ];

        // Tight pitch: seven lines have to clear the bottom of a round screen.
        var top = height * 0.22;
        for (var i = 0; i < lines.size(); i += 1) {
            dc.setColor(i == 0 ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY,
                        Graphics.COLOR_TRANSPARENT);
            dc.drawText(width / 2, (top + i * (height * 0.095)).toNumber(),
                        i == 0 ? Graphics.FONT_SMALL : Graphics.FONT_XTINY,
                        lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}

class AboutDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }

    function onSelect() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}
