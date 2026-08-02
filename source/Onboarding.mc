import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;

//! The first-run card explaining that the built-in map is a demo.
//!
//! Without it the app opens on a synthetic grid town at Berlin's coordinates
//! and says nothing about it, so a user in Madrid concludes the map is broken.
//! The fix (hold the screen, then Change city) is behind a gesture that nothing
//! on screen advertises, which is exactly the kind of thing a first run has to
//! spell out. Shown over the map until acknowledged, and never once a city has
//! been downloaded.
//!
//! Plain `var` rather than `hidden var`: `hidden` is a class modifier and the
//! compiler rejects it inside a module. The leading underscore still says "do
//! not touch this from outside".
module Onboarding {

    //! One boolean, and the only thing this module persists. Storage on these
    //! devices is about 128 KB in total and every write needs transient heap
    //! well beyond its payload, so a card like this gets a single scalar or it
    //! gets nothing. See Settings.mc for the same reasoning at greater length.
    const KEY_SEEN = "tipSeen";

    var _checked = false;
    var _seen = false;

    //! Cached after the first call, because this runs on every frame and a
    //! Storage read has no business in the draw loop.
    function shouldShow() {
        if (!_checked) {
            _checked = true;
            try {
                _seen = (Application.Storage.getValue(KEY_SEEN) != null);
            } catch (ex) {
                // Storage unreadable: show the card. Showing it twice is a far
                // smaller failure than hiding the only pointer to Change city.
                _seen = false;
            }
        }
        // A downloaded city has already answered the question the card asks,
        // so it stops appearing whether or not it was ever dismissed.
        return !_seen && !Pack.isDownloaded();
    }

    //! Persisted the moment the user acknowledges it rather than batched into
    //! `Settings.save`, which only runs at onHide/onStop: a card that has been
    //! read must not come back because the app was killed before it could save.
    function dismiss() {
        _checked = true;
        _seen = true;
        try {
            Application.Storage.setValue(KEY_SEEN, true);
        } catch (ex) {
            // Storage full: the card returns next launch, which is survivable.
            System.println("Onboarding: could not persist dismissal");
        }
    }

    //! The row pitch is 0.09 of the height, which clears a FONT_XTINY line box
    //! (about 1.2 times the em, and the em is around 8% of the height) on every
    //! product in manifest.xml. `Ui.resourceLine` is why the offsets are
    //! fractions at all; see docs/DEVICES.md.
    //!
    //! Lines are separate resources instead of one wrapped string because
    //! `drawText` does not wrap: the break points are part of the copy.
    //!
    //! `colours` is annotated for the reason given in `MapView.drawOverlay`: an
    //! unannotated hop makes it `Object?`, which the checker cannot index.
    function draw(dc, colours as Array<Number>, width, height) {
        // A band across the full width, not a boxed card. On a round screen a
        // box wide enough for this text has its corners off the glass, so the
        // border comes out sliced. The map stays visible above and below the
        // band, which is what says the card is temporary.
        var top = (height * 0.12).toNumber();
        var bottom = (height * 0.88).toNumber();

        dc.setColor(colours[Palette.SLOT_PANEL], Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, top, width, bottom - top);
        dc.setColor(colours[Palette.SLOT_ACCENT], Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(0, top, width, top);
        dc.drawLine(0, bottom, width, bottom);

        var ink = colours[Palette.SLOT_TEXT];
        var dim = colours[Palette.SLOT_DIM];

        Ui.resourceLine(dc, colours[Palette.SLOT_ACCENT], width, height, 0.155,
                        Graphics.FONT_SMALL, Rez.Strings.TipTitle);
        Ui.resourceLine(dc, ink, width, height, 0.290, Graphics.FONT_XTINY,
                        Rez.Strings.TipCity);
        Ui.resourceLine(dc, ink, width, height, 0.380, Graphics.FONT_XTINY,
                        Rez.Strings.TipHold1);
        Ui.resourceLine(dc, ink, width, height, 0.470, Graphics.FONT_XTINY,
                        Rez.Strings.TipHold2);
        // Dim from here down: the phone route is the fallback, not the ask.
        Ui.resourceLine(dc, dim, width, height, 0.575, Graphics.FONT_XTINY,
                        Rez.Strings.TipConnect1);
        Ui.resourceLine(dc, dim, width, height, 0.665, Graphics.FONT_XTINY,
                        Rez.Strings.TipConnect2);
        Ui.resourceLine(dc, dim, width, height, 0.770, Graphics.FONT_XTINY,
                        Rez.Strings.TipDismiss);
    }
}
