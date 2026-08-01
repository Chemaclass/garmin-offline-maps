import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Progress while a city is fetched from the catalogue.
//!
//! Shown instead of the map, because there is no map to show yet: the blocks
//! land in Storage one at a time and a half-downloaded city is deliberately
//! never drawn. A city is around 90 KB over a link that manages under 1 KB/s,
//! so this screen is up for a minute or two and needs to say why.
class DownloadView extends WatchUi.View {

    hidden var _city;
    hidden var _done;
    hidden var _total;
    hidden var _failed;

    function initialize(city) {
        View.initialize();
        _city = city;
        _done = 0;
        _total = 0;
        _failed = false;
    }

    function onProgress(done, total) {
        _done = done;
        _total = total;
        WatchUi.requestUpdate();
    }

    function onFailed() {
        _failed = true;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc) {
        var colours = Palette.colours(true);
        var background = colours[Palette.SLOT_BACKGROUND];
        dc.setColor(background, background);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();

        dc.setColor(colours[Palette.SLOT_TEXT], Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, (height * 0.30).toNumber(), Graphics.FONT_SMALL,
                    WatchUi.loadResource(_failed ? Rez.Strings.DownloadFailed
                                                 : Rez.Strings.Downloading) as String,
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(colours[Palette.SLOT_ACCENT], Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, (height * 0.42).toNumber(), Graphics.FONT_MEDIUM,
                    _city, Graphics.TEXT_JUSTIFY_CENTER);

        if (!_failed) {
            drawBar(dc, colours, width, height);
        }

        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, (height * 0.70).toNumber(), Graphics.FONT_XTINY,
                    WatchUi.loadResource(Rez.Strings.DownloadKeepPhone) as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    hidden function drawBar(dc, colours as Array<Number>, width, height) {
        var barWidth = (width * 0.56).toNumber();
        var x = (width - barWidth) / 2;
        var y = (height * 0.56).toNumber();
        var thickness = 6;

        dc.setColor(colours[Palette.SLOT_PANEL], Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, barWidth, thickness);

        if (_total > 0) {
            var filled = (barWidth * _done / _total).toNumber();
            dc.setColor(colours[Palette.SLOT_ACCENT], Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, y, filled, thickness);
        }

        dc.setColor(colours[Palette.SLOT_DIM], Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, y + thickness + 8, Graphics.FONT_XTINY,
                    _done + " / " + _total, Graphics.TEXT_JUSTIFY_CENTER);
    }
}

//! Back cancels the download and leaves the previous map in place.
class DownloadDelegate extends WatchUi.BehaviorDelegate {

    hidden var _downloader;

    function initialize(downloader) {
        BehaviorDelegate.initialize();
        _downloader = downloader;
    }

    function onBack() {
        if (_downloader != null) { _downloader.cancel(); }
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}
