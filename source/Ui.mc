import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The two drawing moves every screen in this app makes.
//!
//! There are five things that draw -- the map, the first-run card, the
//! download screen, the catalogue error and the about page -- and each one
//! began by clearing to the palette background and then centring a line of
//! text at some fraction of the height. Written out at each call site that is
//! two `dc` calls apiece and, more to the point, a second place that knows
//! which palette slot the background is.
//!
//! Plain `var`/`function`: `hidden` is a class modifier and the compiler
//! rejects it inside a module.
module Ui {

    //! Fill the whole context with this palette's background.
    //!
    //! `colours` is annotated for the reason given in `MapView.drawOverlay`:
    //! an unannotated hop makes it `Object?`, which the checker cannot index,
    //! and the annotation has to sit on every hop from `Palette.colours()` to
    //! the subscript.
    function clear(dc, colours as Array<Number>) {
        var background = colours[Palette.SLOT_BACKGROUND];
        dc.setColor(background, background);
        dc.clear();
    }

    //! One centred line, `fraction` of the way down the screen.
    //!
    //! Every offset in this app is a fraction of the height rather than a
    //! pixel count, because the products in manifest.xml differ in both size
    //! and shape; see docs/DEVICES.md.
    //!
    //! Takes a colour rather than a palette slot so that every `colours[...]`
    //! subscript stays in the annotated caller, and a String rather than a
    //! resource so callers with something to interpolate can use it too.
    function textLine(dc, colour, width, height, fraction, font, text) {
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, (height * fraction).toNumber(), font,
                    text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! The same line, from a string resource.
    //!
    //! `WatchUi.loadResource` is typed as a union of every resource kind, so
    //! the cast happens here once instead of at each call.
    function resourceLine(dc, colour, width, height, fraction, font, resource) {
        textLine(dc, colour, width, height, fraction, font,
                 WatchUi.loadResource(resource) as String);
    }
}
