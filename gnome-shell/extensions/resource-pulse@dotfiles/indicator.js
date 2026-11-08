// The top-bar indicator: two mini area graphs, CPU then memory, with no text. The numbers appear in a label
// below it once the pointer has rested on it for HOVER_LABEL_DELAY_MS, and a click opens the system monitor.
//
// Shell glue only: every number comes from the sampler, every string from lib/format.js and every shape from
// graph.js. It runs inside gnome-shell, so destroying it removes everything it added outside itself (the hover
// label, which lives in the layout manager's chrome, its timeout, and its sampler listener), and nothing it
// schedules can outlive it.
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';

import {drawAreaGraph, padWithLeadingGaps} from './graph.js';
import {
    BASELINE_RGBA, CPU_GRAPH_RGBA, HOVER_LABEL_DELAY_MS, HOVER_LABEL_FADE_IN_MS, HOVER_LABEL_FADE_OUT_MS,
    MEMORY_GRAPH_RGBA, RESOURCES_APP_IDS, TOPBAR_GRAPH_HEIGHT_PX, TOPBAR_GRAPH_WIDTH_PX, TOPBAR_HISTORY_SAMPLES,
} from './lib/constants.js';
import {hoverLabel} from './lib/format.js';
import {hoverLabelPosition} from './lib/layout.js';

const ACCESSIBLE_NAME = 'Resource Pulse';
/** PanelMenu.Button's menu alignment; unused, since the button has no menu. */
const MENU_ALIGNMENT = 0.0;
const DONT_CREATE_MENU = true;
const GRAPH_BOX_STYLE_CLASS = 'resource-pulse-graphs';
const HOVER_LABEL_STYLE_CLASS = 'resource-pulse-hover-label';
/** The stylesheet's gap between the indicator's bottom edge and the label's top, as the dash's labels use. */
const HOVER_LABEL_Y_OFFSET_PROPERTY = '-y-offset';
const HOVER_LABEL_TIMEOUT_NAME = '[resource-pulse] show the hover label';
const GRAPH_WIDTH_STYLE = `width: ${TOPBAR_GRAPH_WIDTH_PX}px;`;
const GRAPH_HEIGHT_STYLE = `height: ${TOPBAR_GRAPH_HEIGHT_PX}px;`;
// St scales CSS lengths by the theme's scale factor, so sizing the graphs in CSS keeps them right at any scale.
const GRAPH_SIZE_STYLE = `${GRAPH_WIDTH_STYLE} ${GRAPH_HEIGHT_STYLE}`;
const TRANSPARENT_OPACITY = 0;
const OPAQUE_OPACITY = 255;
/** Clutter's for_height of -1: the label's width for its own height, with no height constraint. */
const UNCONSTRAINED_HEIGHT = -1;
/** The stage's left edge, for the fallback when the indicator is on no monitor. */
const STAGE_LEFT_EDGE_PX = 0;

export const PulseIndicator = GObject.registerClass(
class PulseIndicator extends PanelMenu.Button {
    /**
     * Builds the graphs, the click and the hover label, and starts listening to the sampler and to the display
     * scale. The hover label is added to the chrome, and the outside signals connected, only after everything
     * that could throw, so a failed construction leaves nothing in the shell.
     *
     * @param {import('./sampler.js').Sampler} sampler - The one sampler; the indicator draws its histories.
     * @returns {void}
     */
    _init(sampler) {
        super._init(MENU_ALIGNMENT, ACCESSIBLE_NAME, DONT_CREATE_MENU);
        // Every field _onDestroy reads is set before anything below can throw.
        this._sampler = sampler;
        this._hoverLabel = null;
        this._isHoverLabelShown = false;
        this._showHoverLabelTimeoutId = null;
        this._snapshotListenerId = null;

        const graphBox = new St.BoxLayout({style_class: GRAPH_BOX_STYLE_CLASS});
        this._cpuGraph = this._addGraph(graphBox, sampler.cpuHistory, CPU_GRAPH_RGBA);
        this._memoryGraph = this._addGraph(graphBox, sampler.memoryHistory, MEMORY_GRAPH_RGBA);
        this.add_child(graphBox);

        // PanelMenu.Button's own click gesture is disabled when it has no menu, so the click gets one of its own.
        const openGesture = new Clutter.ClickGesture({required_button: Clutter.BUTTON_PRIMARY});
        openGesture.connect('recognize', () => this._openSystemMonitor());
        this.add_action(openGesture);

        this.connect('notify::hover', () => this._syncHoverLabel());
        // Hidden while hovered (say, a fullscreen window hides the panel): the label must not stay up above it.
        this.connect('notify::mapped', () => this._syncHoverLabel());

        this._hoverLabel = new St.Label({style_class: HOVER_LABEL_STYLE_CLASS, visible: false});
        // The label's first width after it is shown can be stale: one hidden across a display-scale change
        // measures at the old scale until it is allocated again. Placing it again once its width settles (and
        // when the scale changes while it is up) keeps it centred. The label is destroyed with the indicator,
        // and its handlers with it.
        this._hoverLabel.connect('notify::width', () => this._placeShownHoverLabel());
        Main.layoutManager.addTopChrome(this._hoverLabel);
        this._snapshotListenerId = sampler.addListener(snapshot => this._onSnapshot(snapshot));
        St.ThemeContext.get_for_stage(global.stage).connectObject(
            'notify::scale-factor', () => this._placeShownHoverLabel(), this);
    }

    /**
     * Adds one mini graph that draws a history on every repaint.
     *
     * @param {St.BoxLayout} graphBox - Where the graph goes.
     * @param {import('./lib/history.js').RingBuffer} history - The fractions it draws.
     * @param {number[]} fillRgba - The graph's colour, as [red, green, blue, alpha], each 0–1.
     * @returns {St.DrawingArea} The graph.
     */
    _addGraph(graphBox, history, fillRgba) {
        const graph = new St.DrawingArea({style: GRAPH_SIZE_STYLE, y_align: Clutter.ActorAlign.CENTER});
        graph.connect('repaint', () => this._paintGraph(graph, history, fillRgba));
        graphBox.add_child(graph);
        return graph;
    }

    /**
     * Draws the newest TOPBAR_HISTORY_SAMPLES of a history into a graph, right-aligned, and frees the context
     * whatever happens (as the shell's own drawing areas do).
     *
     * @param {St.DrawingArea} graph - The graph being repainted.
     * @param {import('./lib/history.js').RingBuffer} history - The fractions to draw.
     * @param {number[]} fillRgba - The graph's colour.
     * @returns {void}
     */
    _paintGraph(graph, history, fillRgba) {
        const newestFractions = history.lastValues(TOPBAR_HISTORY_SAMPLES);
        const slotFractions = padWithLeadingGaps(newestFractions, TOPBAR_HISTORY_SAMPLES);
        const [widthPx, heightPx] = graph.get_surface_size();
        const cr = graph.get_context();
        try {
            drawAreaGraph(cr, widthPx, heightPx, slotFractions, fillRgba, BASELINE_RGBA);
        } finally {
            cr.$dispose();
        }
    }

    /**
     * Redraws the graphs for a new snapshot, and refreshes the hover label while it is up, so it never shows
     * an older sample than the graphs do.
     *
     * @param {import('./sampler.js').Snapshot} _snapshot - The new snapshot (the label reads the latest).
     * @returns {void}
     */
    _onSnapshot(_snapshot) {
        this._cpuGraph.queue_repaint();
        this._memoryGraph.queue_repaint();
        if (this._isHoverLabelShown) {
            this._updateHoverLabelText();
            this._placeHoverLabel();
        }
    }

    /**
     * Shows the hover label after the delay while the pointer is on the indicator, and hides it at once when the
     * pointer leaves or the indicator is hidden. A no-op once destroyed.
     *
     * @returns {void}
     */
    _syncHoverLabel() {
        if (this._hoverLabel === null)
            return;
        if (this.hover && this.mapped) {
            this._scheduleHoverLabel();
        } else {
            this._cancelHoverLabelTimeout();
            this._hideHoverLabel();
        }
    }

    /**
     * Starts the delay before the hover label shows, unless it is already pending or shown.
     *
     * @returns {void}
     */
    _scheduleHoverLabel() {
        if (this._showHoverLabelTimeoutId !== null || this._isHoverLabelShown)
            return;
        this._showHoverLabelTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, HOVER_LABEL_DELAY_MS, () => {
            this._showHoverLabelTimeoutId = null;
            this._showHoverLabel();
            return GLib.SOURCE_REMOVE;
        });
        GLib.Source.set_name_by_id(this._showHoverLabelTimeoutId, HOVER_LABEL_TIMEOUT_NAME);
    }

    /**
     * Removes the pending show of the hover label, if any.
     *
     * @returns {void}
     */
    _cancelHoverLabelTimeout() {
        if (this._showHoverLabelTimeoutId === null)
            return;
        GLib.source_remove(this._showHoverLabelTimeoutId);
        this._showHoverLabelTimeoutId = null;
    }

    /**
     * Fades the hover label in below the indicator, with the latest numbers.
     *
     * @returns {void}
     */
    _showHoverLabel() {
        const label = this._hoverLabel;
        this._isHoverLabelShown = true;
        this._updateHoverLabelText();
        label.opacity = TRANSPARENT_OPACITY;
        label.show();
        this._placeHoverLabel();
        label.ease({
            opacity: OPAQUE_OPACITY,
            duration: HOVER_LABEL_FADE_IN_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
    }

    /**
     * Fades the hover label out. A show that starts meanwhile replaces the fade, and the label then stays up.
     *
     * @returns {void}
     */
    _hideHoverLabel() {
        if (!this._isHoverLabelShown)
            return;
        this._isHoverLabelShown = false;
        const label = this._hoverLabel;
        label.ease({
            opacity: TRANSPARENT_OPACITY,
            duration: HOVER_LABEL_FADE_OUT_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            // Runs only when the fade finishes, never when a show or a destroy stops it first.
            onComplete: () => label.hide(),
        });
    }

    /**
     * Sets the hover label's text from the sampler's latest snapshot; lib/format.js says "no data since HH:MM"
     * rather than show a stale number as live.
     *
     * @returns {void}
     */
    _updateHoverLabelText() {
        this._hoverLabel.text = hoverLabel(this._sampler.latestSnapshot, this._sampler.lastGoodClockLabel);
    }

    /**
     * Places the hover label again if it is up; a no-op while it is hidden or once the indicator is destroyed.
     *
     * @returns {void}
     */
    _placeShownHoverLabel() {
        if (this._isHoverLabelShown && this._hoverLabel !== null)
            this._placeHoverLabel();
    }

    /**
     * Centres the hover label below the indicator, kept inside the indicator's monitor (lib/layout.js
     * hoverLabelPosition). Called only after the label's text is set, and it measures the label's natural width
     * for that text: get_width() can still answer with the allocation of the previous text, which put the label
     * off-centre by a pixel or two.
     *
     * @returns {void}
     */
    _placeHoverLabel() {
        const label = this._hoverLabel;
        const [indicatorX, indicatorY] = this.get_transformed_position();
        const indicatorRect = {
            x: indicatorX,
            y: indicatorY,
            width: this.allocation.get_width(),
            height: this.allocation.get_height(),
        };
        const [, labelNaturalWidthPx] = label.get_preferred_width(UNCONSTRAINED_HEIGHT);
        // findMonitorForActor answers null only for an actor on no monitor; the whole stage is the fallback then.
        const monitorRect = Main.layoutManager.findMonitorForActor(this) ??
            {x: STAGE_LEFT_EDGE_PX, width: global.stage.width};
        const gapPx = label.get_theme_node().get_length(HOVER_LABEL_Y_OFFSET_PROPERTY);
        const {x, y} = hoverLabelPosition(indicatorRect, labelNaturalWidthPx, gapPx, monitorRect);
        label.set_position(x, y);
    }

    /**
     * Opens the first system monitor installed, in RESOURCES_APP_IDS order, and leaves the overview so it is
     * seen. With none installed the click does nothing, and hovering still works.
     *
     * @returns {void}
     */
    _openSystemMonitor() {
        const appSystem = Shell.AppSystem.get_default();
        const systemMonitorApp = RESOURCES_APP_IDS
            .map(appId => appSystem.lookup_app(appId))
            .find(app => app !== null);
        if (systemMonitorApp === undefined)
            return;
        systemMonitorApp.activate();
        Main.overview.hide();
    }

    /**
     * Removes everything the indicator added outside itself: the display-scale handler, the hover label's pending
     * show, its sampler listener and the label itself (destroying it also takes it out of the chrome, with its own
     * handlers). Runs on the 'destroy' signal, which PanelMenu.Button connects, so it runs however the indicator
     * is destroyed.
     *
     * @returns {void}
     */
    _onDestroy() {
        St.ThemeContext.get_for_stage(global.stage).disconnectObject(this);
        this._cancelHoverLabelTimeout();
        if (this._snapshotListenerId !== null) {
            this._sampler.removeListener(this._snapshotListenerId);
            this._snapshotListenerId = null;
        }
        this._hoverLabel?.destroy();
        this._hoverLabel = null;
        this._isHoverLabelShown = false;
        this._sampler = null;
        super._onDestroy();
    }
});
