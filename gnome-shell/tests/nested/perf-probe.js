// Test tooling for scripts/resource-pulse-nested.sh `perf`, never loaded by the extension. The harness sends this
// file's text to the NESTED shell's Eval (org.gnome.Shell.Eval on the run's private bus), followed by one call of
// resourcePulsePerfProbe('<request>'), and reads the JSON of its answer. Ported from the performance session's
// probe.js, to the extension as it is now.
//
// Between an attach and a read it counts:
//   frames         the stage's after-paint, one per frame drawn
//   samples        with the extension enabled, the Samples its client appended to the histories
//                  (_client.addHistoryListener)
//   topbarPaints   with the extension enabled, the paints of the top bar's two graphs (the repaint signal of
//                  _indicator._cpuGraph.drawingArea and _indicator._memoryGraph.drawingArea; St emits it as the
//                  graph draws, mapped or not)
// and a read with the extension enabled also answers the card's offscreen redirect ('ALWAYS', or the number), and two
// facts as they are at the end of the window, so that `perf` can tell each state was set up as it is named: whether the
// card counts as visible (the extension's _isCardVisible) and whether the top bar indicator is mapped.
//
// It never attaches to nothing and counts zero, which would read as a clean run: every count of zero means it looked
// and saw none. attach-enabled refuses, naming each missing part, and connects nothing; attach-disabled refuses while
// the extension still has parts; a read refuses when nothing is attached, when the extension's parts are not the ones
// attached to (it was enabled or disabled during the window, so the counts are void), or when either fact cannot be
// read. After the extension is enabled again its parts are new objects, and attach-enabled attaches to those; a handler
// on an older part counts nothing. Its state outlives each Eval in globalThis.__resourcePulsePerfProbe; the stage's
// handler is connected once and stays for the life of the nested shell, which is test-only. Its per-frame handler is
// itself a cost, which `perf`'s percentages include and say so.
//
// The cockpit's grid (cockpitLayer.js) is drawn in every nested run, so a read-cockpit after an enabled read answers,
// as they are at the end of the window, what `perf` needs to tell the grid's states apart and to hold its budgets: the
// card ids that can be seen (the extension's _visibleCardIds), the card ids the layer draws (null with no layer), each
// part's offscreen redirect (the layer's own, and each drawn card's; ruling D12 wants ALWAYS on the data cards and none
// on the layer or the system cell's wrapper, whose adopted v2 card keeps its own), and the one-shot fallback timeouts
// armed now (the cover check's, the layer's pacing's, the dropdown's pacing's), which no state with Samples flowing may
// hold. Counting nothing, it attaches nothing; it refuses like a read, and also when a field it reads is not there.
//
// Requests: 'attach-disabled', 'attach-enabled' (each zeroes the counts), 'read', 'read-cockpit'.
// Answers: {refused: string, missing?: string[]} on a refusal; otherwise
//   attach-disabled  {attached: 'disabled', counts: 'frames only: ...'}
//   attach-enabled   {attached: 'enabled', reattached: boolean}
//   read             {mode: 'disabled', frames} or
//                    {mode: 'enabled', frames, samples, topbarPaints, cardRedirect, isCardVisible, isIndicatorMapped}
//   read-cockpit     {mode: 'enabled', visibleCardIds, layerCardIds, cockpitRedirects, armedCockpitTimers}: the ids
//                    sorted; layerCardIds and cockpitRedirects ({layer, <card id>...}: 'ALWAYS', 'NONE' or the
//                    number) null with no layer; armedCockpitTimers the names of the armed ones, in a fixed order

/**
 * Attaches the counters, zeroes them, or reads them, as one request asks.
 *
 * @param {string} request - 'attach-disabled', 'attach-enabled' or 'read'.
 * @returns {object} The answer (see the header), or {refused} naming why the request was refused.
 */
function resourcePulsePerfProbe(request) {
    const EXTENSION_UUID = 'resource-pulse@dotfiles';
    const PROBE_STATE_KEY = '__resourcePulsePerfProbe';
    const ALWAYS_REDIRECT_NAME = 'ALWAYS';
    const DISABLED_MODE = 'disabled';
    const ENABLED_MODE = 'enabled';
    /** Every part attach-enabled needs, in the order a refusal names them, and how it names each. */
    const PART_DESCRIPTIONS = {
        extension: "the extension's object, with _isCardVisible (Main.extensionManager.lookup(uuid).stateObj)",
        indicator: 'the top bar indicator, with mapped (_indicator)',
        cpuGraphArea: "the top bar CPU graph's drawing area (_indicator._cpuGraph.drawingArea)",
        memoryGraphArea: "the top bar memory graph's drawing area (_indicator._memoryGraph.drawingArea)",
        card: 'the card, with get_offscreen_redirect (_card)',
        client: 'the client, with addHistoryListener (_client)',
    };
    /** The parts that exist only while the extension is enabled. */
    const ENABLED_ONLY_PART_NAMES = ['indicator', 'card', 'client'];
    /** The parts a window's counts belong to: any of them replaced means the extension was enabled again. */
    const ATTACHED_PART_NAMES = ['indicator', 'cpuGraphArea', 'memoryGraphArea', 'card', 'client'];
    /** The parts a read takes its two facts from: the card's visibility from one, the mapping from the other. */
    const FACT_PART_NAMES = ['extension', 'indicator'];
    /** What read-cockpit names a redirect of none (Clutter's 0), which the layer and the system cell's wrapper want. */
    const NO_REDIRECT_NAME = 'NONE';
    /** The key read-cockpit answers the layer's own redirect under, beside each drawn card's id. */
    const LAYER_REDIRECT_KEY = 'layer';
    /**
     * The fields read-cockpit reads, by the object that holds them, and how a refusal names each. A field that is not
     * there at all (undefined) is a refusal: the extension changed shape, and reading on would answer nothing.
     */
    const COCKPIT_FIELD_DESCRIPTIONS = {
        extensionLayer: "the extension's cockpit layer field (_layer: the layer, or null with none)",
        extensionVisibleCardIds: "the extension's visible card ids (_visibleCardIds, an array)",
        extensionCoverFallback: "the extension's cover fallback timeout (_coverFallbackSourceId)",
        layerCards: "the layer's drawn card ids and cards (drawnCardIds, _cardsById)",
        layerRedirect: "the layer's offscreen redirect (get_offscreen_redirect)",
        layerPacing: "the layer's pacing and its fallback timeout (_pacing._fallbackSourceId)",
        dropdownPacing: "the dropdown's pacing (_indicator._sessionsPacing: the pacing, or null with no sessions item)",
    };
    /** The one-shot fallback timeouts read-cockpit names when armed, in the order it names them. */
    const COVER_FALLBACK_TIMER_NAME = 'cover-fallback';
    const LAYER_PACING_TIMER_NAME = 'layer-pacing-fallback';
    const DROPDOWN_PACING_TIMER_NAME = 'dropdown-pacing-fallback';

    globalThis[PROBE_STATE_KEY] ??= {
        counters: {frames: 0, samples: 0, topbarPaints: 0},
        isStageHooked: false,
        mode: null,
        attachedParts: null,
    };
    const probe = globalThis[PROBE_STATE_KEY];

    /**
     * The extension's parts as the shell holds them now; null for each one that is not there.
     *
     * @returns {Object<string, object|null>} The parts by name.
     */
    function findParts() {
        const extension = Main.extensionManager.lookup(EXTENSION_UUID)?.stateObj ?? null;
        const indicator = extension?._indicator ?? null;
        return {
            extension,
            indicator,
            cpuGraphArea: indicator?._cpuGraph?.drawingArea ?? null,
            memoryGraphArea: indicator?._memoryGraph?.drawingArea ?? null,
            card: extension?._card ?? null,
            client: extension?._client ?? null,
        };
    }

    /**
     * Whether a part is there and can be counted from.
     *
     * @param {string} partName - A key of PART_DESCRIPTIONS.
     * @param {object|null} part - The part.
     * @returns {boolean} True when it is usable.
     */
    function isUsablePart(partName, part) {
        if (part === null || part === undefined)
            return false;
        if (partName === 'extension')
            return typeof part._isCardVisible === 'boolean';
        if (partName === 'indicator')
            return typeof part.mapped === 'boolean';
        if (partName === 'cpuGraphArea' || partName === 'memoryGraphArea')
            return typeof part.connect === 'function';
        if (partName === 'card')
            return typeof part.get_offscreen_redirect === 'function';
        if (partName === 'client')
            return typeof part.addHistoryListener === 'function';
        return true;
    }

    /**
     * Whether the shell's parts now are the ones the counters were attached to.
     *
     * @param {Object<string, object|null>} parts - From findParts.
     * @returns {boolean} True when every attached part is still the shell's.
     */
    function areAttachedParts(parts) {
        return probe.attachedParts !== null &&
            ATTACHED_PART_NAMES.every(partName => probe.attachedParts[partName] === parts[partName]);
    }

    /**
     * Connects the frame counter to the stage, once for the life of the shell.
     *
     * @returns {void}
     */
    function hookStage() {
        if (probe.isStageHooked)
            return;
        global.stage.connect('after-paint', () => {
            probe.counters.frames++;
        });
        probe.isStageHooked = true;
    }

    /**
     * Zeroes every counter, in place (the handlers hold the probe, not the counters).
     *
     * @returns {void}
     */
    function zeroCounters() {
        probe.counters.frames = 0;
        probe.counters.samples = 0;
        probe.counters.topbarPaints = 0;
    }

    /**
     * Connects the Sample and paint counters to a fresh set of parts. Each handler counts only while its part is
     * still one of the attached ones, so a part from an earlier enable counts nothing.
     *
     * @param {Object<string, object|null>} parts - From findParts, every one usable.
     * @returns {void}
     */
    function attachToParts(parts) {
        const attachedParts = Object.fromEntries(ATTACHED_PART_NAMES.map(partName => [partName, parts[partName]]));
        probe.attachedParts = attachedParts;
        const isStillAttached = () => probe.attachedParts === attachedParts;
        for (const graphArea of [parts.cpuGraphArea, parts.memoryGraphArea]) {
            graphArea.connect('repaint', () => {
                if (isStillAttached())
                    probe.counters.topbarPaints++;
            });
        }
        parts.client.addHistoryListener(() => {
            if (isStillAttached())
                probe.counters.samples++;
        });
    }

    /**
     * attach-disabled: counts frames alone, once the extension has no parts left.
     *
     * @returns {object} The answer.
     */
    function attachDisabled() {
        const parts = findParts();
        const presentPartNames = ENABLED_ONLY_PART_NAMES.filter(partName => parts[partName] !== null);
        if (presentPartNames.length > 0) {
            const presentDescriptions = presentPartNames.map(partName => PART_DESCRIPTIONS[partName]).join('; ');
            return {refused: `the extension is not disabled: it still has ${presentDescriptions}`};
        }
        hookStage();
        probe.mode = DISABLED_MODE;
        probe.attachedParts = null;
        zeroCounters();
        return {
            attached: DISABLED_MODE,
            counts: 'frames only: with the extension disabled there is no client, top bar or card to count',
        };
    }

    /**
     * attach-enabled: refuses unless every part is there; attaches to them when they are new; zeroes the counts.
     *
     * @returns {object} The answer.
     */
    function attachEnabled() {
        const parts = findParts();
        const missing = Object.keys(PART_DESCRIPTIONS).filter(partName => !isUsablePart(partName, parts[partName]));
        if (missing.length > 0) {
            const missingDescriptions = missing.map(partName => PART_DESCRIPTIONS[partName]).join('; ');
            return {refused: `missing ${missingDescriptions}`, missing};
        }
        hookStage();
        const isReattaching = !areAttachedParts(parts);
        if (isReattaching)
            attachToParts(parts);
        probe.mode = ENABLED_MODE;
        zeroCounters();
        return {attached: ENABLED_MODE, reattached: isReattaching};
    }

    /**
     * read: the counts since the last attach, refused when they no longer belong to the shell's parts, and the two
     * facts as they are now, refused when either cannot be read.
     *
     * @returns {object} The answer.
     */
    function read() {
        const parts = findParts();
        if (probe.mode === DISABLED_MODE) {
            if (ENABLED_ONLY_PART_NAMES.some(partName => parts[partName] !== null))
                return {refused: 'the extension was enabled during the window: its counts are void'};
            return {mode: DISABLED_MODE, frames: probe.counters.frames};
        }
        if (probe.mode !== ENABLED_MODE)
            return {refused: 'nothing is attached: attach-disabled or attach-enabled comes before a read'};
        if (!areAttachedParts(parts)) {
            return {
                refused: "the extension's parts changed during the window (disabled or enabled again): " +
                    'its counts are void',
            };
        }
        const unreadable = FACT_PART_NAMES.filter(partName => !isUsablePart(partName, parts[partName]));
        if (unreadable.length > 0) {
            const unreadableDescriptions = unreadable.map(partName => PART_DESCRIPTIONS[partName]).join('; ');
            return {refused: `cannot read the state's facts from ${unreadableDescriptions}`, missing: unreadable};
        }
        const cardRedirect = parts.card.get_offscreen_redirect();
        const alwaysRedirect = imports.gi.Clutter.OffscreenRedirect.ALWAYS;
        return {
            mode: ENABLED_MODE,
            frames: probe.counters.frames,
            samples: probe.counters.samples,
            topbarPaints: probe.counters.topbarPaints,
            cardRedirect: cardRedirect === alwaysRedirect ? ALWAYS_REDIRECT_NAME : String(cardRedirect),
            isCardVisible: parts.extension._isCardVisible,
            isIndicatorMapped: parts.indicator.mapped,
        };
    }

    /**
     * The name read-cockpit gives an offscreen redirect.
     *
     * @param {number} redirect - What get_offscreen_redirect() answered.
     * @returns {string} 'ALWAYS', NO_REDIRECT_NAME for 0, or the number as text.
     */
    function redirectName(redirect) {
        if (redirect === imports.gi.Clutter.OffscreenRedirect.ALWAYS)
            return ALWAYS_REDIRECT_NAME;
        return redirect === 0 ? NO_REDIRECT_NAME : String(redirect);
    }

    /**
     * The cockpit fields read-cockpit cannot read, each by its COCKPIT_FIELD_DESCRIPTIONS key: the extension's, then,
     * with a layer, the layer's, then the dropdown's pacing field.
     *
     * @param {object} extension - The extension's object.
     * @param {object} indicator - The top bar indicator.
     * @returns {string[]} The keys of the fields that are not there; empty when every one can be read.
     */
    function missingCockpitFields(extension, indicator) {
        const layer = extension._layer;
        const missing = [];
        if (layer === undefined)
            missing.push('extensionLayer');
        if (!Array.isArray(extension._visibleCardIds))
            missing.push('extensionVisibleCardIds');
        if (extension._coverFallbackSourceId === undefined)
            missing.push('extensionCoverFallback');
        if (layer !== undefined && layer !== null) {
            if (!Array.isArray(layer.drawnCardIds) || typeof layer._cardsById?.get !== 'function')
                missing.push('layerCards');
            if (typeof layer.get_offscreen_redirect !== 'function')
                missing.push('layerRedirect');
            if (layer._pacing?._fallbackSourceId === undefined)
                missing.push('layerPacing');
        }
        const dropdownPacing = indicator._sessionsPacing;
        if (dropdownPacing === undefined || (dropdownPacing !== null && dropdownPacing._fallbackSourceId === undefined))
            missing.push('dropdownPacing');
        return missing;
    }

    /**
     * Each part of the grid's offscreen redirect: the layer's own under LAYER_REDIRECT_KEY, then each drawn card's under
     * its id, in the layer's order.
     *
     * @param {object} layer - The cockpit layer, every field it needs readable.
     * @returns {Object<string, string>} The redirects' names, by part.
     */
    function cockpitRedirects(layer) {
        const redirectsByPart = {[LAYER_REDIRECT_KEY]: redirectName(layer.get_offscreen_redirect())};
        for (const cardId of layer.drawnCardIds)
            redirectsByPart[cardId] = redirectName(layer._cardsById.get(cardId).get_offscreen_redirect());
        return redirectsByPart;
    }

    /**
     * The fallback timeouts armed now, by name, in a fixed order.
     *
     * @param {object} extension - The extension's object.
     * @param {object|null} layer - The cockpit layer, or null.
     * @param {object|null} dropdownPacing - The dropdown's pacing, or null.
     * @returns {string[]} The names of the armed ones.
     */
    function armedCockpitTimers(extension, layer, dropdownPacing) {
        const armedTimerNames = [];
        if (extension._coverFallbackSourceId !== null)
            armedTimerNames.push(COVER_FALLBACK_TIMER_NAME);
        if (layer !== null && layer._pacing._fallbackSourceId !== null)
            armedTimerNames.push(LAYER_PACING_TIMER_NAME);
        if (dropdownPacing !== null && dropdownPacing._fallbackSourceId !== null)
            armedTimerNames.push(DROPDOWN_PACING_TIMER_NAME);
        return armedTimerNames;
    }

    /**
     * read-cockpit: the grid's facts as they are now, refused like a read (nothing attached in the enabled mode, or the
     * parts changed since the attach) and when a field it reads is not there.
     *
     * @returns {object} The answer.
     */
    function readCockpit() {
        if (probe.mode !== ENABLED_MODE)
            return {refused: 'read-cockpit needs the enabled mode: attach-enabled comes before it'};
        const parts = findParts();
        if (!areAttachedParts(parts)) {
            return {
                refused: "the extension's parts changed during the window (disabled or enabled again): " +
                    'its facts are void',
            };
        }
        const missing = missingCockpitFields(parts.extension, parts.indicator);
        if (missing.length > 0) {
            const missingDescriptions = missing.map(fieldKey => COCKPIT_FIELD_DESCRIPTIONS[fieldKey]).join('; ');
            return {refused: `cannot read the cockpit's facts from ${missingDescriptions}`, missing};
        }
        const layer = parts.extension._layer;
        const dropdownPacing = parts.indicator._sessionsPacing;
        return {
            mode: ENABLED_MODE,
            visibleCardIds: [...parts.extension._visibleCardIds].sort(),
            layerCardIds: layer === null ? null : [...layer.drawnCardIds].sort(),
            cockpitRedirects: layer === null ? null : cockpitRedirects(layer),
            armedCockpitTimers: armedCockpitTimers(parts.extension, layer, dropdownPacing),
        };
    }

    switch (request) {
    case 'attach-disabled':
        return attachDisabled();
    case 'attach-enabled':
        return attachEnabled();
    case 'read':
        return read();
    case 'read-cockpit':
        return readCockpit();
    default:
        return {refused: `unknown request '${request}': attach-disabled, attach-enabled, read or read-cockpit`};
    }
}
