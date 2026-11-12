// The cockpit's four cards, stage one: system, apps, connections and sessions, each filling one cell of the grid the
// cockpit layer lays out. Shell glue only: every word, number, fraction, bar width, icon name, state class and row
// tooltip comes finished from lib/cockpitFormat.js (icon names from lib/constants.js COCKPIT_ICON_NAMES, through it),
// and the card only assigns them; the tooltip is the one CockpitTooltip (cockpitTooltip.js) a card is given: a card
// never makes one.
//
// - A card is a vertical box carrying the card surface (resource-pulse-card rp-cockpit-cell), built non-reactive. The
//   apps, connections and sessions cards draw through their own offscreen texture, so a window drawn over one paints
//   one rectangle; the system card asks for none, since the v2 card it adopts draws through its own and the cell
//   holds that one texture, not a copy of it. No card paints itself (no paint override, plain or node: ruling D12).
// - Its rows are built with it, one per row it can show, and reused: an update sets texts, icons, classes and bar
//   widths, each only when it changed, and hides the rows beyond the data. No update makes or destroys an actor. A
//   list with more than it can show ends in a '+N more' line (sessions, connections).
// - Frozen (a window covers it), an update is only recorded and no widget is touched; unfreezing draws the latest at
//   once, undimmed; repaintFrozen() draws it, still dimmed by the frozen pseudo-class (.resource-pulse-card:frozen).
// - Interactive (setInteractive) only while nothing covers the desktop: its rows then take the pointer, show their
//   tooltip on hover and, on the sessions card, take a click.
// - The system card wraps the v2 card (card.js) the extension owns and forwards all of this to it; on destroy it gives
//   that card back rather than destroy it. If the v2 card is destroyed first, the system card lets go of it and stays
//   an empty cell.
//
// Destroying a card hides the shared tooltip, which may point at one of its rows; its handlers go with it.
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {
    APPS_CARD_ROW_LIMIT, COCKPIT_LONG_IDLE_ROW_OPACITY, COCKPIT_ROW_BAR_TRACK_SHARE_OF_CELL_WIDTH,
    COCKPIT_ROW_ICON_SIZE_PX, COCKPIT_STATE_COUNT_SPACING_PX, CONNECTIONS_CARD_ROW_LIMIT, RESOURCES_APP_IDS,
    SESSIONS_CARD_ROW_LIMIT,
} from './lib/constants.js';
import {
    appsCardTitle, appsRows, canDrawApps, canDrawConnections, canDrawSessions, connectionsCardTitle, connectionsRows,
    herdrNotRunningText, noDataText, rowBarWidthPx, sessionRows, sessionsCardTitle, sessionsHeader, stateIconName,
    stateStyleClass,
} from './lib/cockpitFormat.js';
import {SESSION_STATES} from './lib/cockpitProtocol.js';

/** The card surface: the v2 card's look, dimmed under :frozen (resource-pulse-card), with no fixed width. */
const CELL_STYLE_CLASS = 'resource-pulse-card rp-cockpit-cell';
/** A row of a card, and the sessions header (both space their parts apart; only a row tracks hover). */
const ROW_STYLE_CLASS = 'rp-cockpit-row';
/** A row's faint bar, and the apps card's divider: a faint line (stylesheet.css). */
const ROW_BAR_STYLE_CLASS = 'rp-cockpit-row-bar';
const LONG_IDLE_ROW_STYLE_CLASS = 'rp-cockpit-row-long-idle';
const WAITING_NAME_STYLE_CLASS = 'rp-cockpit-name-waiting';
const NO_DATA_STYLE_CLASS = 'rp-cockpit-no-data';
/** A card's title, the sessions header's title and a list's "+N more": the v2 card's muted label colour. */
const MUTED_LABEL_STYLE_CLASS = 'resource-pulse-card-label';
/** The style pseudo-class a frozen card carries: .resource-pulse-card:frozen dims it. */
const FROZEN_PSEUDO_CLASS = 'frozen';
/** The opacity of every row that is not a long-idle session's. */
const OPAQUE_OPACITY = 255;
// St scales CSS lengths by the theme's scale factor, so the gap is set in CSS.
const STATE_COUNT_PAIR_STYLE = `spacing: ${COCKPIT_STATE_COUNT_SPACING_PX}px;`;
/**
 * What a card says with no source to draw (none received yet, or one missing a part the card draws): the no-data line
 * of a source never sampled, which reads no clock.
 */
const NO_SOURCE_TEXT = noDataText(null, null);

/**
 * @typedef {object} RowContent What one row shows.
 * @property {string|null} iconName - A COCKPIT_ICON_NAMES name; null hides the icon.
 * @property {string|null} iconStyleClass - The state class that colours the icon; null for none.
 * @property {string} name - The row's name; it ellipsizes when the row is short of room.
 * @property {string} firstValue - The first value; '' hides it.
 * @property {string} secondValue - The second value; '' hides it.
 * @property {number|null} fraction - The faint bar's share of its track, 0–1 (rowBarWidthPx clamps it); null for no
 *     bar.
 * @property {string[]} tooltipLines - What the tooltip says over the row.
 * @property {boolean} isLongIdle - A session idle long enough to dim.
 * @property {boolean} isWaiting - A session waiting on the user: its name is tinted.
 * @property {string|null} sessionId - The session a click on the row focuses; null for a row that takes no click.
 */

/** What a row shows before anything is given to it; each card's row content starts from it. */
const EMPTY_ROW_CONTENT = Object.freeze({
    iconName: null, iconStyleClass: null, name: '', firstValue: '', secondValue: '', fraction: null,
    tooltipLines: [], isLongIdle: false, isWaiting: false, sessionId: null,
});

/**
 * @typedef {object} CardRow One row of a card, built once and reused.
 * @property {St.BoxLayout} actor - The row: its icon, name, two values and the bar's track.
 * @property {St.Icon} icon - The state or connection icon.
 * @property {St.Label} nameLabel - The name.
 * @property {St.Label} firstValueLabel - The first value, never cut.
 * @property {St.Label} secondValueLabel - The second value, never cut.
 * @property {St.Widget} barTrack - A slot of fixed width for the bar, so a bar's change never moves the name.
 * @property {St.Widget} bar - The faint bar, as wide as its fraction of the track.
 * @property {number|null} barFraction - The fraction the bar shows; null for none.
 * @property {number} barWidthPx - The bar's width as last set.
 * @property {string|null} iconStyleClass - The state class the icon carries now.
 * @property {string[]} tooltipLines - What the tooltip says over the row now.
 * @property {string|null} sessionId - The session a click focuses now; null for none.
 */

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
 * Sets the text of a label that hides when it has none.
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
 * Adds a style class to an actor or removes it (St restyles only when the class list changes).
 *
 * @param {St.Widget} actor - The actor.
 * @param {string} styleClass - The class.
 * @param {boolean} isOn - True to add it, false to remove it.
 * @returns {void}
 */
function setStyleClass(actor, styleClass, isOn) {
    if (isOn)
        actor.add_style_class_name(styleClass);
    else
        actor.remove_style_class_name(styleClass);
}

/**
 * Makes a muted label: a card's title, the sessions header's title or a list's "+N more".
 *
 * @param {string} [text] - Its text.
 * @returns {St.Label} The label.
 */
function newMutedLabel(text = '') {
    return new St.Label({style_class: MUTED_LABEL_STYLE_CLASS, text, y_align: Clutter.ActorAlign.CENTER});
}

/**
 * Makes a row's name label, which takes the row's spare width and ellipsizes at its end when there is too little, so
 * the values beside it are never cut.
 *
 * @returns {St.Label} The label, with no text yet.
 */
function newNameLabel() {
    const nameLabel = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
    nameLabel.clutter_text.ellipsize = Pango.EllipsizeMode.END;
    return nameLabel;
}

/**
 * Makes a value label that never ellipsizes (St.Label does by default), so a number is never cut. The cell's
 * tabular numerals keep the digits from jittering.
 *
 * @param {object} [extraProperties] - More St.Label properties (an alignment, say).
 * @returns {St.Label} The label, with no text yet.
 */
function newValueLabel(extraProperties = {}) {
    const valueLabel = new St.Label({y_align: Clutter.ActorAlign.CENTER, ...extraProperties});
    valueLabel.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
    return valueLabel;
}

/**
 * Whether two lists of tooltip lines are the same.
 *
 * @param {string[]} lines - One list.
 * @param {string[]} otherLines - The other.
 * @returns {boolean} True when they hold the same lines in the same order.
 */
function areSameLines(lines, otherLines) {
    return lines.length === otherLines.length && lines.every((line, lineIndex) => line === otherLines[lineIndex]);
}

/**
 * What a row of the apps card shows: a name, its one value and bar, and its tooltip (appsRows gives each row its own
 * entry's group key).
 *
 * @param {string} name - The app's name.
 * @param {string} valueText - Its CPU share or memory.
 * @param {number} fraction - The bar's fraction.
 * @param {string[]} tooltipLines - The row's tooltip, from appsRows.
 * @returns {RowContent} The row's content.
 */
function appRowContent(name, valueText, fraction, tooltipLines) {
    return {...EMPTY_ROW_CONTENT, name, firstValue: valueText, fraction, tooltipLines};
}

/**
 * What a row of the connections card shows: lib/cockpitFormat.js's connections row.
 *
 * @param {{icon: string, text: string, tooltip: string[], fraction: number|null}} connectionRow - One row of
 *     connectionsRows.
 * @returns {RowContent} The row's content.
 */
function connectionRowContent(connectionRow) {
    return {
        ...EMPTY_ROW_CONTENT,
        iconName: connectionRow.icon,
        name: connectionRow.text,
        fraction: connectionRow.fraction,
        tooltipLines: connectionRow.tooltip,
    };
}

/**
 * What a row of the sessions card shows: lib/cockpitFormat.js's session row as it is (its icon, state class and
 * tooltip come with it), and its id for a click.
 *
 * @param {object} row - One row of sessionRows.
 * @returns {RowContent} The row's content.
 */
function sessionRowContent(row) {
    return {
        iconName: row.iconName,
        iconStyleClass: row.iconStyleClass,
        name: row.name,
        firstValue: row.idleText,
        secondValue: row.memoryText,
        fraction: row.memoryFraction,
        tooltipLines: row.tooltip,
        isLongIdle: row.isLongIdle,
        isWaiting: row.isWaiting,
        sessionId: row.id,
    };
}

/**
 * Finds the first system monitor installed, in RESOURCES_APP_IDS order.
 *
 * @returns {Shell.App|undefined} The app, or undefined when none is installed.
 */
export function findResourcesApp() {
    const appSystem = Shell.AppSystem.get_default();
    return RESOURCES_APP_IDS
        .map(appId => appSystem.lookup_app(appId))
        .find(app => app !== null);
}

/**
 * Opens the first system monitor installed and leaves the overview so it is seen: the dropdown's "Open Resources"
 * item and a click on the system card. With none installed it does nothing.
 *
 * @returns {void}
 */
export function openResourcesApp() {
    const resourcesApp = findResourcesApp();
    if (resourcesApp === undefined)
        return;
    resourcesApp.activate();
    Main.overview.hide();
}

/**
 * What every cockpit card shares: the cell's surface and size, the frozen state, the interactive state, the no-data
 * line, and rows with their hover tooltip and click. Each card defines update() with exactly what it draws (ruling
 * D9): the system card a pulse snapshot and its clock label, the apps card a snapshot's apps, the connections card
 * the network and mounts sources, the sessions card the sessions source.
 */
export const CockpitCardBase = GObject.registerClass(
class CockpitCardBase extends St.BoxLayout {
    /**
     * Builds the card, empty: each card adds its title and rows. It starts unfrozen and non-interactive.
     *
     * @param {object} options - The card's options.
     * @param {import('./cockpitTooltip.js').CockpitTooltip} options.tooltip - The tooltip every card shares; the card
     *     only calls its showFor() and hide().
     * @param {function(string): void|null} [options.onRowActivated] - Called with a row's session id when the row is
     *     clicked; null for a card whose rows take no click.
     * @param {string|null} [options.cellStyleClass] - The card's style classes: the cell surface, or null for a card
     *     that draws none of its own.
     * @param {boolean} [options.isDrawnThroughOwnTexture] - Whether the card draws through an offscreen texture of its
     *     own (Clutter.OffscreenRedirect.ALWAYS), so a window drawn over it paints one cached rectangle; false for a
     *     card whose only child already does, where a second texture would hold a copy of the first.
     * @returns {void}
     */
    _init({tooltip, onRowActivated = null, cellStyleClass = CELL_STYLE_CLASS, isDrawnThroughOwnTexture = true}) {
        super._init({
            style_class: cellStyleClass,
            orientation: Clutter.Orientation.VERTICAL,
            reactive: false,
        });
        if (isDrawnThroughOwnTexture)
            this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);
        // Every field _onDestroy reads is set before anything below can throw.
        this._tooltip = tooltip;
        this._onRowActivated = onRowActivated;
        /** @type {CardRow[]} */
        this._rows = [];
        this._isFrozen = false;
        /** @type {(function(): void)|null} The latest render, kept while frozen and run on the reveal. */
        this._latestRender = null;
        this._barTrackWidthPx = 0;
        this._contentBox = null;
        this._noDataLabel = null;
        this.connect('destroy', () => this._onDestroy());
    }

    /**
     * Sizes the card to its cell: its width, with every row's bar track (setCardWidth), then its height. A frozen card
     * is resized too: its place on the grid is not data.
     *
     * @param {number} widthPx - The cell's width.
     * @param {number} heightPx - The cell's height.
     * @returns {void}
     */
    setCellSize(widthPx, heightPx) {
        this.setCardWidth(widthPx);
        this.set_height(heightPx);
    }

    /**
     * Sets the card's width, and every row's bar track to its share of that width (redrawing each bar to the new
     * track); nothing more when the track's width is unchanged. Only the width: the dropdown gives its card the system
     * card's width and leaves the height to the card's content (ruling D29), and the grid sets the height as well
     * (setCellSize). A frozen card is resized too: its size is not data.
     *
     * @param {number} widthPx - The card's width.
     * @returns {void}
     */
    setCardWidth(widthPx) {
        this.set_width(widthPx);
        const barTrackWidthPx = Math.round(widthPx * COCKPIT_ROW_BAR_TRACK_SHARE_OF_CELL_WIDTH);
        if (barTrackWidthPx === this._barTrackWidthPx)
            return;
        this._barTrackWidthPx = barTrackWidthPx;
        for (const row of this._rows) {
            row.barTrack.set_width(barTrackWidthPx);
            this._showRowBar(row);
        }
    }

    /**
     * Freezes the card while a window covers it, or unfreezes it on the reveal. Freezing only dims it (the frozen
     * pseudo-class); unfreezing undims it and draws the latest update at once. Setting the state it has does nothing.
     *
     * @param {boolean} isFrozen - True while covered.
     * @returns {void}
     */
    setFrozen(isFrozen) {
        if (isFrozen === this._isFrozen)
            return;
        this._isFrozen = isFrozen;
        if (isFrozen) {
            this.add_style_pseudo_class(FROZEN_PSEUDO_CLASS);
            return;
        }
        this.remove_style_pseudo_class(FROZEN_PSEUDO_CLASS);
        this._latestRender?.();
    }

    /**
     * Draws a frozen card's latest update, still dimmed: the extension's frozen repaint, so a card misjudged as covered
     * reads as stale, never as live. Unfrozen it does nothing, since an unfrozen card draws every update already.
     *
     * @returns {void}
     */
    repaintFrozen() {
        if (this._isFrozen)
            this._latestRender?.();
    }

    /**
     * Lets the card and its rows take the pointer, or not: under a window or ding's desktop the card is display-only,
     * with no hover state and no click. A card that stops taking the pointer also hides the tooltip.
     *
     * @param {boolean} isInteractive - True while nothing covers the desktop.
     * @returns {void}
     */
    setInteractive(isInteractive) {
        this.reactive = isInteractive;
        for (const row of this._rows)
            row.actor.reactive = isInteractive;
        if (!isInteractive)
            this._tooltip.hide();
    }

    /**
     * Shows one muted line (lib/cockpitFormat.js's "no data" or "no data since HH:MM") in place of the card's data;
     * the title stays. Frozen, it is only recorded, as an update is.
     *
     * @param {string} text - The line.
     * @returns {void}
     */
    showNoData(text) {
        this._renderUnlessFrozen(() => this._renderNoData(text));
    }

    /**
     * Shows that herdr is not running, in place of the card's data.
     *
     * @returns {void}
     */
    showHerdrNotRunning() {
        this.showNoData(herdrNotRunningText);
    }

    /**
     * Records the card's latest render and runs it now unless the card is frozen: a frozen card touches no widget, and
     * the reveal (setFrozen) or the frozen repaint runs the latest.
     *
     * @param {function(): void} render - Draws what the card shows now.
     * @returns {void}
     */
    _renderUnlessFrozen(render) {
        this._latestRender = render;
        if (!this._isFrozen)
            render();
    }

    /**
     * Adds the box the card's data goes in, and below it the no-data line that replaces it.
     *
     * @returns {St.BoxLayout} The data box, for the card's rows.
     */
    _addContentBox() {
        this._contentBox = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL});
        this._noDataLabel = new St.Label({style_class: NO_DATA_STYLE_CLASS, visible: false});
        this.add_child(this._contentBox);
        this.add_child(this._noDataLabel);
        return this._contentBox;
    }

    /**
     * Shows the card's data or its no-data line, never both. No leave-event reaches a row hidden under the pointer
     * with the box that holds it, so hiding the data while one of this card's rows is hovered hides the tooltip. The
     * tooltip is shared and a no-data line is redrawn on every update, so it is hidden only as the box goes from shown
     * to hidden, and only for a row of this card.
     *
     * @param {boolean} isDataShown - True to show the data.
     * @returns {void}
     */
    _setDataShown(isDataShown) {
        if (!isDataShown && this._contentBox.visible && this._hasHoveredRow())
            this._tooltip.hide();
        this._contentBox.visible = isDataShown;
        this._noDataLabel.visible = !isDataShown;
    }

    /**
     * Whether one of the card's shown rows is under the pointer (a row hidden already may keep a stale hover).
     *
     * @returns {boolean} True when a visible row is hovered.
     */
    _hasHoveredRow() {
        return this._rows.some(row => row.actor.visible && row.actor.hover);
    }

    /**
     * Draws the no-data line in place of the data.
     *
     * @param {string} text - The line.
     * @returns {void}
     */
    _renderNoData(text) {
        this._setDataShown(false);
        setLabelText(this._noDataLabel, text);
    }

    /**
     * Builds one row, hidden until it is given content: an icon, a name, two values and the faint bar in its track.
     * It is built non-reactive (setInteractive makes it take the pointer) and tracks hover for its :hover style. Its
     * handlers are tied to the card, so they go when the card does.
     *
     * @param {St.BoxLayout} rowsBox - Where the row goes.
     * @returns {CardRow} The row.
     */
    _buildRow(rowsBox) {
        const row = {
            actor: new St.BoxLayout({style_class: ROW_STYLE_CLASS, reactive: false, track_hover: true, visible: false}),
            icon: new St.Icon({
                icon_size: COCKPIT_ROW_ICON_SIZE_PX, y_align: Clutter.ActorAlign.CENTER, visible: false,
            }),
            nameLabel: newNameLabel(),
            firstValueLabel: newValueLabel(),
            secondValueLabel: newValueLabel(),
            barTrack: new St.Widget({layout_manager: new Clutter.BinLayout(), width: this._barTrackWidthPx}),
            bar: new St.Widget({
                style_class: ROW_BAR_STYLE_CLASS, width: 0,
                x_align: Clutter.ActorAlign.START, y_align: Clutter.ActorAlign.CENTER,
            }),
            barFraction: null,
            barWidthPx: 0,
            iconStyleClass: null,
            tooltipLines: [],
            sessionId: null,
        };
        row.barTrack.add_child(row.bar);
        for (const rowPart of [row.icon, row.nameLabel, row.firstValueLabel, row.secondValueLabel, row.barTrack])
            row.actor.add_child(rowPart);
        row.actor.connectObject(
            'enter-event', () => this._onRowEntered(row),
            'leave-event', () => this._onRowLeft(),
            'button-release-event', (_actor, event) => this._onRowReleased(row, event),
            this);
        rowsBox.add_child(row.actor);
        this._rows.push(row);
        return row;
    }

    /**
     * Shows content in a row, setting each part only when it changed. A row under the pointer whose tooltip changed
     * (another session moved to its place, say) updates the tooltip, so the tooltip always describes what a click acts
     * on.
     *
     * @param {CardRow} row - The row.
     * @param {RowContent} content - What it shows.
     * @returns {void}
     */
    _showRow(row, content) {
        row.actor.visible = true;
        this._showRowIcon(row, content.iconName, content.iconStyleClass);
        setLabelText(row.nameLabel, content.name);
        setOptionalLabelText(row.firstValueLabel, content.firstValue);
        setOptionalLabelText(row.secondValueLabel, content.secondValue);
        row.barFraction = content.fraction;
        this._showRowBar(row);
        this._showRowState(row, content);
        if (row.actor.hover && !areSameLines(row.tooltipLines, content.tooltipLines))
            this._tooltip.showFor(row.actor, content.tooltipLines);
        row.tooltipLines = content.tooltipLines;
        row.sessionId = content.sessionId;
    }

    /**
     * Shows a row's icon and its state class, or hides the icon for a row with none.
     *
     * @param {CardRow} row - The row.
     * @param {string|null} iconName - A COCKPIT_ICON_NAMES name, or null.
     * @param {string|null} iconStyleClass - The state class that colours it, or null.
     * @returns {void}
     */
    _showRowIcon(row, iconName, iconStyleClass) {
        row.icon.visible = iconName !== null;
        if (iconName !== null && row.icon.icon_name !== iconName)
            row.icon.icon_name = iconName;
        if (iconStyleClass === row.iconStyleClass)
            return;
        if (row.iconStyleClass !== null)
            row.icon.remove_style_class_name(row.iconStyleClass);
        if (iconStyleClass !== null)
            row.icon.add_style_class_name(iconStyleClass);
        row.iconStyleClass = iconStyleClass;
    }

    /**
     * Dims a long-idle session's row and tints a waiting session's name. St reads no CSS opacity (ruling D8), so the
     * long-idle class is a hook and the dim is the row actor's opacity; every other row is opaque.
     *
     * @param {CardRow} row - The row.
     * @param {{isLongIdle: boolean, isWaiting: boolean}} content - The row's session flags.
     * @returns {void}
     */
    _showRowState(row, {isLongIdle, isWaiting}) {
        setStyleClass(row.actor, LONG_IDLE_ROW_STYLE_CLASS, isLongIdle);
        setStyleClass(row.nameLabel, WAITING_NAME_STYLE_CLASS, isWaiting);
        const rowOpacity = isLongIdle ? COCKPIT_LONG_IDLE_ROW_OPACITY : OPAQUE_OPACITY;
        if (row.actor.opacity !== rowOpacity)
            row.actor.opacity = rowOpacity;
    }

    /**
     * Sets a row's bar to the width lib/cockpitFormat.js gives its fraction on this card's track, only when that width
     * changed. A row with no fraction has an empty bar.
     *
     * @param {CardRow} row - The row.
     * @returns {void}
     */
    _showRowBar(row) {
        const barWidthPx = rowBarWidthPx(row.barFraction, this._barTrackWidthPx);
        if (barWidthPx === row.barWidthPx)
            return;
        row.bar.set_width(barWidthPx);
        row.barWidthPx = barWidthPx;
    }

    /**
     * Hides every row from an index on; a hidden row keeps its actors, for the next update to reuse. No leave-event
     * reaches a row hidden under the pointer, so hiding a hovered row hides the tooltip it may be showing; a row hidden
     * already is left alone, so a stale hover on it never hides another row's tooltip.
     *
     * @param {CardRow[]} rows - A card's rows of one list.
     * @param {number} firstHiddenIndex - The first row with nothing to show.
     * @returns {void}
     */
    _hideRowsFrom(rows, firstHiddenIndex) {
        for (const row of rows.slice(firstHiddenIndex)) {
            if (row.actor.visible && row.actor.hover)
                this._tooltip.hide();
            row.actor.visible = false;
        }
    }

    /**
     * Shows the row's tooltip after the shared tooltip's delay.
     *
     * @param {CardRow} row - The row the pointer entered.
     * @returns {boolean} Clutter.EVENT_PROPAGATE: the card may see the crossing too.
     */
    _onRowEntered(row) {
        if (row.tooltipLines.length > 0)
            this._tooltip.showFor(row.actor, row.tooltipLines);
        return Clutter.EVENT_PROPAGATE;
    }

    /**
     * Hides the tooltip as the pointer leaves a row.
     *
     * @returns {boolean} Clutter.EVENT_PROPAGATE.
     */
    _onRowLeft() {
        this._tooltip.hide();
        return Clutter.EVENT_PROPAGATE;
    }

    /**
     * Activates the row's session on a primary-button release; any other row, or button, does nothing.
     *
     * @param {CardRow} row - The row released over.
     * @param {Clutter.Event} event - The release.
     * @returns {boolean} Clutter.EVENT_STOP once a session is activated, else Clutter.EVENT_PROPAGATE.
     */
    _onRowReleased(row, event) {
        if (row.sessionId === null || this._onRowActivated === null || event.get_button() !== Clutter.BUTTON_PRIMARY)
            return Clutter.EVENT_PROPAGATE;
        this._onRowActivated(row.sessionId);
        return Clutter.EVENT_STOP;
    }

    /**
     * Hides the shared tooltip, which may point at one of the card's rows, and drops what the card was given. Runs on
     * 'destroy', so it runs however the card is destroyed; the rows' handlers go with the rows.
     *
     * @returns {void}
     */
    _onDestroy() {
        this._tooltip?.hide();
        this._tooltip = null;
        this._onRowActivated = null;
        this._latestRender = null;
    }
});

export const SystemCockpitCard = GObject.registerClass(
class SystemCockpitCard extends CockpitCardBase {
    /**
     * Adopts the extension's v2 card (card.js PulseCard) into the system cell. The cell draws one surface: the v2
     * card keeps its own (resource-pulse-card, which its frozen dim reads), and this wrapper draws none. It holds one
     * texture too: the v2 card draws through its own offscreen texture, and this wrapper asks for none, which would
     * only hold a copy of it. A click on it, while interactive, opens Resources.
     *
     * @param {object} options - The card's options.
     * @param {import('./card.js').PulseCard} options.pulseCard - The v2 card; the extension owns it and destroys it.
     * @param {import('./cockpitTooltip.js').CockpitTooltip} options.tooltip - The shared tooltip (the system card has
     *     no row of its own to show it for).
     * @returns {void}
     */
    _init({pulseCard, tooltip}) {
        super._init({tooltip, cellStyleClass: null, isDrawnThroughOwnTexture: false});
        this._pulseCard = pulseCard;
        this._adoptPulseCard();
        this.connect('button-release-event', (_actor, event) => this._onCardReleased(event));
    }

    /**
     * Takes the v2 card out of wherever it is (the background group, top right) and into this cell, which lays it out
     * from now on: a fixed position left from its top-right placement would override the cell's layout. A handler
     * tied to this card lets go of the v2 card if the extension destroys it first.
     *
     * @returns {void}
     */
    _adoptPulseCard() {
        const pulseCard = this._pulseCard;
        pulseCard.get_parent()?.remove_child(pulseCard);
        pulseCard.fixed_position_set = false;
        this.add_child(pulseCard);
        pulseCard.connectObject('destroy', () => this._onPulseCardDestroyed(), this);
    }

    /**
     * Lets go of a v2 card destroyed before this card: from now on the cell is empty, every forward does nothing, and
     * this card's destroy does not touch it. The v2 card's handlers go with it.
     *
     * @returns {void}
     */
    _onPulseCardDestroyed() {
        this._pulseCard = null;
    }

    /**
     * Gives the v2 card back: releases the destroy handler on it and takes it out of the cell, unparented, for the
     * extension to destroy or put back top right. Does nothing once the v2 card is gone.
     *
     * @returns {void}
     */
    _releasePulseCard() {
        const pulseCard = this._pulseCard ?? null;
        if (pulseCard === null)
            return;
        this._pulseCard = null;
        pulseCard.disconnectObject(this);
        if (pulseCard.get_parent() === this)
            this.remove_child(pulseCard);
    }

    /**
     * Sizes the cell and the v2 card inside it to the grid's cell.
     *
     * @param {number} widthPx - The cell's width.
     * @param {number} heightPx - The cell's height.
     * @returns {void}
     */
    setCellSize(widthPx, heightPx) {
        this.set_size(widthPx, heightPx);
        this._pulseCard?.setCellSize(widthPx, heightPx);
    }

    /**
     * Shows a pulse snapshot: the v2 card's own update.
     *
     * @param {import('./pulseClient.js').Snapshot|null} snapshot - The latest snapshot, or null before the first.
     * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data, for "no data since".
     * @returns {void}
     */
    update(snapshot, lastGoodClockLabel) {
        this._pulseCard?.update(snapshot, lastGoodClockLabel);
    }

    /**
     * Freezes or unfreezes the v2 card, which dims and repaints itself.
     *
     * @param {boolean} isFrozen - True while covered.
     * @returns {void}
     */
    setFrozen(isFrozen) {
        this._pulseCard?.setFrozen(isFrozen);
    }

    /**
     * The v2 card's frozen repaint.
     *
     * @returns {void}
     */
    repaintFrozen() {
        this._pulseCard?.repaintFrozen();
    }

    /**
     * Does nothing: the system card's source is the sampler, not the cockpit service, and the v2 card draws its own
     * "no data" from a snapshot with none.
     *
     * @param {string} _text - Unused.
     * @returns {void}
     */
    showNoData(_text) {
        // The v2 card says "no data" itself.
    }

    /**
     * Opens Resources on a primary-button release (the card takes the pointer only while interactive).
     *
     * @param {Clutter.Event} event - The release.
     * @returns {boolean} Clutter.EVENT_STOP once handled, else Clutter.EVENT_PROPAGATE.
     */
    _onCardReleased(event) {
        if (event.get_button() !== Clutter.BUTTON_PRIMARY)
            return Clutter.EVENT_PROPAGATE;
        openResourcesApp();
        return Clutter.EVENT_STOP;
    }

    /**
     * Gives the v2 card back before the cell's children are destroyed (a 'destroy' handler runs before Clutter
     * destroys the children), so the extension, its owner, still destroys it in its own teardown or puts it back top
     * right.
     *
     * @returns {void}
     */
    _onDestroy() {
        this._releasePulseCard();
        super._onDestroy();
    }
});

export const AppsCockpitCard = GObject.registerClass(
class AppsCockpitCard extends CockpitCardBase {
    /**
     * Builds the title, APPS_CARD_ROW_LIMIT rows for the CPU ranking, a divider and as many for the memory ranking. No
     * row takes a click; each row's tooltip is its group key. Shows no data until the first update.
     *
     * @param {object} options - The card's options.
     * @param {import('./cockpitTooltip.js').CockpitTooltip} options.tooltip - The shared tooltip.
     * @returns {void}
     */
    _init({tooltip}) {
        super._init({tooltip});
        this.add_child(newMutedLabel(appsCardTitle));
        const rowsBox = this._addContentBox();
        this._cpuRows = Array.from({length: APPS_CARD_ROW_LIMIT}, () => this._buildRow(rowsBox));
        rowsBox.add_child(new St.Widget({style_class: ROW_BAR_STYLE_CLASS, x_expand: true}));
        this._memoryRows = Array.from({length: APPS_CARD_ROW_LIMIT}, () => this._buildRow(rowsBox));
        this.showNoData(NO_SOURCE_TEXT);
    }

    /**
     * Shows the sampler's apps rankings (lib/protocol.js parseAppRanking, in the pulse snapshot).
     *
     * @param {{cpuRanking: Array<object>|null, memoryRanking: Array<object>|null}|null} apps - The snapshot's apps;
     *     null shows no data.
     * @returns {void}
     */
    update(apps) {
        if (!canDrawApps(apps)) {
            this.showNoData(NO_SOURCE_TEXT);
            return;
        }
        this._renderUnlessFrozen(() => this._renderApps(apps));
    }

    /**
     * Draws both rankings, hiding the rows beyond each.
     *
     * @param {{cpuRanking: Array<object>|null, memoryRanking: Array<object>|null}} apps - The snapshot's apps.
     * @returns {void}
     */
    _renderApps(apps) {
        this._setDataShown(true);
        const {cpu, memory} = appsRows(apps);
        cpu.forEach((entry, rowIndex) => this._showRow(this._cpuRows[rowIndex],
            appRowContent(entry.name, entry.cpuText, entry.cpuFraction, entry.tooltip)));
        this._hideRowsFrom(this._cpuRows, cpu.length);
        memory.forEach((entry, rowIndex) => this._showRow(this._memoryRows[rowIndex],
            appRowContent(entry.name, entry.memoryText, entry.memoryFraction, entry.tooltip)));
        this._hideRowsFrom(this._memoryRows, memory.length);
    }
});

export const ConnectionsCockpitCard = GObject.registerClass(
class ConnectionsCockpitCard extends CockpitCardBase {
    /**
     * Builds the title, CONNECTIONS_CARD_ROW_LIMIT rows (uplink, VPN, ssh masters, then the mounts) and the "+N more"
     * line for the mounts that do not fit. No row takes a click; each row's tooltip is its details. Shows no data
     * until the first update.
     *
     * @param {object} options - The card's options.
     * @param {import('./cockpitTooltip.js').CockpitTooltip} options.tooltip - The shared tooltip.
     * @returns {void}
     */
    _init({tooltip}) {
        super._init({tooltip});
        this.add_child(newMutedLabel(connectionsCardTitle));
        const rowsBox = this._addContentBox();
        this._connectionRows = Array.from({length: CONNECTIONS_CARD_ROW_LIMIT}, () => this._buildRow(rowsBox));
        this._overflowLabel = newMutedLabel();
        rowsBox.add_child(this._overflowLabel);
        this.showNoData(NO_SOURCE_TEXT);
    }

    /**
     * Shows the network and mounts sources; either missing (or missing a part the card draws) shows no data.
     *
     * @param {object|null} network - The network source.
     * @param {object|null} mounts - The mounts source.
     * @returns {void}
     */
    update(network, mounts) {
        if (!canDrawConnections(network, mounts)) {
            this.showNoData(NO_SOURCE_TEXT);
            return;
        }
        this._renderUnlessFrozen(() => this._renderConnections(network, mounts));
    }

    /**
     * Draws the connections rows (at most CONNECTIONS_CARD_ROW_LIMIT, as connectionsRows gives them), hides the rest,
     * and says "+N more" for the mounts that did not fit.
     *
     * @param {object} network - The network source.
     * @param {object} mounts - The mounts source.
     * @returns {void}
     */
    _renderConnections(network, mounts) {
        this._setDataShown(true);
        const {rows, overflowText} = connectionsRows(network, mounts);
        rows.forEach((connectionRow, rowIndex) =>
            this._showRow(this._connectionRows[rowIndex], connectionRowContent(connectionRow)));
        this._hideRowsFrom(this._connectionRows, rows.length);
        setOptionalLabelText(this._overflowLabel, overflowText ?? '');
    }
});

export const SessionsCockpitCard = GObject.registerClass(
class SessionsCockpitCard extends CockpitCardBase {
    /**
     * Builds the header (SESSIONS, the count, the five state icons with counts, the bucket total),
     * SESSIONS_CARD_ROW_LIMIT rows and the "+N more" line. A row's click activates its session. Shows no data until
     * the first update.
     *
     * @param {object} options - The card's options.
     * @param {import('./cockpitTooltip.js').CockpitTooltip} options.tooltip - The shared tooltip.
     * @param {function(string): void} options.onRowActivated - Called with a row's session id on a click.
     * @returns {void}
     */
    _init({tooltip, onRowActivated}) {
        super._init({tooltip, onRowActivated});
        this._buildHeader();
        const rowsBox = this._addContentBox();
        this._sessionRows = Array.from({length: SESSIONS_CARD_ROW_LIMIT}, () => this._buildRow(rowsBox));
        this._overflowLabel = newMutedLabel();
        rowsBox.add_child(this._overflowLabel);
        this.showNoData(NO_SOURCE_TEXT);
    }

    /**
     * Shows the sessions source: "herdr not running" when herdr is down, no data when the source (or a part the card
     * draws) is missing.
     *
     * @param {object|null} sessions - The sessions source.
     * @returns {void}
     */
    update(sessions) {
        if (sessions?.herdrRunning === false) {
            this.showHerdrNotRunning();
            return;
        }
        if (!canDrawSessions(sessions)) {
            this.showNoData(NO_SOURCE_TEXT);
            return;
        }
        this._renderUnlessFrozen(() => this._renderSessions(sessions));
    }

    /**
     * Builds the header: the title, which stays with no data, then its details, which hide with the data.
     *
     * @returns {void}
     */
    _buildHeader() {
        const headerBox = new St.BoxLayout({style_class: ROW_STYLE_CLASS});
        headerBox.add_child(newMutedLabel(sessionsCardTitle));
        this._headerDetailsBox = new St.BoxLayout({style_class: ROW_STYLE_CLASS, x_expand: true});
        this._sessionCountLabel = newValueLabel();
        this._headerDetailsBox.add_child(this._sessionCountLabel);
        this._stateCountLabels = SESSION_STATES.map(state => this._addStateCount(state));
        this._totalMemoryLabel = newValueLabel({x_expand: true, x_align: Clutter.ActorAlign.END});
        this._headerDetailsBox.add_child(this._totalMemoryLabel);
        headerBox.add_child(this._headerDetailsBox);
        this.add_child(headerBox);
    }

    /**
     * Adds one state's icon, coloured by its state class, and its count to the header.
     *
     * @param {string} state - One of SESSION_STATES.
     * @returns {St.Label} The count's label.
     */
    _addStateCount(state) {
        const stateCountBox = new St.BoxLayout({style: STATE_COUNT_PAIR_STYLE});
        stateCountBox.add_child(new St.Icon({
            icon_name: stateIconName(state), icon_size: COCKPIT_ROW_ICON_SIZE_PX, style_class: stateStyleClass(state),
            y_align: Clutter.ActorAlign.CENTER,
        }));
        const stateCountLabel = newValueLabel();
        stateCountBox.add_child(stateCountLabel);
        this._headerDetailsBox.add_child(stateCountBox);
        return stateCountLabel;
    }

    /**
     * Shows the data or the no-data line; the header's details go with the data.
     *
     * @param {boolean} isDataShown - True to show the data.
     * @returns {void}
     */
    _setDataShown(isDataShown) {
        super._setDataShown(isDataShown);
        this._headerDetailsBox.visible = isDataShown;
    }

    /**
     * Draws the header, the visible rows (hiding the rest) and "+N more".
     *
     * @param {object} sessions - The sessions source.
     * @returns {void}
     */
    _renderSessions(sessions) {
        this._setDataShown(true);
        this._showHeader(sessionsHeader(sessions));
        const {rows, overflowText} = sessionRows(sessions);
        rows.forEach((row, rowIndex) => this._showRow(this._sessionRows[rowIndex], sessionRowContent(row)));
        this._hideRowsFrom(this._sessionRows, rows.length);
        setOptionalLabelText(this._overflowLabel, overflowText ?? '');
    }

    /**
     * Shows the header's count, each state's count and the bucket total, as sessionsHeader writes them.
     *
     * @param {{count: string, counts: Array<{state: string, count: string}>, totalMemory: string}} header - The
     *     header's parts, the counts in SESSION_STATES order (the order the state labels were built in).
     * @returns {void}
     */
    _showHeader(header) {
        setLabelText(this._sessionCountLabel, header.count);
        header.counts.forEach(({count}, stateIndex) => setLabelText(this._stateCountLabels[stateIndex], count));
        setLabelText(this._totalMemoryLabel, header.totalMemory);
    }
});
