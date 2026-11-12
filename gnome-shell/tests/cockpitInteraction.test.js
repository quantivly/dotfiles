// lib/cockpitInteraction.js: when the cockpit watch is wanted, when the desktop is interactive, which window a
// FocusSession reply activates, and what to do with the reply.
import {test, assertEqual} from './harness.js';
import * as interaction from '../extensions/resource-pulse@dotfiles/lib/cockpitInteraction.js';
import {COCKPIT_FOCUS_ERROR_CODES} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

test('cockpitInteraction: the watch is wanted while a card is visible outside the overview or the dropdown is open', () => {
    const watchWanted = (isAnyCockpitCardVisible, isDropdownOpen, isOverviewVisible) =>
        interaction.isCockpitWatchWanted({isAnyCockpitCardVisible, isDropdownOpen, isOverviewVisible});
    assertEqual(watchWanted(true, false, false), true);
    assertEqual(watchWanted(true, false, true), false);
    assertEqual(watchWanted(false, true, false), true);
    assertEqual(watchWanted(true, true, true), true);
    assertEqual(watchWanted(false, false, false), false);
});

test('cockpitInteraction: a showing DESKTOP window makes the desktop display-only', () => {
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: [{windowType: 'desktop', isShowing: true}]}), false);
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: [{windowType: 'normal', isShowing: true}]}), true);
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: []}), true);
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: [{windowType: 'desktop', isShowing: false}]}), true);
});

const WINDOWS = [
    {pid: 10, stackIndex: 0, isOnActiveWorkspace: false, isMinimized: false},
    {pid: 10, stackIndex: 2, isOnActiveWorkspace: true, isMinimized: true},
    {pid: 11, stackIndex: 3, isOnActiveWorkspace: true, isMinimized: false},
];

test('cockpitInteraction: the window pick prefers the active workspace, then the topmost, and is null without a match', () => {
    assertEqual(interaction.pickWindowToActivate({windows: WINDOWS, candidatePids: [10, 99]}), 2);
    assertEqual(interaction.pickWindowToActivate({windows: WINDOWS, candidatePids: [42]}), null);
    assertEqual(interaction.pickWindowToActivate({windows: WINDOWS, candidatePids: [10, 11]}), 3);
    assertEqual(interaction.pickWindowToActivate({windows: [], candidatePids: [10]}), null);
});

test('cockpitInteraction: the window pick takes the topmost window of a workspace-less match, and ignores minimization', () => {
    const offWorkspace = [
        {pid: 10, stackIndex: 1, isOnActiveWorkspace: false, isMinimized: false},
        {pid: 10, stackIndex: 4, isOnActiveWorkspace: false, isMinimized: false},
    ];
    assertEqual(interaction.pickWindowToActivate({windows: offWorkspace, candidatePids: [10]}), 4);
    const unminimized = WINDOWS.map(window => ({...window, isMinimized: false}));
    assertEqual(interaction.pickWindowToActivate({windows: unminimized, candidatePids: [10, 99]}), 2);
});

test('cockpitInteraction: the window pick prefers the active workspace even when an off-workspace window is higher in the stack', () => {
    const offWorkspaceHigher = [
        {pid: 10, stackIndex: 9, isOnActiveWorkspace: false, isMinimized: false},
        {pid: 11, stackIndex: 1, isOnActiveWorkspace: true, isMinimized: false},
    ];
    assertEqual(interaction.pickWindowToActivate({windows: offWorkspaceHigher, candidatePids: [10, 11]}), 1);
    assertEqual(interaction.pickWindowToActivate({windows: [...offWorkspaceHigher].reverse(), candidatePids: [10, 11]}), 1);
});

test('cockpitInteraction: the outcome activates on focused + picked, logs otherwise, never both; an error the ' +
    'protocol does not know is logged as "not focused", never as its own text', () => {
    const outcome = (reply, pickedStackIndex) => {
        const {activateWindow, logLine} = interaction.focusSessionOutcome({reply, pickedStackIndex});
        return {activateWindow, logLine};
    };
    assertEqual(outcome({focused: true, error: null, windowPidCandidates: [10]}, 2), {activateWindow: true, logLine: null});
    assertEqual(outcome({focused: true, error: null, windowPidCandidates: [10]}, 0), {activateWindow: true, logLine: null});
    assertEqual(outcome({focused: true, error: null, windowPidCandidates: [10, 11]}, null),
        {activateWindow: false, logLine: 'cockpit: focus: no window for pids [10, 11]'});
    assertEqual(outcome({focused: true, error: null, windowPidCandidates: []}, null),
        {activateWindow: false, logLine: 'cockpit: focus: no window for pids []'});
    assertEqual(outcome({focused: false, error: 'herdr-unreachable', windowPidCandidates: []}, 2),
        {activateWindow: false, logLine: 'cockpit: focus: herdr-unreachable'});
    assertEqual(outcome({focused: false, error: null, windowPidCandidates: []}, null),
        {activateWindow: false, logLine: 'cockpit: focus: not focused'});
    assertEqual(outcome({focused: false, error: 'a code from a later protocol', windowPidCandidates: []}, null),
        {activateWindow: false, logLine: 'cockpit: focus: not focused'});
});

// Each reason a click brings no window forward, with a reply that gives it (ruling D32: one journal line per reason).
const NOT_FOCUSED_REASON = 'not focused';
const NO_WINDOW_REASON = 'no window';
const FOCUS_OUTCOME_REASON_CASES = [
    ...COCKPIT_FOCUS_ERROR_CODES.map(errorCode => ({
        reason: errorCode, reply: {focused: false, error: errorCode, windowPidCandidates: []}, pickedStackIndex: null,
    })),
    {reason: NOT_FOCUSED_REASON, reply: {focused: false, error: null, windowPidCandidates: []}, pickedStackIndex: null},
    {reason: NO_WINDOW_REASON, reply: {focused: true, error: null, windowPidCandidates: [10, 11]}, pickedStackIndex: null},
];

/**
 * The template key a focus outcome's line is limited by (lib/errorLog.js).
 *
 * @param {{reply: object, pickedStackIndex: number|null}} focusOutcomeCase - The reply and the pick.
 * @returns {string|null|undefined} The outcome's logTemplateKey.
 */
function focusOutcomeLogTemplateKey({reply, pickedStackIndex}) {
    return interaction.focusSessionOutcome({reply, pickedStackIndex}).logTemplateKey;
}

test('cockpitInteraction: the outcome names the template key its line is limited by, one per reason: each focus ' +
    'error code, "not focused" for a reply with none, "no window" for a focused reply no window matches (its pids ' +
    'left out); none when it activates', () => {
    assertEqual({
        reasonKeys: FOCUS_OUTCOME_REASON_CASES.map(focusOutcomeLogTemplateKey),
        activated: focusOutcomeLogTemplateKey({
            reply: {focused: true, error: null, windowPidCandidates: [10]}, pickedStackIndex: 2,
        }),
    }, {
        reasonKeys: [
            'cockpit: focus: unknown-session', 'cockpit: focus: no-pane', 'cockpit: focus: herdr-rejected',
            'cockpit: focus: herdr-unreachable', 'cockpit: focus: internal', 'cockpit: focus: not focused',
            'cockpit: focus: no window',
        ],
        activated: null,
    });
});

test('cockpitInteraction: the outcome\'s template keys are bounded by its reasons: an error the protocol does not ' +
    'know, a focused reply\'s error, a reply without its focused field, and any other pids each read as one of them, ' +
    'never as a key of their own', () => {
    const reasonByLogTemplateKey = new Map(FOCUS_OUTCOME_REASON_CASES.map(focusOutcomeCase =>
        [focusOutcomeLogTemplateKey(focusOutcomeCase), focusOutcomeCase.reason]));
    const unusualCases = [
        {reply: {focused: false, error: 'a code from a later protocol', windowPidCandidates: []}, pickedStackIndex: null},
        {reply: {focused: false, error: 'HERDR-UNREACHABLE', windowPidCandidates: [10]}, pickedStackIndex: null},
        {reply: {focused: false, error: '', windowPidCandidates: []}, pickedStackIndex: null},
        {reply: {focused: null, error: null, windowPidCandidates: []}, pickedStackIndex: null},
        {reply: {focused: true, error: 'herdr-rejected', windowPidCandidates: [7]}, pickedStackIndex: null},
        {reply: {focused: true, error: null, windowPidCandidates: [1, 2, 3]}, pickedStackIndex: null},
        {reply: {focused: true, error: null}, pickedStackIndex: null},
        {reply: {focused: false, error: 'internal', windowPidCandidates: [5]}, pickedStackIndex: 3},
    ];
    assertEqual(unusualCases.map(unusualCase =>
        reasonByLogTemplateKey.get(focusOutcomeLogTemplateKey(unusualCase)) ?? null), [
        NOT_FOCUSED_REASON, NOT_FOCUSED_REASON, NOT_FOCUSED_REASON, NOT_FOCUSED_REASON, NO_WINDOW_REASON,
        NO_WINDOW_REASON, NO_WINDOW_REASON, 'internal',
    ]);
});

test('cockpitInteraction: DESKTOP_WINDOW_TYPE is the type name the glue gives a Meta.WindowType.DESKTOP window', () => {
    assertEqual(interaction.DESKTOP_WINDOW_TYPE, 'desktop');
    assertEqual(interaction.isDesktopInteractive({
        windowsOnMonitor: [{windowType: interaction.DESKTOP_WINDOW_TYPE, isShowing: true}],
    }), false);
});
