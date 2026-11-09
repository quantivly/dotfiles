// The desktop card ("quiet card"): one small translucent card at the top right of the primary monitor's work
// area, laid out as the mockup the user picked:
//
//   CPU   23%  P 41 · E 6        [five-minute CPU graph]
//   MEM   16.4 of 30.3 GiB       [memory used bar]
//   swap  1.6 GiB (0.4 in RAM)
//
//   waiting on:  CPU [meter]  mem [meter]  io [meter]
//   heaviest:  Chromium 31% · herdr agents 15.7 GiB
//
// Each meter is three drawn cells (graph.js drawPressureMeter), not glyphs: the ▮ and ▯ glyphs are not in Ubuntu
// Sans, fell back to DejaVu Sans, and the empty ones read as missing-glyph boxes.
//
// Its width is fixed (rp-card-fixed), so its left edge never moves as the numbers and names change. St.Label
// ellipsizes by default; every label here turns that off, so a number is never cut, except the two app names on the
// "heaviest" line, which ellipsize at their end when the line is longer than the card.
//
// Windows cover it most of the day. While one does, the extension freezes it (setFrozen): a new snapshot is only
// recorded, and the card queues no relayout and no repaint until the reveal, which repaints it at once from the latest
// snapshot. A frozen card is dimmed (the frozen pseudo-class, which stylesheet.css styles) and repainted, still dimmed,
// every FROZEN_REPAINT_INTERVAL_SECONDS (repaintFrozen), so a card misjudged as covered reads as stale, never as live;
// freezing costs one repaint, unseen when the card really is covered. Unfrozen, a "waiting on" meter and the memory
// bar redraw only when the value they draw changes (lib/cardRepaint.js decides what to repaint).
//
// Shell glue only: every string and meter band comes from lib/format.js (cardText, through lib/cardRepaint.js), every
// shape from graph.js and the position from lib/layout.js (cardPosition). The extension adds it to the layout
// manager's background group, above the wallpaper and below every window, which the overview hides. It is
// display-only: ding's desktop window lies over it and takes every click, so nothing here is reactive. Destroying it
// removes its client listener, the only thing it adds outside itself.
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {drawAreaGraph, drawPressureMeter, drawUsedBar, padWithLeadingGaps, withOpacity} from './graph.js';
import {
    BASELINE_RGBA, CARD_CPU_GRAPH_HEIGHT_PX, CARD_CPU_GRAPH_WIDTH_PX, CARD_HISTORY_SAMPLES, CARD_MARGIN_PX,
    CARD_MEMORY_BAR_HEIGHT_PX, CARD_MEMORY_BAR_WIDTH_PX, CPU_GRAPH_RGBA, MEMORY_GRAPH_RGBA, PRESSURE_METER_FILL_RGBA,
    PRESSURE_METER_HEIGHT_PX, PRESSURE_METER_TRACK_RGBA, PRESSURE_METER_WIDTH_PX, USED_BAR_TRACK_RGBA,
} from './lib/constants.js';
import {CardRepaintPlanner} from './lib/cardRepaint.js';
import {cardPosition} from './lib/layout.js';

const CARD_STYLE_CLASS = 'resource-pulse-card';
/**
 * The card's fixed width, sized to its widest rows (measured in gnome-shell/tests/visibility.test.js). A class of this
 * release only: GNOME re-reads the stylesheet on every enable but the code only at login, so the previous release's
 * code, which never sets it, may meet this stylesheet until then.
 */
const FIXED_WIDTH_STYLE_CLASS = 'rp-card-fixed';
/** The "heaviest" line's names, values and separator, spaced about a word apart. */
const HEAVIEST_PARTS_STYLE_CLASS = 'rp-card-heaviest-parts';
/** The top section: CPU, memory and swap, in label, value and graph columns. */
const METERS_STYLE_CLASS = 'resource-pulse-card-meters';
/** The bottom section: the "waiting on" and "heaviest" lines. */
const DETAILS_STYLE_CLASS = 'resource-pulse-card-details';
const DETAIL_ROW_STYLE_CLASS = 'resource-pulse-card-detail-row';
const CPU_FIGURE_BOX_STYLE_CLASS = 'resource-pulse-card-cpu-figure';
const LABEL_STYLE_CLASS = 'resource-pulse-card-label';
const VALUE_STYLE_CLASS = 'resource-pulse-card-value';
/** The big numbers: the CPU percent and the memory line. */
const FIGURE_STYLE_CLASS = 'resource-pulse-card-figure';
const SUFFIX_STYLE_CLASS = 'resource-pulse-card-suffix';
/** The three "waiting on" meters, side by side. */
const PRESSURE_METERS_STYLE_CLASS = 'resource-pulse-card-pressure-meters';
/** One meter: its label, then its drawn cells. */
const PRESSURE_GROUP_STYLE_CLASS = 'resource-pulse-card-pressure-group';
/** One meter each for CPU, memory and io, in the order lib/format.js waitingOnMeters lists them. */
const WAITING_ON_METER_COUNT = 3;
/** The style pseudo-class the card carries while frozen: stylesheet.css dims its values and graphs under it. */
const FROZEN_PSEUDO_CLASS = 'frozen';
/** The stylesheet property, set on the frozen card, that scales the opacity of its graphs, 0–1. */
const GRAPH_OPACITY_PROPERTY = '-rp-graph-opacity';
/** The graphs' opacity where the stylesheet sets none: undimmed. */
const FULL_GRAPH_OPACITY = 1;

// Cells of the meters grid: [column, row], and how many columns a cell spans.
const LABEL_COLUMN = 0;
const VALUE_COLUMN = 1;
const GRAPHIC_COLUMN = 2;
const CPU_ROW = 0;
const MEMORY_ROW = 1;
const SWAP_ROW = 2;
const ONE_CELL = 1;
/** The swap value has no graphic, so it may run on under the graphs. */
const VALUE_AND_GRAPHIC_CELLS = 2;

// St scales CSS lengths by the theme's scale factor, so sizing the graphs in CSS keeps them right at any scale.
const CPU_GRAPH_SIZE_STYLE = `width: ${CARD_CPU_GRAPH_WIDTH_PX}px; height: ${CARD_CPU_GRAPH_HEIGHT_PX}px;`;
const MEMORY_BAR_SIZE_STYLE = `width: ${CARD_MEMORY_BAR_WIDTH_PX}px; height: ${CARD_MEMORY_BAR_HEIGHT_PX}px;`;
const PRESSURE_METER_SIZE_STYLE = `width: ${PRESSURE_METER_WIDTH_PX}px; height: ${PRESSURE_METER_HEIGHT_PX}px;`;

/**
 * Sets a label's text only when it changed, so an unchanged row never costs a relayout.
 *
 * @param {St.Label} label - The label.
 * @param {string} text - Its new text.
 * @returns {void}
 */
function setLabelText(label, text) {
    if (label.text !== text)
        label.text = text;
}

/**
 * Sets the text of a label that hides when it has none, as the parts of the "heaviest" line do.
 *
 * @param {St.Label} label - The label.
 * @param {string} text - Its new text; '' hides it.
 * @returns {void}
 */
function setOptionalLabelText(label, text) {
    setLabelText(label, text);
    label.visible = text !== '';
}

/**
 * Makes a text label for the card that never ellipsizes (St.Label ellipsizes at its end by default), so the fixed
 * width never cuts a number. Text sits on the bottom of its cell, so labels of different sizes on one row share
 * (nearly) a baseline.
 *
 * @param {string} styleClass - Its style class (muted label, value, big figure or dim suffix).
 * @returns {St.Label} The label, with no text yet.
 */
function newCardLabel(styleClass) {
    const cardLabel = new St.Label({style_class: styleClass, y_align: Clutter.ActorAlign.END});
    cardLabel.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
    return cardLabel;
}

/**
 * Makes a label for an app name on the "heaviest" line: a value label that ellipsizes at its end when the fixed-width
 * card has no room for the whole name, so the numbers beside it are never cut.
 *
 * @returns {St.Label} The label, with no text yet.
 */
function newAppNameLabel() {
    const appNameLabel = newCardLabel(VALUE_STYLE_CLASS);
    appNameLabel.clutter_text.ellipsize = Pango.EllipsizeMode.END;
    return appNameLabel;
}

export const PulseCard = GObject.registerClass(
class PulseCard extends St.BoxLayout {
    /**
     * Builds the rows, shows "no data" until the first snapshot, and starts listening to the client. The
     * listener is added last, after everything that could throw, so a failed construction leaves nothing in the
     * client. The card starts unfrozen.
     *
     * @param {import('./pulseClient.js').PulseClient} client - The one client; the card draws its CPU and memory
     *     histories.
     * @returns {void}
     */
    _init(client) {
        super._init({
            style_class: `${CARD_STYLE_CLASS} ${FIXED_WIDTH_STYLE_CLASS}`,
            orientation: Clutter.Orientation.VERTICAL,
            reactive: false,
        });
        // Every field _onDestroy reads is set before anything below can throw.
        this._client = client;
        this._snapshotListenerId = null;
        this.connect('destroy', () => this._onDestroy());
        this._repaintPlanner = new CardRepaintPlanner();
        // The fraction the memory bar draws: none until the first render.
        this._memoryBarFraction = null;

        this._buildMeters(client.cpuHistory);
        this._buildDetails();
        this.update(client.latestSnapshot, client.lastGoodClockLabel);
        this._snapshotListenerId = client.addListener(
            snapshot => this.update(snapshot, this._client.lastGoodClockLabel));
    }

    /**
     * Shows a snapshot. Frozen, the card only records it, touching no actor, so a covered card queues no relayout and
     * no repaint; unfrozen, it renders it at once (_applyRepaintPlan).
     *
     * @param {import('./pulseClient.js').Snapshot|null} snapshot - The latest snapshot, or null before the first.
     * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data, for "no data since".
     * @returns {void}
     */
    update(snapshot, lastGoodClockLabel) {
        // The client appends the newest fraction with the Sample whose snapshot the memory line shows, before telling
        // listeners, so the bar and the text agree.
        const [newestMemoryFraction = null] = this._client.memoryHistory.lastValues(1);
        this._applyRepaintPlan(this._repaintPlanner.show({snapshot, lastGoodClockLabel, newestMemoryFraction}));
    }

    /**
     * Freezes the card while a window covers it, repainting it once, dimmed; or unfreezes it on the reveal, which
     * repaints it at once, undimmed, from the latest snapshot it was given. Setting the state it already has does
     * nothing.
     *
     * @param {boolean} isFrozen - True while covered.
     * @returns {void}
     */
    setFrozen(isFrozen) {
        this._applyRepaintPlan(this._repaintPlanner.setFrozen(isFrozen));
    }

    /**
     * Repaints a frozen card, still dimmed, from the latest snapshot it was given: the extension's cover re-check timer
     * calls it every FROZEN_REPAINT_INTERVAL_SECONDS while the card counts as covered. Unfrozen it does nothing, since
     * an unfrozen card renders every snapshot already.
     *
     * @returns {void}
     */
    repaintFrozen() {
        this._applyRepaintPlan(this._repaintPlanner.repaintFrozen());
    }

    /**
     * Renders a repaint plan: the dim first, when it changed (_showDimmed); then every row's text (a label whose text
     * is unchanged is left alone), each "waiting on" meter and the memory bar only when what it draws changed, and the
     * CPU graph, whose history moves on with every sample. A part with no data reads "no data" and draws as a gap (an
     * empty bar, or a meter's no-data dash), never as the last good number.
     *
     * @param {import('./lib/cardRepaint.js').RepaintPlan|null} repaintPlan - What to repaint; null for nothing (the
     *     card is frozen, or already in the state asked for).
     * @returns {void}
     */
    _applyRepaintPlan(repaintPlan) {
        if (repaintPlan === null)
            return;
        const {text, changedMeterIndexes, isMemoryBarChanged, memoryFraction, isDimmed, isDimChanged} = repaintPlan;
        if (isDimChanged)
            this._showDimmed(isDimmed);
        this._showRowTexts(text);
        this._showHeaviestRow(text.heaviestRow);
        this._showPressureMeters(text.waitingOnMeters, changedMeterIndexes);
        this._memoryBarFraction = memoryFraction;
        if (isMemoryBarChanged)
            this._memoryBar.queue_repaint();
        this._cpuGraph.queue_repaint();
    }

    /**
     * Dims the card as it freezes, or undims it as it unfreezes: adds or removes the frozen pseudo-class, under which
     * stylesheet.css dims the values (the colour they take from the card) and the graphs (GRAPH_OPACITY_PROPERTY, which
     * every painter reads). The plan that changes the dim also redraws every graph, so each paints at the new opacity.
     *
     * @param {boolean} isDimmed - True as the card freezes.
     * @returns {void}
     */
    _showDimmed(isDimmed) {
        if (isDimmed)
            this.add_style_pseudo_class(FROZEN_PSEUDO_CLASS);
        else
            this.remove_style_pseudo_class(FROZEN_PSEUDO_CLASS);
    }

    /**
     * The opacity the stylesheet gives the card's graphs now: GRAPH_OPACITY_PROPERTY on the card's own style, which
     * stylesheet.css sets only under the frozen pseudo-class, or FULL_GRAPH_OPACITY where it sets none.
     *
     * @returns {number} 0–1 (graph.js withOpacity clamps whatever the stylesheet says).
     */
    _graphOpacity() {
        const [isSet, graphOpacity] = this.get_theme_node().lookup_double(GRAPH_OPACITY_PROPERTY, false);
        return isSet ? graphOpacity : FULL_GRAPH_OPACITY;
    }

    /**
     * Shows the muted labels and the values of the CPU, memory and swap rows, and the labels of the two lines below.
     *
     * @param {import('./lib/format.js').CardText} text - The card's strings.
     * @returns {void}
     */
    _showRowTexts(text) {
        setLabelText(this._cpuLabel, text.cpuLabel);
        setLabelText(this._cpuValue, text.cpuValue);
        setLabelText(this._cpuClusterSuffix, text.cpuClusterSuffix);
        // An empty suffix would still take the figure box's spacing.
        this._cpuClusterSuffix.visible = text.cpuClusterSuffix !== '';
        setLabelText(this._memoryLabel, text.memoryLabel);
        setLabelText(this._memoryValue, text.memoryValue);
        setLabelText(this._swapLabel, text.swapLabel);
        setLabelText(this._swapValue, text.swapValue);
        setLabelText(this._waitingOnLabel, text.waitingOnLabel);
        setLabelText(this._heaviestLabel, text.heaviestLabel);
    }

    /**
     * Shows the "heaviest" line's parts, hiding each one that has no text.
     *
     * @param {import('./lib/format.js').HeaviestRowTexts} heaviestRow - Each half's name and value, and the separator.
     * @returns {void}
     */
    _showHeaviestRow(heaviestRow) {
        setOptionalLabelText(this._heaviestCpuNameLabel, heaviestRow.cpuName);
        setOptionalLabelText(this._heaviestCpuValueLabel, heaviestRow.cpuValue);
        setOptionalLabelText(this._heaviestSeparatorLabel, heaviestRow.separator);
        setOptionalLabelText(this._heaviestMemoryNameLabel, heaviestRow.memoryName);
        setOptionalLabelText(this._heaviestMemoryValueLabel, heaviestRow.memoryValue);
    }

    /**
     * Shows the three "waiting on" meters: each one's label and band, and a redraw of only those whose band changed.
     *
     * @param {import('./lib/format.js').PressureMeter[]} waitingOnMeters - A label and a band for CPU, memory and io.
     * @param {number[]} changedMeterIndexes - The meters whose band differs from the one they drew.
     * @returns {void}
     */
    _showPressureMeters(waitingOnMeters, changedMeterIndexes) {
        this._pressureMeters.forEach((pressureMeter, meterIndex) => {
            const {label, band} = waitingOnMeters[meterIndex];
            setLabelText(pressureMeter.label, label);
            pressureMeter.band = band;
        });
        for (const meterIndex of changedMeterIndexes)
            this._pressureMeters[meterIndex].drawingArea.queue_repaint();
    }

    /**
     * Moves the card to the top right of the primary monitor's work area, inset by CARD_MARGIN_PX, at its current
     * width. With no monitor at all (primaryIndex is -1 then) it stays where it is until the monitors come back.
     *
     * @returns {void}
     */
    placeOnPrimaryMonitor() {
        const {primaryIndex} = Main.layoutManager;
        if (primaryIndex < 0)
            return;
        const workArea = Main.layoutManager.getWorkAreaForMonitor(primaryIndex);
        const {x, y} = cardPosition(workArea, this.width, CARD_MARGIN_PX);
        // Whole logical pixels keep the text sharp.
        this.set_position(Math.floor(x), Math.floor(y));
    }

    /**
     * Builds the top section, a grid so the values and the graphs line up in columns: CPU with its graph, memory
     * with its used bar, then swap.
     *
     * @param {import('./lib/history.js').RingBuffer} cpuHistory - CPU busy fractions, for the graph.
     * @returns {void}
     */
    _buildMeters(cpuHistory) {
        const metersLayout = new Clutter.GridLayout();
        // The layout must belong to its widget before attach() is called: attach() adds nothing otherwise.
        const meters = new St.Widget({style_class: METERS_STYLE_CLASS, layout_manager: metersLayout});
        // Reads the grid's spacing-rows and spacing-columns from the stylesheet (environment.js patches this in).
        metersLayout.hookup_style(meters);
        /**
         * Puts an actor in one row of the grid (which also adds it to the grid's widget).
         *
         * @param {Clutter.Actor} actor - The cell's content.
         * @param {number} column - Its column.
         * @param {number} row - Its row.
         * @param {number} [columnSpan] - How many columns it covers.
         * @returns {void}
         */
        const attachCell = (actor, column, row, columnSpan = ONE_CELL) =>
            metersLayout.attach(actor, column, row, columnSpan, ONE_CELL);

        this._cpuLabel = newCardLabel(LABEL_STYLE_CLASS);
        this._cpuValue = newCardLabel(FIGURE_STYLE_CLASS);
        this._cpuClusterSuffix = newCardLabel(SUFFIX_STYLE_CLASS);
        const cpuFigureBox = new St.BoxLayout({style_class: CPU_FIGURE_BOX_STYLE_CLASS});
        cpuFigureBox.add_child(this._cpuValue);
        cpuFigureBox.add_child(this._cpuClusterSuffix);
        this._cpuGraph = new St.DrawingArea({style: CPU_GRAPH_SIZE_STYLE, y_align: Clutter.ActorAlign.CENTER});
        this._cpuGraph.connect('repaint', () => this._paintCpuGraph(cpuHistory));
        attachCell(this._cpuLabel, LABEL_COLUMN, CPU_ROW);
        attachCell(cpuFigureBox, VALUE_COLUMN, CPU_ROW);
        attachCell(this._cpuGraph, GRAPHIC_COLUMN, CPU_ROW);

        this._memoryLabel = newCardLabel(LABEL_STYLE_CLASS);
        this._memoryValue = newCardLabel(FIGURE_STYLE_CLASS);
        this._memoryBar = new St.DrawingArea({style: MEMORY_BAR_SIZE_STYLE, y_align: Clutter.ActorAlign.CENTER});
        this._memoryBar.connect('repaint', () => this._paintMemoryBar());
        attachCell(this._memoryLabel, LABEL_COLUMN, MEMORY_ROW);
        attachCell(this._memoryValue, VALUE_COLUMN, MEMORY_ROW);
        attachCell(this._memoryBar, GRAPHIC_COLUMN, MEMORY_ROW);

        this._swapLabel = newCardLabel(LABEL_STYLE_CLASS);
        this._swapValue = newCardLabel(VALUE_STYLE_CLASS);
        attachCell(this._swapLabel, LABEL_COLUMN, SWAP_ROW);
        attachCell(this._swapValue, VALUE_COLUMN, SWAP_ROW, VALUE_AND_GRAPHIC_CELLS);

        this.add_child(meters);
    }

    /**
     * Builds the bottom section: the "waiting on" line (a muted label, then a labelled drawn meter for each of
     * CPU, memory and io) and the "heaviest" line.
     *
     * @returns {void}
     */
    _buildDetails() {
        const details = new St.BoxLayout({
            style_class: DETAILS_STYLE_CLASS,
            orientation: Clutter.Orientation.VERTICAL,
        });
        const waitingOnRow = this._addDetailRow(details);
        this._waitingOnLabel = newCardLabel(LABEL_STYLE_CLASS);
        waitingOnRow.add_child(this._waitingOnLabel);
        const pressureMetersBox = new St.BoxLayout({style_class: PRESSURE_METERS_STYLE_CLASS});
        this._pressureMeters = Array.from({length: WAITING_ON_METER_COUNT},
            () => this._addPressureMeter(pressureMetersBox));
        waitingOnRow.add_child(pressureMetersBox);

        this._buildHeaviestRow(this._addDetailRow(details));
        this.add_child(details);
    }

    /**
     * Builds the "heaviest" line: a muted label, then a box of the CPU half's name and value, a separator, and the
     * memory half's name and value. Only the two names ellipsize, so when the line is longer than the card the names
     * give way and the values stay whole.
     *
     * @param {St.BoxLayout} heaviestRow - The empty line.
     * @returns {void}
     */
    _buildHeaviestRow(heaviestRow) {
        this._heaviestLabel = newCardLabel(LABEL_STYLE_CLASS);
        heaviestRow.add_child(this._heaviestLabel);
        this._heaviestCpuNameLabel = newAppNameLabel();
        this._heaviestCpuValueLabel = newCardLabel(VALUE_STYLE_CLASS);
        this._heaviestSeparatorLabel = newCardLabel(VALUE_STYLE_CLASS);
        this._heaviestMemoryNameLabel = newAppNameLabel();
        this._heaviestMemoryValueLabel = newCardLabel(VALUE_STYLE_CLASS);
        const heaviestPartsBox = new St.BoxLayout({style_class: HEAVIEST_PARTS_STYLE_CLASS});
        for (const heaviestPartLabel of [this._heaviestCpuNameLabel, this._heaviestCpuValueLabel,
            this._heaviestSeparatorLabel, this._heaviestMemoryNameLabel, this._heaviestMemoryValueLabel])
            heaviestPartsBox.add_child(heaviestPartLabel);
        heaviestRow.add_child(heaviestPartsBox);
    }

    /**
     * Adds one empty line to the bottom section.
     *
     * @param {St.BoxLayout} details - The bottom section.
     * @returns {St.BoxLayout} The line, for its label and value.
     */
    _addDetailRow(details) {
        const detailRow = new St.BoxLayout({style_class: DETAIL_ROW_STYLE_CLASS});
        details.add_child(detailRow);
        return detailRow;
    }

    /**
     * Adds one "waiting on" meter: a label, then a drawing area sized in CSS that draws the meter's band on every
     * repaint. The drawing area is the card's child, so its repaint handler goes when the card is destroyed.
     *
     * @param {St.BoxLayout} pressureMetersBox - Where the meter goes.
     * @returns {{label: St.Label, drawingArea: St.DrawingArea, band: 0|1|2|3|null}} The meter; update() sets its
     *     label text and band, and band starts as no data.
     */
    _addPressureMeter(pressureMetersBox) {
        const pressureGroup = new St.BoxLayout({style_class: PRESSURE_GROUP_STYLE_CLASS});
        const pressureMeter = {
            label: newCardLabel(VALUE_STYLE_CLASS),
            drawingArea: new St.DrawingArea({style: PRESSURE_METER_SIZE_STYLE, y_align: Clutter.ActorAlign.CENTER}),
            band: null,
        };
        pressureMeter.drawingArea.connect('repaint', () => this._paintPressureMeter(pressureMeter));
        pressureGroup.add_child(pressureMeter.label);
        pressureGroup.add_child(pressureMeter.drawingArea);
        pressureMetersBox.add_child(pressureGroup);
        return pressureMeter;
    }

    /**
     * Draws the five-minute CPU history, right-aligned in one slot per sample, at the graphs' opacity
     * (_graphOpacity), and frees the context whatever happens (as the shell's own drawing areas do).
     *
     * @param {import('./lib/history.js').RingBuffer} cpuHistory - CPU busy fractions, oldest first.
     * @returns {void}
     */
    _paintCpuGraph(cpuHistory) {
        const slotFractions = padWithLeadingGaps(cpuHistory.values(), CARD_HISTORY_SAMPLES);
        const graphOpacity = this._graphOpacity();
        const fillRgba = withOpacity(CPU_GRAPH_RGBA, graphOpacity);
        const baselineRgba = withOpacity(BASELINE_RGBA, graphOpacity);
        const [widthPx, heightPx] = this._cpuGraph.get_surface_size();
        const cr = this._cpuGraph.get_context();
        try {
            drawAreaGraph(cr, widthPx, heightPx, slotFractions, fillRgba, baselineRgba);
        } finally {
            cr.$dispose();
        }
    }

    /**
     * Draws the memory bar at the fraction the last render gave it (the newest in the client's history then), at the
     * graphs' opacity (_graphOpacity), and frees the context whatever happens. With no data (none yet, a failed
     * sample, or no fresh Sample) the bar is all track.
     *
     * @returns {void}
     */
    _paintMemoryBar() {
        const graphOpacity = this._graphOpacity();
        const fillRgba = withOpacity(MEMORY_GRAPH_RGBA, graphOpacity);
        const trackRgba = withOpacity(USED_BAR_TRACK_RGBA, graphOpacity);
        const [widthPx, heightPx] = this._memoryBar.get_surface_size();
        const cr = this._memoryBar.get_context();
        try {
            drawUsedBar(cr, widthPx, heightPx, this._memoryBarFraction, fillRgba, trackRgba);
        } finally {
            cr.$dispose();
        }
    }

    /**
     * Draws one "waiting on" meter at its band, at the graphs' opacity (_graphOpacity), and frees the context whatever
     * happens.
     *
     * @param {{drawingArea: St.DrawingArea, band: 0|1|2|3|null}} pressureMeter - The meter being repainted.
     * @returns {void}
     */
    _paintPressureMeter(pressureMeter) {
        const graphOpacity = this._graphOpacity();
        const fillRgba = withOpacity(PRESSURE_METER_FILL_RGBA, graphOpacity);
        const trackRgba = withOpacity(PRESSURE_METER_TRACK_RGBA, graphOpacity);
        const [widthPx, heightPx] = pressureMeter.drawingArea.get_surface_size();
        const cr = pressureMeter.drawingArea.get_context();
        try {
            drawPressureMeter(cr, widthPx, heightPx, pressureMeter.band, fillRgba, trackRgba);
        } finally {
            cr.$dispose();
        }
    }

    /**
     * Removes the client listener, the one thing the card added outside itself. Runs on 'destroy', so it runs
     * however the card is destroyed.
     *
     * @returns {void}
     */
    _onDestroy() {
        if (this._snapshotListenerId !== null) {
            this._client.removeListener(this._snapshotListenerId);
            this._snapshotListenerId = null;
        }
        this._client = null;
    }
});
