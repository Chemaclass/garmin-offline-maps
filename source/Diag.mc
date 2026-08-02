import Toybox.Lang;
import Toybox.System;

//! The last thing that went wrong, kept so the watch can show it.
//!
//! `System.println` only reaches a machine running `monkeydo`, and the watch's
//! own CIQ_LOG.YAML needs a USB cable and a file manager. Neither helps someone
//! standing outside with a black screen. An exception recorded here is drawn on
//! the map instead, so the failure can be read off the watch and repeated back.
//!
//! Deliberately one string. Storage is not involved and nothing accumulates:
//! this exists to make the current fault visible, not to keep a history.
module Diag {

    //! Short description of the last failure, or null.
    //!
    //! Plain `var`: `hidden` is a class modifier and the compiler rejects it
    //! inside a module.
    var lastError = null;

    //! Record a failure, tagged with where it happened.
    //!
    //! The tag matters more than it looks. "render" and "download" fail for
    //! entirely different reasons, and the message alone rarely says which side
    //! of the app threw.
    function record(where, ex) {
        var message = "?";
        try {
            if (ex != null) {
                var text = ex.getErrorMessage();
                if (text != null) { message = text; }
            }
        } catch (inner) {
            // getErrorMessage can itself fail on some exception types.
        }
        lastError = where + ": " + message;
        System.println("Diag " + lastError);
    }

    function clear() {
        lastError = null;
    }

    //! Not named `has`: that is the Monkey C membership operator and the
    //! parser rejects it as an identifier.
    function hasError() {
        return lastError != null;
    }
}
