import Toybox.Lang;

//! The app's own version, so a watch can say which build it is running.
//!
//! It has to live here because nothing else knows. A Connect IQ manifest
//! carries no version field, the store assigns its own number at upload
//! (`Store-Version` in a crash log), and neither is readable from inside the
//! app. Without this a side-loaded build and a store build are
//! indistinguishable on the wrist, which is a problem when the question being
//! asked is "did the fix reach the watch?".
//!
//! Bump this in the same commit that cuts the release. It is not free-floating:
//! `tests/contract/test_version.py` fails if it disagrees with the newest
//! entry in `CHANGELOG.md`, so a forgotten bump breaks CI rather than shipping
//! a build that lies about itself.
module Version {

    const APP = "0.5.1";
}
