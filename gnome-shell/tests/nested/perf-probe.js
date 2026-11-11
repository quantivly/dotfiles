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
// and a read with the extension enabled also answers the card's offscreen redirect ('ALWAYS', or the number).
//
// It never attaches to nothing and counts zero, which would read as a clean run: every count of zero means it looked
// and saw none. attach-enabled refuses, naming each missing part, and connects nothing; attach-disabled refuses while
// the extension still has parts; a read refuses when nothing is attached, or when the extension's parts are not the
// ones attached to (it was enabled or disabled during the window, so the counts are void). After the extension is
// enabled again its parts are new objects, and attach-enabled attaches to those; a handler on an older part counts
// nothing. Its state outlives each Eval in globalThis.__resourcePulsePerfProbe; the stage's handler is connected
// once and stays for the life of the nested shell, which is test-only. Its per-frame handler is itself a cost, which
// `perf`'s percentages include and say so.
//
// Requests: 'attach-disabled', 'attach-enabled' (each zeroes the counts), 'read'.
// Answers: {refused: string, missing?: string[]} on a refusal; otherwise
//   attach-disabled  {attached: 'disabled', counts: 'frames only: ...'}
//   attach-enabled   {attached: 'enabled', reattached: boolean}
//   read             {mode: 'disabled', frames} or {mode: 'enabled', frames, samples, topbarPaints, cardRedirect}

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
        extension: "the extension's object (Main.extensionManager.lookup(uuid).stateObj)",
        indicator: 'the top bar indicator (_indicator)',
        cpuGraphArea: "the top bar CPU graph's drawing area (_indicator._cpuGraph.drawingArea)",
        memoryGraphArea: "the top bar memory graph's drawing area (_indicator._memoryGraph.drawingArea)",
        card: 'the card, with get_offscreen_redirect (_card)',
        client: 'the client, with addHistoryListener (_client)',
    };
    /** The parts that exist only while the extension is enabled. */
    const ENABLED_ONLY_PART_NAMES = ['indicator', 'card', 'client'];
    /** The parts a window's counts belong to: any of them replaced means the extension was enabled again. */
    const ATTACHED_PART_NAMES = ['indicator', 'cpuGraphArea', 'memoryGraphArea', 'card', 'client'];

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
     * read: the counts since the last attach, refused when they no longer belong to the shell's parts.
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
        if (!areAttachedParts(parts))
            return {refused: "the extension's parts changed during the window (disabled or enabled again): its counts are void"};
        const cardRedirect = parts.card.get_offscreen_redirect();
        const alwaysRedirect = imports.gi.Clutter.OffscreenRedirect.ALWAYS;
        return {
            mode: ENABLED_MODE,
            frames: probe.counters.frames,
            samples: probe.counters.samples,
            topbarPaints: probe.counters.topbarPaints,
            cardRedirect: cardRedirect === alwaysRedirect ? ALWAYS_REDIRECT_NAME : String(cardRedirect),
        };
    }

    switch (request) {
    case 'attach-disabled':
        return attachDisabled();
    case 'attach-enabled':
        return attachEnabled();
    case 'read':
        return read();
    default:
        return {refused: `unknown request '${request}': attach-disabled, attach-enabled or read`};
    }
}
