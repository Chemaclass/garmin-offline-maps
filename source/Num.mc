import Toybox.Lang;

//! Turning values that came from JSON into ones the language can compute with.
//!
//! Nothing here is defensive tidiness. A `Float` reaching `<<` or `>>` raises
//! `UnexpectedTypeError`, and so does a `null`. That is a `Lang.Error` rather
//! than a `Lang.Exception`, so **no `catch` can stop it**: the app terminates
//! and the watch shows the Connect IQ error screen. It shipped once, in the
//! first version that could download a city.
//!
//! `toNumber()` alone is not enough, which is the trap. It is itself partial:
//! on a `String` it returns `null` for anything unparseable, and on a `Boolean`
//! or `Dictionary` it does not exist at all. So a guard that only checks for
//! `null` before calling it can still put a `null` in the field it was written
//! to protect. Every conversion here is gated on a type test first.
//!
//! This lives in its own module rather than in `Pack` because `CityStore` needs
//! it too, and `Pack` already reads `CityStore`. Putting it in either would
//! make the two depend on each other for the sake of one helper.
module Num {

    //! Anything `toNumber()` and `toDouble()` are actually defined on.
    //!
    //! There is no runtime `Lang.Numeric` to test against; that name is a
    //! type-checker union, not a class.
    function isNumeric(value) {
        return value instanceof Lang.Number || value instanceof Lang.Float
            || value instanceof Lang.Long || value instanceof Lang.Double;
    }

    //! An integer, or `fallback` when the value cannot give one.
    function integer(value, fallback) {
        return isNumeric(value) ? value.toNumber() : fallback;
    }

    function decimal(value) {
        return isNumeric(value) ? value.toDouble() : 0.0d;
    }

    function text(value, fallback) {
        return value instanceof Lang.String ? value : fallback;
    }

    //! Every element as an integer, or an empty array if any of them is not.
    //!
    //! All or nothing on purpose. The arrays this reads are paired by slot
    //! index, so skipping a bad element would marry a zoom to another zoom's
    //! origin, which draws the wrong part of the world rather than failing.
    //! Typed return, because every caller assigns this to a container that then
    //! gets subscripted. Without it the annotation on the field is erased by
    //! the assignment and the warning comes back at the `[i]`.
    function integers(value) as Array<Number> {
        var out = [];
        if (!(value instanceof Lang.Array)) { return out; }
        var list = value as Array;
        for (var i = 0; i < list.size(); i += 1) {
            if (!isNumeric(list[i])) { return []; }
            out.add(list[i].toNumber());
        }
        return out;
    }
}
