#!/usr/bin/env python3
"""Count Wi-Fi disconnects by cause, to show whether the dock Wi-Fi guard works.

The guard (scripts/dock-wifi.sh) turns the radio OFF while a wired link is up.
NetworkManager then tears the association down, and wpa_supplicant logs that as
`CTRL-EVENT-DISCONNECTED ... reason=3 locally_generated=1`: the same line a real
drop produces. So counting every CTRL-EVENT-DISCONNECTED (what the week-one
check did) counts the guard's own action as the failure it prevents, and adds
every undocked drop and every suspend to it. Measured 2026-11-10: that count said
61 and 31 for the two weeks after the guard went in, and the number of drops
while docked with Wi-Fi still on was 0 in both. Record: docs/DOCK_WIFI.md.

Each disconnect is put in exactly one class, tested in this order:

  radio-off  within TOGGLE_WINDOW_S of `nmcli radio wifi off` (NetworkManager's
             `op="radio-control" arg="wireless-enabled:off"` audit line). That
             line is logged AFTER the radio is off, so the disconnect it causes
             comes FIRST, by about 100 ms: the window is two-sided.
  sleep      within SLEEP_WINDOW_S after `sleep requested` or `caught SIGTERM`.
  unknown    no wired-device transition or NetworkManager start seen yet, so
             whether a wired link was up cannot be said.
  docked     a wired device was `activated`: a drop while docked with Wi-Fi on,
             which is what the guard exists to remove. Should be 0.
  undocked   no wired device was `activated`.

READ-ONLY. It runs journalctl and prints. It never touches the radio.

The wired state at the start of the window comes from the journal before it:
the query reaches LOOKBACK_DAYS further back. A device's first transition also
says what it was before (`activated -> unmanaged` means it was up), and a
NetworkManager start means every device starts from nothing.

Usage:
    dock-wifi-report.py [--days N] [--list] [--journal-file FILE]

    --list               also print one line per disconnect: time, class, and
                         wpa_supplicant's own text (bssid, reason code)
    --journal-file FILE  read FILE (journalctl -o short-iso-precise output)
                         instead of running journalctl; the state table's seam
    DOCK_WIFI_REPORT_NOW=<epoch seconds> pins the end of the window, for tests

Exit codes:
    0  printed a report
    2  COULD NOT RUN: journalctl failed or could not see the system journal, no
       NetworkManager line in the span, or lines that did not parse. Never a
       pass: "0 docked drops" and "I could not read the journal" must not print
       the same thing.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta

DEFAULT_DAYS = 7
LOOKBACK_DAYS = 7
# Measured 2026-11-10 on 37 toggles: the disconnect precedes the audit line by
# about 100 ms, and never by a second. Two seconds covers second-resolution logs.
TOGGLE_WINDOW_S = 2
# Measured: the suspend and shutdown disconnects land in the same second as
# NetworkManager's `sleep requested` / `caught SIGTERM`.
SLEEP_WINDOW_S = 10
JOURNALCTL_TIMEOUT_S = 60
JOURNAL_UNITS = ("NetworkManager.service", "wpa_supplicant.service")

CLASS_RADIO_OFF = "radio-off"
CLASS_SLEEP = "sleep"
CLASS_UNKNOWN = "unknown"
CLASS_DOCKED = "docked"
CLASS_UNDOCKED = "undocked"
CLASS_LABELS = (
    (CLASS_DOCKED, "docked, Wi-Fi still on", "what the guard removes; 0 when it works"),
    (CLASS_RADIO_OFF, "radio switched off", "the guard's own toggle at a dock event"),
    (CLASS_UNDOCKED, "undocked", "ordinary Wi-Fi drops, out of the guard's scope"),
    (CLASS_SLEEP, "at suspend or shutdown", ""),
    (CLASS_UNKNOWN, "wired state unknown", "no wired transition seen before it"),
)

# journalctl -o short-iso-precise: '2026-11-10T12:20:20.896027+02:00 host ident[pid]: msg'.
# Older systemd prints '+0200'; %z accepts both. The offset is PARSED, never
# matched: a pinned offset reads zero events after a DST change.
JOURNAL_LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:?\d{2}) \S+ (?P<ident>[^\[:]+)"
)
# Wired devices by name: predictable ethernet names (en*), legacy eth*, and usb*
# (RNDIS tethering). Only an activation with `managed-type: 'full'` counts as a
# wired link coming up: docker's bridges and the VPN's tun0 reach `activated` as
# 'external'. Leaving `activated` counts WHATEVER the managed-type: the undock
# line is `activated -> unmanaged (... managed-type: 'removed')`, and filtering
# it on 'full' kept a long-gone dock "up" for days (42 undocked drops read as
# docked, 2026-11-10).
FULLY_MANAGED = "full"
WIRED_TRANSITION_RE = re.compile(
    r"device \((?P<dev>(?:en|eth|usb)[^)]*)\): state change: (?P<old>[\w-]+) -> (?P<new>[\w-]+)"
    r" \(reason '[^']*', managed-type: '(?P<managed>\w+)'\)"
)
DISCONNECT_MARKER = "CTRL-EVENT-DISCONNECTED"
RADIO_OFF_MARKER = 'op="radio-control" arg="wireless-enabled:off"'
RADIO_ON_MARKER = 'op="radio-control" arg="wireless-enabled:on"'
SLEEP_MARKERS = ("sleep requested", "caught SIGTERM")
NM_START_MARKER = "is starting..."
NM_IDENT = "NetworkManager"
ACTIVATED = "activated"
# What journalctl prints on stderr when the caller cannot read the system journal.
JOURNAL_ACCESS_HINT = "You are currently not seeing messages from"


class CouldNotRun(Exception):
    """The journal could not be read or understood; the report would be a guess."""


@dataclass
class Disconnect:
    """One wpa_supplicant disconnect, with what was true when it happened."""

    at: datetime
    reason: str
    wired_known: bool
    wired_up: bool
    klass: str = ""


@dataclass
class Timeline:
    """The events the classification needs, parsed out of the journal."""

    disconnects: list[Disconnect] = field(default_factory=list)
    radio_offs: list[datetime] = field(default_factory=list)
    radio_ons: list[datetime] = field(default_factory=list)
    sleeps: list[datetime] = field(default_factory=list)
    wired_activations: list[datetime] = field(default_factory=list)
    nm_lines: int = 0


def read_journal_lines(journal_file: str | None, since: datetime, until: datetime) -> list[str]:
    """Return the journal lines for the span, from FILE or from journalctl.

    Raises CouldNotRun when journalctl fails, times out, or cannot see the
    system journal (a user outside adm/systemd-journal gets `-- No entries --`
    and a hint on stderr, which would otherwise read as a quiet fortnight).
    """
    if journal_file is not None:
        try:
            with open(journal_file, encoding="utf-8", errors="replace") as handle:
                return handle.read().splitlines()
        except OSError as err:
            raise CouldNotRun(f"cannot read {journal_file}: {err.strerror}") from err
    unit_args = [arg for unit in JOURNAL_UNITS for arg in ("-u", unit)]
    since_arg = since.strftime("%Y-%m-%d %H:%M:%S")
    until_arg = until.strftime("%Y-%m-%d %H:%M:%S")
    argv = ["journalctl", "--no-pager", "-o", "short-iso-precise",
            "--since", since_arg, "--until", until_arg, *unit_args]
    try:
        completed = subprocess.run(argv, capture_output=True, text=True,
                                   timeout=JOURNALCTL_TIMEOUT_S, check=False)
    except (OSError, subprocess.SubprocessError) as err:
        raise CouldNotRun(f"journalctl could not run: {err}") from err
    if JOURNAL_ACCESS_HINT in completed.stderr:
        raise CouldNotRun("journalctl cannot see the system journal (not in adm or systemd-journal?)")
    if completed.returncode != 0:
        first_error_line = next((line for line in completed.stderr.splitlines() if line.strip()), "")
        raise CouldNotRun(f"journalctl exited {completed.returncode}: {first_error_line}")
    return completed.stdout.splitlines()


def parse_timestamp(text: str) -> datetime:
    """Parse a short-iso-precise stamp, with or without fraction or offset colon."""
    has_fraction = "." in text
    stamp_format = "%Y-%m-%dT%H:%M:%S.%f%z" if has_fraction else "%Y-%m-%dT%H:%M:%S%z"
    return datetime.strptime(text, stamp_format)


def infer_wired_before(disconnects: list[Disconnect], wired_up_before: bool) -> None:
    """Settle the wired state of every disconnect recorded before the first transition."""
    for event in disconnects:
        if not event.wired_known:
            event.wired_known = True
            event.wired_up = wired_up_before


def build_timeline(lines: list[str]) -> Timeline:
    """Walk the journal in time order, tracking which wired devices are up."""
    stamped: list[tuple[datetime, str, str]] = []
    candidates = 0
    for line in lines:
        if not line.strip() or line.startswith("--"):
            continue   # '-- Boot <id> --' and '-- No entries --'
        candidates += 1
        match = JOURNAL_LINE_RE.match(line)
        if not match:
            continue
        try:
            stamp = parse_timestamp(match.group("ts"))
        except ValueError:
            continue
        stamped.append((stamp, match.group("ident"), line))
    if candidates and not stamped:
        raise CouldNotRun(f"{candidates} journal lines and not one parsed: a parser fault, not a quiet week")
    stamped.sort(key=lambda item: item[0])

    timeline = Timeline()
    wired_up_devices: set[str] = set()
    wired_known = False
    for stamp, ident, line in stamped:
        if ident == NM_IDENT:
            timeline.nm_lines += 1
        if NM_START_MARKER in line and ident == NM_IDENT:
            wired_up_devices.clear()
            wired_known = True
        elif transition := WIRED_TRANSITION_RE.search(line):
            device = transition.group("dev")
            came_up = transition.group("new") == ACTIVATED and transition.group("managed") == FULLY_MANAGED
            went_down = transition.group("old") == ACTIVATED and transition.group("new") != ACTIVATED
            if (went_down or came_up) and not wired_known:
                # The first transition into or out of `activated` also states what came
                # BEFORE it: `activated -> unmanaged` means the link was up until then.
                infer_wired_before(timeline.disconnects, wired_up_before=went_down)
                wired_known = True
            if went_down:
                wired_up_devices.discard(device)
            elif came_up:
                wired_up_devices.add(device)
                timeline.wired_activations.append(stamp)
        elif RADIO_OFF_MARKER in line:
            timeline.radio_offs.append(stamp)
        elif RADIO_ON_MARKER in line:
            timeline.radio_ons.append(stamp)
        elif any(marker in line for marker in SLEEP_MARKERS) and ident == NM_IDENT:
            timeline.sleeps.append(stamp)
        elif DISCONNECT_MARKER in line:
            reason = line.split(DISCONNECT_MARKER, 1)[1].strip()
            timeline.disconnects.append(
                Disconnect(stamp, reason, wired_known, bool(wired_up_devices)))
    return timeline


def classify(timeline: Timeline) -> None:
    """Give every disconnect exactly one class, in the order the docstring states."""
    toggle_window = timedelta(seconds=TOGGLE_WINDOW_S)
    sleep_window = timedelta(seconds=SLEEP_WINDOW_S)
    for event in timeline.disconnects:
        near_radio_off = any(abs(event.at - off) <= toggle_window for off in timeline.radio_offs)
        after_sleep = any(timedelta(0) <= event.at - slept <= sleep_window for slept in timeline.sleeps)
        if near_radio_off:
            event.klass = CLASS_RADIO_OFF
        elif after_sleep:
            event.klass = CLASS_SLEEP
        elif not event.wired_known:
            event.klass = CLASS_UNKNOWN
        elif event.wired_up:
            event.klass = CLASS_DOCKED
        else:
            event.klass = CLASS_UNDOCKED


def in_window(stamp: datetime, start: datetime, end: datetime) -> bool:
    """Is STAMP inside [start, end)?"""
    return start <= stamp < end


def print_report(timeline: Timeline, start: datetime, end: datetime, days: int, list_each: bool) -> None:
    """Print the counts for the window, and one line per disconnect with --list."""
    window_disconnects = [event for event in timeline.disconnects if in_window(event.at, start, end)]
    counts = {klass: 0 for klass, _, _ in CLASS_LABELS}
    for event in window_disconnects:
        counts[event.klass] += 1
    radio_offs = sum(in_window(stamp, start, end) for stamp in timeline.radio_offs)
    radio_ons = sum(in_window(stamp, start, end) for stamp in timeline.radio_ons)
    activations = sum(in_window(stamp, start, end) for stamp in timeline.wired_activations)
    window_text = f"{start:%Y-%m-%d %H:%M} -> {end:%Y-%m-%d %H:%M}"

    print(f"Wi-Fi disconnects by cause, last {days} days ({window_text}): {len(window_disconnects)}")
    for klass, label, note in CLASS_LABELS:
        note_text = f"  ({note})" if note else ""
        print(f"  {label + ':':<26}{counts[klass]:>4}{note_text}")
    print(f"dock events: {activations} wired link(s) up, {radio_offs} radio off, {radio_ons} radio on")
    if list_each:
        for event in window_disconnects:
            print(f"{event.at:%Y-%m-%d %H:%M:%S}\t{event.klass}\t{event.reason}")


def window_end() -> datetime:
    """Now, or DOCK_WIFI_REPORT_NOW (epoch seconds) for a reproducible window."""
    pinned = os.environ.get("DOCK_WIFI_REPORT_NOW", "")
    if not pinned:
        return datetime.now().astimezone()
    if not pinned.isdigit():
        raise CouldNotRun(f"DOCK_WIFI_REPORT_NOW must be epoch seconds, got '{pinned}'")
    return datetime.fromtimestamp(int(pinned)).astimezone()


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description="Count Wi-Fi disconnects by cause (read-only).")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS, help="window length in days (default 7)")
    parser.add_argument("--list", action="store_true", help="print one line per disconnect")
    parser.add_argument("--journal-file", help="read this journalctl -o short-iso-precise dump instead")
    args = parser.parse_args(argv)
    if args.days < 1:
        parser.error("--days must be at least 1")
    return args


def main(argv: list[str]) -> int:
    """Read, classify, print. 0 printed, 2 could not run."""
    args = parse_args(argv)
    try:
        end = window_end()
        start = end - timedelta(days=args.days)
        query_start = start - timedelta(days=LOOKBACK_DAYS)
        lines = read_journal_lines(args.journal_file, query_start, end)
        timeline = build_timeline(lines)
        if timeline.nm_lines == 0:
            raise CouldNotRun("no NetworkManager line in the span; docked and undocked cannot be told apart")
    except CouldNotRun as err:
        print(f"dock-wifi-report: could not run: {err}", file=sys.stderr)
        return 2
    classify(timeline)
    print_report(timeline, start, end, args.days, args.list)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
