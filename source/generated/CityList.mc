//
// GENERATED FILE -- DO NOT EDIT.
// Produced by tools/mappack. Re-run the publish workflow to regenerate.
//

import Toybox.Lang;

//! The cities offered by the phone settings dropdown.
//!
//! Connect IQ list settings store a number, so the phone hands back an
//! index and this turns it back into a catalogue slug. Index 0 means the
//! built-in map, hence the offset.
//!
//! This is only what was published when the app was built. The picker on
//! the watch reads the live catalogue and is not limited to it.
module CityList {

    const SLUGS = ["vienna", "paris", "berlin", "hamburg", "munich", "amsterdam", "lisbon", "barcelona", "bullas", "caravaca-de-la-cruz", "cartagena", "cehegin", "madrid", "murcia", "valencia"];

    //! Slug for a settings index, or null for the built-in map.
    function slugAt(index) {
        if (index == null || index <= 0 || index > SLUGS.size()) {
            return null;
        }
        return SLUGS[index - 1];
    }

    //! Settings index for a slug, or 0 when it is not in this build.
    function indexOf(slug) {
        if (slug == null) { return 0; }
        for (var i = 0; i < SLUGS.size(); i += 1) {
            if (SLUGS[i].equals(slug)) { return i + 1; }
        }
        return 0;
    }
}
