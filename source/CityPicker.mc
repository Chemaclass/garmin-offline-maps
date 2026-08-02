import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Choose a city on the watch, from the published catalogue.
//!
//! Two levels, country then city, because a catalogue meant to reach every
//! capital is far too long to scroll flat.
//!
//! This has to live on the watch rather than in the phone settings, and that is
//! a platform limit rather than a preference. Connect IQ settings are compiled
//! into the app: `settingConfig type="list"` takes only static `listEntry`
//! children, and the single dependency mechanism in the schema
//! (`group enableIfTrue`) gates a group on a boolean. There is no way to fill a
//! list at runtime, and no way to make one list depend on another's value. A
//! compiled-in list would also mean an app release per city, which is exactly
//! what publishing from CI removes.
//!
//! The catalogue is a couple of hundred bytes per city, so unlike the blocks it
//! is fine to hold as one parsed response. It arrives sorted by country then
//! name, so the grouping below is one walk with no sorting on a 768 KB heap.
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
        WatchUi.pushView(countryMenu(), new CountryDelegate(self), WatchUi.SLIDE_UP);
    }

    //! One entry per country, with how many cities it has.
    //!
    //! The id is the index of that country's first city, so picking a country
    //! needs no second lookup and no map from country to list.
    hidden function countryMenu() {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MenuCountry });
        var at = 0;
        while (at < _cities.size()) {
            var country = countryAt(at);
            var count = 0;
            while (at + count < _cities.size() && countryAt(at + count).equals(country)) {
                count += 1;
            }
            menu.addItem(new WatchUi.MenuItem(country, count.toString(), at, null));
            at += count;
        }
        return menu;
    }

    //! The cities of the country that starts at `first`.
    function cityMenu(first) {
        var country = countryAt(first);
        var menu = new WatchUi.Menu2({ :title => country });
        for (var i = first; i < _cities.size(); i += 1) {
            if (!countryAt(i).equals(country)) { break; }
            var city = _cities[i];
            var stored = city["storedBytes"];
            var subtitle = stored == null
                ? null
                : (stored.toNumber() / 1024).toString() + " KB";
            // The id is the index: Menu2 ids are symbols or objects, and the
            // slug is only needed once something is chosen.
            menu.addItem(new WatchUi.MenuItem(city["name"], subtitle, i, null));
        }
        return menu;
    }

    hidden function countryAt(index) {
        var city = _cities[index];
        var country = city["country"];
        return country == null ? "Other" : country;
    }

    //! Slug for the menu item at `index`, or null.
    function slugAt(index) {
        if (_cities == null || index < 0 || index >= _cities.size()) {
            return null;
        }
        var city = _cities[index];
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

//! Picking a country opens its cities. Back returns to the country list, which
//! is why this pushes rather than replaces.
class CountryDelegate extends WatchUi.Menu2InputDelegate {

    hidden var _picker;

    function initialize(picker) {
        Menu2InputDelegate.initialize();
        _picker = picker;
    }

    function onSelect(item) {
        WatchUi.pushView(_picker.cityMenu(item.getId()),
                         new CityPickerDelegate(_picker), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
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
        // Take down the city list and the country list under it, so choosing a
        // city lands on the map rather than back in the menus it came from.
        WatchUi.popView(WatchUi.SLIDE_DOWN);
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
        Ui.clear(dc, colours);
        var width = dc.getWidth();
        var height = dc.getHeight();
        Ui.resourceLine(dc, colours[Palette.SLOT_TEXT], width, height, 0.42,
                        Graphics.FONT_SMALL, _message);
        Ui.resourceLine(dc, colours[Palette.SLOT_DIM], width, height, 0.58,
                        Graphics.FONT_XTINY, Rez.Strings.DownloadKeepPhone);
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
