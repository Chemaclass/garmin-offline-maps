import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Fetches a city from the published catalogue, one block at a time.
//!
//! One block per request on purpose. The whole city is ~90 KB, which is far
//! too much to hold as a parsed JSON document beside everything else on a
//! 768 KB heap, and BLE moves under 1 KB/s so the transfer takes a minute or
//! two either way. Small requests also mean a dropped connection costs one
//! block rather than the lot.
//!
//! Requests are strictly sequential: each response starts the next. Connect IQ
//! gives no request queue and firing thirty at once is a good way to be
//! throttled or run out of memory.
class CityDownloader {

    hidden var _baseUrl;
    hidden var _slug;
    hidden var _onProgress;
    hidden var _onDone;

    hidden var _keys as Array<Number>?;
    hidden var _at;
    hidden var _failed;
    hidden var _cancelled;

    function initialize(baseUrl, slug, onProgress, onDone) {
        _baseUrl = baseUrl;
        _slug = slug;
        _onProgress = onProgress;
        _onDone = onDone;
        _keys = null;
        _at = 0;
        _failed = false;
        _cancelled = false;
    }

    function total() { return _keys == null ? 0 : _keys.size(); }
    function done() { return _at; }
    function failed() { return _failed; }

    function cancel() {
        _cancelled = true;
        CityStore.clear();
    }

    function start() {
        request(_baseUrl + "/" + _slug + "/meta.json", method(:onMeta));
    }

    hidden function request(url, callback) {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        try {
            Communications.makeWebRequest(url, null, options, callback);
        } catch (ex) {
            fail("request failed");
        }
    }

    //! Annotated because `Communications.makeWebRequest` types its callback
    //! exactly; an untyped signature is rejected. See the note on API-boundary
    //! annotations in docs/DEVELOPMENT.md.
    function onMeta(responseCode as Number, data as Dictionary or String or Null) as Void {
        if (_cancelled) { return; }
        if (responseCode != 200 || !(data instanceof Lang.Dictionary)) {
            fail("meta " + responseCode);
            return;
        }
        var meta = data as Dictionary;
        if (meta["blocks"] == null) {
            fail("meta has no blocks");
            return;
        }
        if (!CityStore.begin(_slug, meta)) {
            fail("storage refused the city");
            return;
        }
        _keys = meta["blocks"];
        _at = 0;
        next();
    }

    hidden function next() {
        if (_cancelled) { return; }
        if (_at >= _keys.size()) {
            CityStore.finish();
            if (_onDone != null) { _onDone.invoke(true); }
            return;
        }
        if (_onProgress != null) { _onProgress.invoke(_at, _keys.size()); }
        request(_baseUrl + "/" + _slug + "/b" + _keys[_at].toString() + ".json",
                method(:onBlock));
    }

    //! Same annotation rule as `onMeta`.
    function onBlock(responseCode as Number, data as Dictionary or String or Null) as Void {
        if (_cancelled) { return; }
        if (responseCode != 200) {
            fail("block " + _keys[_at] + ": " + responseCode);
            return;
        }
        // The packer writes each block as {"b": "<base64>"}. An object rather
        // than an array because this callback's data is typed
        // `Dictionary or String or Null`, and the checker proves an array
        // branch unreachable.
        var encoded = null;
        if (data instanceof Lang.Dictionary) {
            var body = data as Dictionary;
            encoded = body["b"];
        }
        if (encoded == null) {
            fail("block " + _keys[_at] + " was not a string");
            return;
        }
        if (!CityStore.putBlock(_keys[_at], encoded)) {
            fail("storage full");
            return;
        }
        _at += 1;
        next();
    }

    hidden function fail(reason) {
        System.println("CityDownloader: " + reason);
        _failed = true;
        // Leave nothing half-written: an incomplete city must never draw.
        CityStore.clear();
        if (_onDone != null) { _onDone.invoke(false); }
    }
}
