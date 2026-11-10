// lib/cockpitInteraction.js: when the cockpit watch is wanted, when the desktop is interactive, which window a
// FocusSession reply activates, and what to do with the reply.
import {test, assertEqual} from './harness.js';
import * as interaction from '../extensions/resource-pulse@dotfiles/lib/cockpitInteraction.js';

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

test('cockpitInteraction: the outcome activates on focused + picked, logs otherwise, never both', () => {
    const outcome = (reply, pickedStackIndex) => interaction.focusSessionOutcome({reply, pickedStackIndex});
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
});
