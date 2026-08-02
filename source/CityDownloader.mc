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
    hidden var _cancelled;

    function initialize(baseUrl, slug, onProgress, onDone) {
        _baseUrl = baseUrl;
        _slug = slug;
        _onProgress = onProgress;
        _onDone = onDone;
        _keys = null;
        _at = 0;
        _cancelled = false;
    }

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
        try {
            handleMeta(responseCode, data);
        } catch (ex) {
            Diag.record("download", ex);
            fail("meta handling threw");
        }
    }

    hidden function handleMeta(responseCode, data) {
        if (_cancelled) { return; }
        if (responseCode != 200 || !(data instanceof Lang.Dictionary)) {
            fail("meta " + responseCode);
            return;
        }
        var meta = data as Dictionary;
        // Coerced once, here, which is what makes the `Array<Number>` on the
        // field true rather than a hopeful label on a raw JSON array. It also
        // collapses three failures into one test: "blocks" missing, "blocks"
        // that is not a list, and "blocks" that is empty all arrive as size 0.
        // The empty case used to pass: `next()` then declared the download
        // finished immediately and stored a city with no blocks in it, which
        // renders as a permanently blank map rather than as an error.
        var keys = Num.integers(meta["blocks"]);
        if (keys.size() == 0) {
            fail("meta has no usable blocks");
            return;
        }
        if (!CityStore.begin(_slug, meta)) {
            fail("storage refused the city");
            return;
        }
        _keys = keys;
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
        // No toNumber() here: `_keys` is assigned in exactly one place and
        // arrives already coerced, so the element really is a Number. A Float
        // would build ".../b1024.0.json" and 404.
        request(_baseUrl + "/" + _slug + "/b" + _keys[_at].toString()
                + ".json", method(:onBlock));
    }

    //! Same annotation rule as `onMeta`.
    function onBlock(responseCode as Number, data as Dictionary or String or Null) as Void {
        try {
            handleBlock(responseCode, data);
        } catch (ex) {
            // A throw out of a web callback is not caught by anything above it.
            Diag.record("download", ex);
            fail("block handling threw");
        }
    }

    hidden function handleBlock(responseCode, data) {
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
        // Tested, not assumed. `TileStore` decodes this as base64 and swallows
        // a decode failure, so a non-string stores happily and then draws an
        // empty block for as long as the city stays on the watch. Failing the
        // download says so instead.
        if (!(encoded instanceof Lang.String)) {
            fail("block " + _keys[_at] + " was not a string");
            return;
        }
        Diag.trace("dl.store " + (_at + 1) + "/" + _keys.size()
                   + " key:" + _keys[_at]);
        if (!CityStore.putBlock(_keys[_at], encoded)) {
            fail("storage full");
            return;
        }
        _at += 1;
        next();
    }

    //! No `_failed` flag kept here: failure reaches the screen through
    //! `_onDone(false)`, and `DownloadView` holds the only copy anyone reads.
    hidden function fail(reason) {
        System.println("CityDownloader: " + reason);
        // Leave nothing half-written: an incomplete city must never draw.
        CityStore.clear();
        if (_onDone != null) { _onDone.invoke(false); }
    }
}
