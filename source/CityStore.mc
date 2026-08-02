import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! A downloaded city, held in `Application.Storage`.
//!
//! Storage is the tightest thing this app touches: about **128 KB in total** and
//! **8 KB per value**, and it holds strings rather than byte arrays. So a city
//! is stored the way it is served, one base64 block per value, and the packer
//! guarantees each one clears the per-value cap
//! (`citypack.MAX_BLOCK_BINARY`).
//!
//! Only one city is kept at a time. Two would not fit, and "one active at a
//! time" is the model anyway: choosing a different city in the phone settings
//! wipes this and downloads again.
module CityStore {

    const KEY_SLUG = "citySlug";
    const KEY_META = "cityMeta";
    //! Prefix for block values: `cb<key>`.
    const KEY_BLOCK = "cb";

    //! Turn whatever was typed into a catalogue slug.
    //!
    //! The published files are lowercase and hyphenated, and GitHub Pages is
    //! case-sensitive: "Berlin" 404s where "berlin" does not. Typing a capital
    //! is the obvious thing to do, so it must not be the thing that fails.
    function normalize(text) {
        if (text == null || !(text instanceof Lang.String)) { return null; }
        var raw = (text as String).toLower();
        var out = "";
        var lastWasDash = true;         // also trims a leading separator
        for (var i = 0; i < raw.length(); i += 1) {
            var ch = raw.substring(i, i + 1);
            if (ch.equals(" ") || ch.equals("_") || ch.equals("-")) {
                if (!lastWasDash) {
                    out += "-";
                    lastWasDash = true;
                }
            } else {
                out += ch;
                lastWasDash = false;
            }
        }
        // Trim a trailing separator.
        if (out.length() > 0 && out.substring(out.length() - 1, out.length()).equals("-")) {
            out = out.substring(0, out.length() - 1);
        }
        return out.length() == 0 ? null : out;
    }

    //! Slug of the stored city, or null when none has been downloaded.
    function slug() {
        try {
            return Application.Storage.getValue(KEY_SLUG);
        } catch (ex) {
            return null;
        }
    }

    //! Stored metadata, or null. Shape is `<slug>/meta.json`.
    function meta() as Dictionary? {
        try {
            return Application.Storage.getValue(KEY_META);
        } catch (ex) {
            return null;
        }
    }

    //! True when this city is stored complete and ready to draw.
    function isComplete(wanted) {
        var have = slug();
        if (have == null || wanted == null || !have.equals(wanted)) {
            return false;
        }
        var stored = meta();
        return stored != null && stored["complete"] == true;
    }

    function blockBase64(key) {
        try {
            return Application.Storage.getValue(KEY_BLOCK + key.toString());
        } catch (ex) {
            return null;
        }
    }

    //! Write one block. Returns false when Storage refused it, which is how a
    //! city that overruns the device budget shows up at runtime.
    function putBlock(key, encoded) {
        try {
            Application.Storage.setValue(KEY_BLOCK + key.toString(), encoded);
            return true;
        } catch (ex) {
            System.println("CityStore: could not store block " + key);
            return false;
        }
    }

    //! Begin a download: remember the slug and the metadata, but leave
    //! `complete` false so an interrupted download is never drawn.
    function begin(citySlug, cityMeta as Dictionary) {
        clear();
        try {
            cityMeta["complete"] = false;
            Application.Storage.setValue(KEY_SLUG, citySlug);
            Application.Storage.setValue(KEY_META, cityMeta);
            return true;
        } catch (ex) {
            System.println("CityStore: could not start " + citySlug);
            return false;
        }
    }

    function finish() {
        try {
            var stored = meta();
            if (stored == null) { return false; }
            stored["complete"] = true;
            Application.Storage.setValue(KEY_META, stored);
            return true;
        } catch (ex) {
            return false;
        }
    }

    //! Drop the stored city, block values included. Storage has no "delete by
    //! prefix", so the block keys come from the metadata we are about to throw
    //! away -- which is why `begin` writes the metadata before any block.
    function clear() {
        try {
            var stored = meta();
            if (stored != null && stored["blocks"] != null) {
                var keys = stored["blocks"] as Array<Number>;
                for (var i = 0; i < keys.size(); i += 1) {
                    Application.Storage.deleteValue(KEY_BLOCK + keys[i].toString());
                }
            }
            Application.Storage.deleteValue(KEY_META);
            Application.Storage.deleteValue(KEY_SLUG);
        } catch (ex) {
            System.println("CityStore: could not clear");
        }
    }
}
