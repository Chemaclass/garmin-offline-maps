import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! The last thing that went wrong, kept so the watch can show it.
//!
//! `System.println` only reaches a machine running `monkeydo`, and the watch's
//! own CIQ_LOG.YAML needs a USB cable and a file manager. Neither helps someone
//! standing outside with a black screen. An exception recorded here is drawn on
//! the map instead, so the failure can be read off the watch and repeated back.
//!
//! # Why there are breadcrumbs as well as messages
//!
//! `record` only ever sees a `Lang.Exception`. The fault that has actually been
//! killing this app after a download is a `Lang.Error` -- `UnexpectedTypeError`,
//! `OutOfMemoryError`, an out-of-range subscript -- and **no `catch` receives
//! one**. The app is terminated where it stands, so nothing held in a variable
//! survives to be drawn.
//!
//! What does survive is a value already written to `Application.Storage`. So
//! `trace` writes *where we are about to go* before going there. If the app
//! dies, that string is still in storage on the next launch, and the crumb
//! names the step that killed it. `MapView` draws it.
//!
//! Storage writes are flash writes, so tracing is not left on. It is armed
//! around a city switch and the first render that follows, which is the window
//! every reported crash has fallen inside, and disarmed the moment a render
//! completes.
module Diag {

    //! Survives a crash; read back on the next launch.
    const KEY_CRUMB = "diagCrumb";

    //! Short description of the last failure, or null.
    //!
    //! Plain `var`: `hidden` is a class modifier and the compiler rejects it
    //! inside a module.
    var lastError = null;

    //! Where the *previous* run died, recovered from storage at startup.
    var lastCrash = null;

    var tracing = false;

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

    //! Record a failure that has no exception behind it.
    //!
    //! `Lang.Exception` takes no message, so a refusal we detect ourselves
    //! cannot be dressed up as one just to reuse `record`.
    function note(where, message) {
        lastError = where + ": " + message;
        System.println("Diag " + lastError);
    }

    //! Start leaving crumbs. Called when a city is about to be adopted.
    function arm() {
        tracing = true;
    }

    //! Stop, and drop the crumb: we got through the risky stretch alive.
    //!
    //! A no-op once disarmed, because the caller is a render that runs every
    //! frame and the delete below is a flash write.
    function disarm() {
        if (!tracing) { return; }
        tracing = false;
        try {
            Application.Storage.deleteValue(KEY_CRUMB);
        } catch (ex) {
            // Nothing to do: a crumb left behind only costs a stale message.
        }
    }

    //! "About to do <step>." Persisted, because the failure we are chasing does
    //! not let us write anything afterwards.
    function trace(step) {
        if (!tracing) { return; }
        try {
            Application.Storage.setValue(KEY_CRUMB, step);
        } catch (ex) {
            // Storage full or unavailable. The app still works; we just lose
            // the breadcrumb, which is strictly better than failing here.
        }
    }

    //! Pick up a crumb the previous run left behind, then clear it.
    //!
    //! A crumb still in storage means the last run did not reach `disarm`, so
    //! whatever it names is where the app died.
    function recoverCrash() {
        try {
            var crumb = Application.Storage.getValue(KEY_CRUMB);
            if (crumb instanceof Lang.String) {
                lastCrash = crumb;
                System.println("Diag: previous run died at " + crumb);
                // Also push it at the phone. Storage is watch-only, so without
                // this the message can only be read off the watch face; as a
                // property it turns up in the app's settings in Garmin Connect
                // at the next sync, which is somewhere it can be copied from.
                try {
                    Application.Properties.setValue("lastCrash", crumb);
                } catch (inner) {
                    // Older install without the property. The on-screen line
                    // still works, and that is the one that matters.
                }
            }
            Application.Storage.deleteValue(KEY_CRUMB);
        } catch (ex) {
            // No crumb, or storage unreadable. Nothing lost.
        }
    }

    function clear() {
        lastError = null;
        lastCrash = null;
    }

    //! What to put on the map, or null. The crash crumb wins: a caught
    //! exception is a failure the app survived, and the one that killed it
    //! matters more.
    function message() {
        if (lastCrash != null) { return "DIED: " + lastCrash; }
        return lastError;
    }
}
