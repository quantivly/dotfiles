// The cockpit's shared tooltip: the top-bar hover label's mechanism (indicator.js), generalised from one fixed
// anchor to any actor. One label in the layout manager's top chrome; showFor() brings it up under an anchor after
// HOVER_LABEL_DELAY_MS, hide() fades it out. Shell glue only: the placement is lib/layout.js's tooltipPosition.
//
// destroy() removes everything the tooltip added outside itself (the pending show, the pending re-placement, the
// label, which also takes it out of the chrome, and the destroy handler on its anchor), so nothing it schedules or
// connects can outlive it. A card owned by someone else can be destroyed while the tooltip lives: while the tooltip
// holds an anchor it holds exactly one 'destroy' handler on it, which hides the tooltip.
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Pango from 'gi://Pango';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {
    COCKPIT_TOOLTIP_GAP_PX, HOVER_LABEL_DELAY_MS, HOVER_LABEL_FADE_IN_MS, HOVER_LABEL_FADE_OUT_MS,
} from './lib/constants.js';
import {tooltipPosition} from './lib/layout.js';

const TOOLTIP_STYLE_CLASS = 'rp-cockpit-tooltip';
const SHOW_TIMEOUT_NAME = '[resource-pulse] show the cockpit tooltip';
const LINE_SEPARATOR = '\n';
const TRANSPARENT_OPACITY = 0;
const OPAQUE_OPACITY = 255;
/** Clutter's for_height / for_width of -1: the natural size with no constraint on the other axis. */
const UNCONSTRAINED_SIZE = -1;
/** The stage's top-left corner, for the fallback when the anchor is on no monitor. */
const STAGE_ORIGIN_PX = 0;

export class CockpitTooltip {
    /**
     * Builds the hidden label and adds it to the top chrome. The label ellipsizes each line at its end, so with the
     * stylesheet's max-width a long line (a mount point, an app's group key) is cut rather than drawn across the
     * monitor's edge.
     */
    constructor() {
        this._label = new St.Label({
            style_class: TOOLTIP_STYLE_CLASS, visible: false, opacity: TRANSPARENT_OPACITY, reactive: false,
        });
        this._label.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        this._anchor = null;
        this._anchorDestroyId = null;
        this._text = '';
        this._isShown = false;
        this._showTimeoutId = null;
        this._placeLaterId = null;
        // A new text changes the width during allocation; the label is placed again before the next frame.
        this._label.connect('notify::width', () => this._queuePlaceShownLabel());
        Main.layoutManager.addTopChrome(this._label);
    }

    /**
     * Shows the tooltip under an anchor after the delay. For the anchor it already serves, only the text is
     * updated: the label is placed again while it is up, and a pending show keeps its timer (a caller that calls
     * this on every pointer motion must still see the tooltip appear). For another anchor, the pending show
     * restarts for the new anchor.
     *
     * @param {Clutter.Actor} anchorActor - The actor the tooltip hangs off (a row of a card).
     * @param {string[]} lines - The tooltip's lines, joined with newlines.
     * @returns {void}
     */
    showFor(anchorActor, lines) {
        if (this._label === null)
            return;
        const text = lines.join(LINE_SEPARATOR);
        if (anchorActor === this._anchor && (this._isShown || this._showTimeoutId !== null)) {
            this._text = text;
            if (this._isShown) {
                this._label.text = text;
                this._placeLabel();
            }
            return;
        }
        this._cancelPendingShow();
        this._setAnchor(anchorActor);
        this._text = text;
        this._showTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, HOVER_LABEL_DELAY_MS, () => {
            this._showTimeoutId = null;
            this._show();
            return GLib.SOURCE_REMOVE;
        });
        GLib.Source.set_name_by_id(this._showTimeoutId, SHOW_TIMEOUT_NAME);
    }

    /**
     * Cancels a pending show and fades the label out if it is up. A no-op once destroyed.
     *
     * @returns {void}
     */
    hide() {
        if (this._label === null)
            return;
        this._cancelPendingShow();
        this._releaseAnchor();
        if (!this._isShown)
            return;
        this._isShown = false;
        const label = this._label;
        label.ease({
            opacity: TRANSPARENT_OPACITY,
            duration: HOVER_LABEL_FADE_OUT_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            // Runs only when the fade finishes, never when a show or a destroy stops it first.
            onComplete: () => label.hide(),
        });
    }

    /**
     * Cancels the pending show and the pending re-placement and destroys the label (which takes it out of the
     * chrome). Safe to call twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._label === null)
            return;
        this._cancelPendingShow();
        this._releaseAnchor();
        if (this._placeLaterId !== null) {
            global.compositor.get_laters().remove(this._placeLaterId);
            this._placeLaterId = null;
        }
        this._label.destroy();
        this._label = null;
        this._isShown = false;
    }

    /**
     * Makes an actor the anchor, holding one 'destroy' handler on it that hides the tooltip; the previous anchor's
     * handler is released first.
     *
     * @param {Clutter.Actor} anchorActor - The new anchor.
     * @returns {void}
     */
    _setAnchor(anchorActor) {
        this._releaseAnchor();
        this._anchor = anchorActor;
        this._anchorDestroyId = anchorActor.connect('destroy', () => this.hide());
    }

    /**
     * Drops the anchor and the destroy handler held on it, if any.
     *
     * @returns {void}
     */
    _releaseAnchor() {
        if (this._anchor === null)
            return;
        this._anchor.disconnect(this._anchorDestroyId);
        this._anchor = null;
        this._anchorDestroyId = null;
    }

    /**
     * Removes the pending show, if any.
     *
     * @returns {void}
     */
    _cancelPendingShow() {
        if (this._showTimeoutId === null)
            return;
        GLib.source_remove(this._showTimeoutId);
        this._showTimeoutId = null;
    }

    /**
     * Raises the label above its siblings, sets the text, places the label and fades it in. The raise is on every
     * show: the label joined the top chrome once, when it was made, and GNOME Shell's PopupMenu.open() raises the
     * menu to the top of the same group on every open, so the dropdown's tooltip would be drawn under its own menu.
     *
     * @returns {void}
     */
    _show() {
        const label = this._label;
        this._isShown = true;
        label.get_parent()?.set_child_above_sibling(label, null);
        label.text = this._text;
        label.opacity = TRANSPARENT_OPACITY;
        label.show();
        this._placeLabel();
        label.ease({
            opacity: OPAQUE_OPACITY,
            duration: HOVER_LABEL_FADE_IN_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
    }

    /**
     * Places the label again before the next frame, if it is up. notify::width comes during allocation, and moving
     * an actor then leaves it needing an allocation, which Clutter warns about; a BEFORE_REDRAW later moves it
     * before the next frame instead (as indicator.js does). Several calls before then queue one.
     *
     * @returns {void}
     */
    _queuePlaceShownLabel() {
        if (this._placeLaterId !== null || !this._isShown)
            return;
        this._placeLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._placeLaterId = null;
            if (this._isShown && this._label !== null)
                this._placeLabel();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Places the label under its anchor (lib/layout.js tooltipPosition), measuring the label's natural size for its
     * current text: get_width() can still answer with the previous text's allocation.
     *
     * @returns {void}
     */
    _placeLabel() {
        const label = this._label;
        const anchor = this._anchor;
        if (anchor === null)
            return;
        const [anchorX, anchorY] = anchor.get_transformed_position();
        const [anchorWidth, anchorHeight] = anchor.get_transformed_size();
        const anchorRect = {x: anchorX, y: anchorY, width: anchorWidth, height: anchorHeight};
        const [, labelWidthPx] = label.get_preferred_width(UNCONSTRAINED_SIZE);
        const [, labelHeightPx] = label.get_preferred_height(labelWidthPx);
        // findMonitorForActor answers null only for an actor on no monitor; the whole stage is the fallback then.
        const monitorRect = Main.layoutManager.findMonitorForActor(anchor) ??
            {x: STAGE_ORIGIN_PX, y: STAGE_ORIGIN_PX, width: global.stage.width, height: global.stage.height};
        const {x, y} = tooltipPosition({
            anchorRect, labelWidthPx, labelHeightPx, gapPx: COCKPIT_TOOLTIP_GAP_PX, monitorRect,
        });
        label.set_position(x, y);
    }
}
