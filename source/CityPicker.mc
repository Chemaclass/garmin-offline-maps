import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Choose a city on the watch, from the published catalogue.
//!
//! The phone settings also take a city, but typing a slug means knowing the
//! slug, and getting the case wrong silently 404s. This fetches
//! `<baseUrl>/catalogue.json` and offers what is actually published, so the
//! list grows by publishing a pack rather than by shipping an app update.
//!
//! The catalogue is a couple of hundred bytes per city, so unlike the blocks it
//! is fine to hold as one parsed response.
class CityPicker {

    hidden var _baseUrl;
    hidden var _onChosen;
    hidden var _cities as Array<Dictionary>?;

    function initialize(baseUrl, onChosen) {
        _baseUrl = baseUrl;
        _onChosen = onChosen;
        _cities = null;
    }

    function start() {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        try {
            Communications.makeWebRequest(_baseUrl + "/catalogue.json", null,
                                          options, method(:onCatalogue));
        } catch (ex) {
            showError();
        }
    }

    //! Annotated because `Communications.makeWebRequest` types its callback
    //! exactly. See the note on API-boundary annotations in
    //! docs/DEVELOPMENT.md.
    function onCatalogue(responseCode as Number,
                         data as Dictionary or String or Null) as Void {
        if (responseCode != 200 || !(data instanceof Lang.Dictionary)) {
            System.println("CityPicker: catalogue " + responseCode);
            showError();
            return;
        }
        var body = data as Dictionary;
        var list = body["cities"];
        if (list == null || !(list instanceof Lang.Array)) {
            showError();
            return;
        }
        _cities = list as Array<Dictionary>;
        if (_cities.size() == 0) {
            showError();
            return;
        }

        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MenuCity });
        for (var i = 0; i < _cities.size(); i += 1) {
            var city = _cities[i] as Dictionary;
            var stored = city["storedBytes"];
            var subtitle = stored == null
                ? null
                : (stored.toNumber() / 1024).toString() + " KB";
            // The id is the index: Menu2 ids are symbols or objects, and the
            // slug is only needed once something is chosen.
            menu.addItem(new WatchUi.MenuItem(city["name"], subtitle, i, null));
        }
        WatchUi.pushView(menu, new CityPickerDelegate(self), WatchUi.SLIDE_UP);
    }

    //! Slug for the menu item at `index`, or null.
    function slugAt(index) {
        if (_cities == null || index < 0 || index >= _cities.size()) {
            return null;
        }
        var city = _cities[index] as Dictionary;
        return city["slug"];
    }

    function choose(index) {
        var slug = slugAt(index);
        if (slug != null && _onChosen != null) {
            _onChosen.invoke(slug);
        }
    }

    hidden function showError() {
        WatchUi.pushView(new MessageView(Rez.Strings.CatalogueFailed),
                         new MessageDelegate(), WatchUi.SLIDE_UP);
    }
}

class CityPickerDelegate extends WatchUi.Menu2InputDelegate {

    hidden var _picker;

    function initialize(picker) {
        Menu2InputDelegate.initialize();
        _picker = picker;
    }

    function onSelect(item) {
        var index = item.getId();
        // Pop the picker and the map menu underneath it, so choosing a city
        // returns to the map rather than to the menu it came from.
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        _picker.choose(index);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

//! One line of text and a Back. Used when the catalogue cannot be reached.
class MessageView extends WatchUi.View {

    hidden var _message;

    function initialize(message) {
        View.initialize();
        _message = message;
    }

    function onUpdate(dc) {
        var colours = Palette.colours(true);
        var background = colours[Palette.SLOT_BACKGROUND];
        dc.setColor(background, background);
        dc.clear();
        dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, (dc.getHeight() * 0.42).toNumber(),
                    Graphics.FONT_SMALL,
                    WatchUi.loadResource(_message) as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, (dc.getHeight() * 0.58).toNumber(),
                    Graphics.FONT_XTINY,
                    WatchUi.loadResource(Rez.Strings.DownloadKeepPhone) as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
    }
}

class MessageDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}
