#!/usr/bin/env python3
"""Offline report on AWS Client VPN outages, re-auths and SAML latency.

This is the instrument. It is the only way to know whether the rest of DO-692
worked, and it is the tool that produced every number in docs/VPN_INTERNALS.md.

IT READS LOGS, AND NOTHING ELSE IN DO-692 DOES
----------------------------------------------
Both client log directories are writable by any process running as this user, so
nothing that runs as root or reacts automatically may read them. That rule is
what deletes the attack surface two adversarial reviews mapped. This script is
the deliberate exception: it is run BY A HUMAN, ON DEMAND, and it only counts and
prints. It never acts, never opens a browser, never touches the tunnel, and never
feeds a daemon. Keep it that way.

EVERY NUMBER COMES FROM THE CLIENT'S OWN LOGS, NEVER FROM CHROME HISTORY
------------------------------------------------------------------------
Chrome does not chain the ACS delivery -- it is a form POST -- so 0 of 88 SAML
chains in either history DB reach the local ACS, and every chain appears to
dead-end at /v3/signin/accountchooser whether it succeeded or not. That artifact
produced two wrong root causes during planning. The ground truth is
`SAML ACS received a request` and `Succesfully retrieved and validated
assertion` in the app log -- note the vendor's spelling of "Succesfully", which
is matched exactly because that is what is in the file.

THE DST TRAP
------------
Every log line carries an explicit UTC offset:

    2026-09-22 11:01:39.931 +03:00 [DBG][TI=13][Quantivly:483350] SAML ACS ...

All 12,697 timestamped lines in the corpus at the time of writing carry +03:00.
The zone is Asia/Jerusalem and it goes to +02:00 on 2026-10-25 -- about four
weeks out, and exactly when the week-later comparison this tool exists for would
run. Anything pinning the literal offset silently reports ZERO EVENTS, which
reads as "the fix worked". So the offset is PARSED, never matched, and
scripts/test-vpn-failfast.sh has a fixture carrying both offsets in one file.

THE JOIN
--------
Two streams, and neither is sufficient:

  ~/.config/AWSVPNClient/logs/aws_vpn_client_*.log     "app"
      has SAML ACS started / received a request / was stopped,
      SamlSessionTimedOutException and the browser-open line. Begins later than
      the other stream (retention), and carries ~32k untimestamped continuation
      lines from stack traces.

  /var/log/aws-vpn-client/zvi/gtk_service_*.log        "ovpn"
      has every AUTH_FAILED with a timestamp on every line, and reaches further
      back.

They are joined on the OPENVPN EPOCH inside `>STATE:<epoch>,<NAME>,<detail>`,
never on the wall-clock string: the two streams' millisecond fields differ by 1ms
on about 20 events, so a string join silently drops them. The epoch is an integer
the openvpn management interface emits itself, so it is identical in both.

Usage:
    vpn-log-report.py [--days N] [--json] [--app-dir D] [--ovpn-dir D]

Exit codes:
    0  produced a report
    2  COULD NOT RUN -- no log directory, or no readable logs in the window.
       Never a pass: "0 outages" and "I could not find the logs" are the same
       sentence otherwise, and the second one reads as success.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# --- line shapes -----------------------------------------------------------
# The offset is CAPTURED (([+-]\d{2}:\d{2})), never compared to a literal. See
# the DST note in the module docstring.
TS_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ [+-]\d{2}:\d{2})\s'
)
STATE_RE = re.compile(r'>STATE:(?P<epoch>\d+),(?P<name>[A-Z_]+),(?P<detail>[^,]*)')
# THE JOIN KEY. The openvpn management epoch, which both streams carry in a
# different shape and which is identical for the same event:
#
#   app :  CM received:    >LOG:1790064100,,AUTH: Received control message: AUTH_FAILED,...
#          CM processsing: >LOG:1790064100,,AUTH: ...        <- vendor's spelling
#   ovpn:  [PID: 483350] 2026-09-22 11:01:40 AUTH: Received control message: AUTH_FAILED,...
#
# Verified: 1790064100 == 2026-09-22 11:01:40 +03:00, exactly.
#
# THREE LINES, ONE EVENT. Without this join AUTH_FAILED is counted twice from the
# app stream's received/processsing pair and a third time from the ovpn stream --
# measured, 100 over seven days where the truth is about half that, which
# silently doubles the re-auth rate every report quotes.
LOG_EPOCH_RE = re.compile(r'>LOG:(?P<epoch>\d+),')
# journalctl -o short-iso emits '+03:00' on systemd 259 here and '+0300' on
# older versions. Accept BOTH: pinning one spelling is how the resume probe
# silently returned nothing. %z parses either from Python 3.7 on.
JOURNAL_TS_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:?\d{2})')
# The openvpn stream embeds its own second-resolution LOCAL stamp before the
# message, with no offset of its own -- the offset is at the FRONT of the same
# line and is parsed from there rather than assumed. The DST rule again: on
# 2026-10-25 these lines keep this shape and change offset.
EMBEDDED_TS_RE = re.compile(r'(?P<ets>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) AUTH:')
LINE_OFFSET_RE = re.compile(r'^\S+ \S+ (?P<off>[+-]\d{2}:\d{2}) ')

MARKERS = {
    'auth_failed':  'AUTH_FAILED',
    'browser_open': 'Attempting to open browser with URL',
    'acs_request':  'SAML ACS received a request',
    # The vendor's spelling. Matched exactly because that is what is in the file;
    # "Successfully" matches nothing and would report a 0% success rate forever.
    'assertion':    'Succesfully retrieved and validated assertion',
    'saml_timeout': 'SamlSessionTimedOutException',
    'acs_unclean':  'Acs did not stop correctly',
}

CONNECTED = 'CONNECTED'


def auth_epoch(line, ts):
    """The openvpn epoch for an AUTH_FAILED line, in either stream.

    Returns an int so the three spellings of one event collapse to one key. The
    wall-clock fallback exists so an unrecognised variant is still counted ONCE
    rather than dropped -- no observed line needs it.
    """
    m = LOG_EPOCH_RE.search(line)
    if m:
        return int(m.group('epoch'))
    em = EMBEDDED_TS_RE.search(line)
    om = LINE_OFFSET_RE.match(line)
    if em and om:
        try:
            return int(datetime.strptime(
                '%s %s' % (em.group('ets'), om.group('off')),
                '%Y-%m-%d %H:%M:%S %z').timestamp())
        except ValueError:
            pass
    return int(round(ts))


def parse_ts(line):
    """Epoch seconds (float) from a log line, or None if it has no timestamp.

    %z accepts the '+03:00' spelling from Python 3.7 on, and converts using the
    offset that is actually in the line -- which is the whole point.
    """
    m = TS_RE.match(line)
    if not m:
        return None
    try:
        return datetime.strptime(m.group('ts'), '%Y-%m-%d %H:%M:%S.%f %z').timestamp()
    except ValueError:
        return None


def log_files(d, since_epoch):
    """Readable .log files in d, filtered by mtime so a 7-day window does not
    parse 33 days of logs. mtime, not the name's date: a rotated file
    (..._001.log) carries the same date and a different span."""
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for n in names:
        if not n.endswith('.log'):
            continue
        p = os.path.join(d, n)
        try:
            st = os.stat(p)
        except OSError:
            continue
        # A file whose LAST write is before the window still cannot contain a
        # line inside it.
        if st.st_mtime < since_epoch:
            continue
        if os.access(p, os.R_OK):
            out.append(p)
    return out


def scan(paths, since_epoch, events, states, unreadable):
    """Collect events and >STATE transitions from one stream."""
    for p in paths:
        try:
            fh = open(p, 'r', errors='replace')
        except OSError:
            unreadable.append(p)
            continue
        with fh:
            for line in fh:
                ts = parse_ts(line)
                # Untimestamped continuation lines (stack traces) are skipped
                # rather than attributed to the previous line's time: there are
                # ~32k of them and none carries an event marker.
                if ts is None or ts < since_epoch:
                    continue
                sm = STATE_RE.search(line)
                if sm:
                    # Keyed on the OPENVPN epoch, which is identical in both
                    # streams, so the same transition seen twice collapses.
                    states[(int(sm.group('epoch')), sm.group('name'),
                            sm.group('detail'))] = ts
                for kind, needle in MARKERS.items():
                    if needle not in line:
                        continue
                    if kind == 'auth_failed':
                        # Joined on the openvpn epoch, never on the wall-clock
                        # string: the two streams' millisecond fields differ by
                        # 1ms on about 20 events, so a string join keeps both.
                        events.setdefault(kind, {})[auth_epoch(line, ts)] = ts
                    else:
                        # Every other marker exists only in the app stream and is
                        # written once -- measured, raw count == distinct-
                        # millisecond count for all four.
                        events.setdefault(kind, {})[round(ts, 3)] = ts


def pct(sorted_vals, q):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    i = (len(sorted_vals) - 1) * q
    lo, hi = int(i), min(int(i) + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (i - lo)


def fmt_dur(s):
    if s is None:
        return 'n/a'
    if s < 90:
        return '%.1fs' % s
    if s < 5400:
        return '%.1fm' % (s / 60.0)
    return '%.1fh' % (s / 3600.0)


def outages(states):
    """Spans between leaving CONNECTED and reaching it again.

    Anchored on the openvpn epoch rather than on the log wall clock, so a DST
    change inside the window cannot lengthen or shorten an outage.

    An outage still open at the end of the window is reported separately and
    NOT folded into the totals: counting it would make every report understate
    the current outage and overstate nothing, silently.
    """
    seq = sorted(states.items(), key=lambda kv: kv[0][0])
    spans, start, open_since = [], None, None
    for (epoch, name, _detail), _ts in seq:
        if name == CONNECTED:
            if start is not None:
                spans.append((start, epoch))
                start = None
        else:
            if start is None:
                start = epoch
    if start is not None:
        open_since = start
    return spans, open_since


def _journalctl_iso(argv, timeout=30):
    """Run journalctl and return its ISO-stamped lines, or None if it could not
    be asked. None and [] mean different things everywhere below."""
    import subprocess
    try:
        r = subprocess.run(['journalctl', '-o', 'short-iso', '--no-pager'] + argv,
                           capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    out, candidates = [], 0
    for line in r.stdout.splitlines():
        if not line or line.startswith('--'):
            # '-- Boot <id> --' and '-- No entries --' separators.
            continue
        candidates += 1
        m = JOURNAL_TS_RE.match(line)
        if not m:
            continue
        try:
            # No transformation: %z accepts BOTH '+03:00' and '+0300' from
            # Python 3.7 on. An earlier draft tried to normalise the offset by
            # stripping colons and stripped the TIME's colons instead.
            out.append(datetime.strptime(m.group(1),
                                         '%Y-%m-%dT%H:%M:%S%z').timestamp())
        except ValueError:
            continue
    # journalctl produced lines and NOT ONE parsed. That is a parser fault, not
    # an absence of events, and the two must never print the same thing: an
    # earlier draft of this function used a regex requiring '+0300' while
    # `-o short-iso` emits '+03:00' here, so it silently returned [] and the
    # report said "0 kernel resumes" on a machine with twelve. Returning None
    # makes that read as NOT CHECKED, which is what it is.
    if candidates and not out:
        return None
    return out


def resume_epochs(since_epoch):
    """Kernel resume times, for the 'within 120s of a resume' split.

    Returns (times, coverage_start) where either may be None:

      times is None          -- NOT CHECKED. journalctl could not be asked.
      coverage_start is None -- the journal's own start could not be determined.

    An empty LIST is a real answer ("no resumes in the window"); None is not. The
    distinction is the whole point, because the failure mode here is a probe that
    finds nothing and reads as a clean result.

    `_TRANSPORT=kernel` rather than `-k`, and this is measured, not stylistic:
    `-k` IMPLIES `-b`, so it silently reports only the CURRENT BOOT. On this
    machine that was the difference between 1 resume and 12 over the same ten
    days -- and the under-count is invisible, because one resume is a perfectly
    plausible number.
    """
    since_iso = datetime.fromtimestamp(since_epoch, timezone.utc).astimezone() \
        .strftime('%Y-%m-%d %H:%M:%S')
    times = _journalctl_iso(['_TRANSPORT=kernel', '--since', since_iso,
                             '-g', 'PM: suspend exit'])
    return times, journal_starts()


def journal_starts():
    """Epoch of the OLDEST entry the journal still holds, or None.

    From `--list-boots -o json`, whose `first_entry` is microseconds. Not from
    `-n 1`, which returns the NEWEST entry -- an earlier draft used that and
    reported the journal as starting four minutes ago on a box holding two
    months of it, which would have flagged every report as partial.
    """
    import subprocess
    try:
        r = subprocess.run(['journalctl', '--list-boots', '-o', 'json',
                            '--no-pager'],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        boots = json.loads(r.stdout)
    except (ValueError, TypeError):
        return None
    if not isinstance(boots, list) or not boots:
        return None
    firsts = [b.get('first_entry') for b in boots
              if isinstance(b, dict) and isinstance(b.get('first_entry'), int)]
    if not firsts:
        return None
    return min(firsts) / 1000000.0


def pair_forward(starts, ends, window):
    """For each start, the first end within `window` seconds. Returns
    (matched list of (start, end, delta), unmatched starts)."""
    ends = sorted(ends)
    matched, unmatched = [], []
    import bisect
    for s in sorted(starts):
        i = bisect.bisect_left(ends, s)
        if i < len(ends) and ends[i] - s <= window:
            matched.append((s, ends[i], ends[i] - s))
        else:
            unmatched.append(s)
    return matched, unmatched


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--app-dir',
                    default=os.path.expanduser('~/.config/AWSVPNClient/logs'))
    ap.add_argument('--ovpn-dir', default='/var/log/aws-vpn-client/%s'
                    % os.environ.get('USER', ''))
    args = ap.parse_args()

    if args.days < 1:
        print('vpn-log-report: --days must be at least 1', file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)
    since = (now - timedelta(days=args.days)).timestamp()

    app = log_files(args.app_dir, since)
    ovpn = log_files(args.ovpn_dir, since)
    if app is None and ovpn is None:
        print('vpn-log-report: neither log directory exists:\n  %s\n  %s'
              % (args.app_dir, args.ovpn_dir), file=sys.stderr)
        return 2
    paths = (app or []) + (ovpn or [])
    if not paths:
        print('vpn-log-report: no readable .log files modified within %d days in:\n'
              '  %s\n  %s\n'
              'That is NOT "no outages" -- refusing to print a report that would '
              'read as a clean week.' % (args.days, args.app_dir, args.ovpn_dir),
              file=sys.stderr)
        return 2

    events, states, unreadable = {}, {}, []
    scan(app or [], since, events, states, unreadable)
    scan(ovpn or [], since, events, states, unreadable)

    def times(kind):
        return sorted(events.get(kind, {}).values())

    auth_failed = times('auth_failed')
    opens = times('browser_open')
    acs = times('acs_request')
    assertions = times('assertion')
    timeouts = times('saml_timeout')
    unclean = times('acs_unclean')

    spans, open_since = outages(states)
    durs = sorted(e - s for s, e in spans)
    total_down = sum(durs)

    # A re-auth was needed for this outage if an AUTH_FAILED falls inside it.
    needed_saml = 0
    for s, e in spans:
        if any(s - 5 <= a <= e + 5 for a in auth_failed):
            needed_saml += 1
    self_healed = len(spans) - needed_saml
    healed_durs = sorted(
        e - s for s, e in spans
        if not any(s - 5 <= a <= e + 5 for a in auth_failed))

    # The residual-attributing number: the client opens the browser itself, so
    # this is how long the Google round trip took, not how long a human took.
    open_to_acs, open_no_acs = pair_forward(opens, acs, 700)

    resumes, journal_from = resume_epochs(since)
    resume_partial = (journal_from is not None and journal_from > since)
    near_resume, far_resume = [], []
    for s, _e, d in open_to_acs:
        if resumes is None:
            continue
        if any(0 <= s - r <= 120 for r in resumes):
            near_resume.append(d)
        else:
            far_resume.append(d)

    # THE NUMBER THIS PR TARGETS. After SamlSessionTimedOutException the client
    # goes Disconnected and nothing retries it; the gap to the next attempt is
    # how long nobody noticed.
    attempts = sorted(ts for (epoch, name, _d), ts in states.items()
                      if name in ('RESOLVE', 'AUTH'))
    timeout_to_next, timeout_no_next = pair_forward(timeouts, attempts, 86400 * 2)
    ttn = sorted(d for _s, _e, d in timeout_to_next)

    report = {
        'window_days': args.days,
        'files_scanned': len(paths),
        'unreadable_files': unreadable,
        'outages': len(spans),
        'outage_open_now': open_since is not None,
        'downtime_seconds': round(total_down, 1),
        'outage_p50': pct(durs, 0.5),
        'outage_p90': pct(durs, 0.9),
        'self_healed': self_healed,
        'self_healed_p50': pct(healed_durs, 0.5),
        'needed_saml': needed_saml,
        'auth_failed': len(auth_failed),
        'browser_opens': len(opens),
        'acs_requests': len(acs),
        'assertions': len(assertions),
        'saml_timeouts': len(timeouts),
        'acs_unclean_stops': len(unclean),
        'open_to_acs_count': len(open_to_acs),
        'open_to_acs_p50': pct(sorted(d for _s, _e, d in open_to_acs), 0.5),
        'open_to_acs_p90': pct(sorted(d for _s, _e, d in open_to_acs), 0.9),
        'opens_with_no_acs': len(open_no_acs),
        'resume_split': ('NOT CHECKED' if resumes is None else {
            'within_120s_of_resume': len(near_resume),
            'within_120s_p50': pct(sorted(near_resume), 0.5),
            'not_near_resume': len(far_resume),
            'not_near_resume_p50': pct(sorted(far_resume), 0.5),
            'resumes_seen': len(resumes),
            # True when the journal does not reach back as far as --days, so the
            # split is computed over less history than the rest of the report.
            'partial_journal_coverage': resume_partial,
            'journal_starts': journal_from,
        }),
        'timeout_to_next_attempt_count': len(ttn),
        'timeout_to_next_attempt_p50': pct(ttn, 0.5),
        'timeout_to_next_attempt_max': ttn[-1] if ttn else None,
    }

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    p = print
    p('AWS Client VPN — last %d days (%d log files)' % (args.days, len(paths)))
    if unreadable:
        p('  ! %d log file(s) could not be read; counts below are INCOMPLETE'
          % len(unreadable))
    p('')
    p('outages                %d' % len(spans))
    p('total downtime         %s' % fmt_dur(total_down))
    p('  p50 / p90            %s / %s' % (fmt_dur(report['outage_p50']),
                                          fmt_dur(report['outage_p90'])))
    p('  self-healed, no SAML %d (p50 %s)' % (self_healed,
                                              fmt_dur(report['self_healed_p50'])))
    p('  needed a SAML re-auth %d' % needed_saml)
    if open_since is not None:
        p('  ! an outage is OPEN now and is excluded from the totals above')
    p('')
    p('re-auth flow')
    p('  AUTH_FAILED          %d' % len(auth_failed))
    p('  client opened browser %d' % len(opens))
    p('  ACS POST arrived     %d' % len(acs))
    p('  assertion validated  %d' % len(assertions))
    p('  SAML timed out (600s) %d' % len(timeouts))
    p('  ACS stopped uncleanly %d' % len(unclean))
    p('')
    p('client-own-open -> ACS POST   (the Google round trip, not a human)')
    p('  paired               %d  (%d opens never got an ACS POST)'
      % (len(open_to_acs), len(open_no_acs)))
    p('  p50 / p90            %s / %s' % (fmt_dur(report['open_to_acs_p50']),
                                          fmt_dur(report['open_to_acs_p90'])))
    if resumes is None:
        p('  near a resume        NOT CHECKED (the kernel journal could not be read)')
    else:
        p('  within 120s of a resume  %d (p50 %s)'
          % (len(near_resume), fmt_dur(pct(sorted(near_resume), 0.5))))
        p('  not near a resume        %d (p50 %s)'
          % (len(far_resume), fmt_dur(pct(sorted(far_resume), 0.5))))
        p('  (%d kernel resume(s) in the window)' % len(resumes))
        if resume_partial:
            p('  ! the journal only reaches back to %s, which is INSIDE this '
              'window —' % datetime.fromtimestamp(journal_from).strftime('%Y-%m-%d %H:%M'))
            p('    the resume split above covers less history than the rest of '
              'this report.')
    p('')
    p('SAML timeout -> next attempt  (THE NUMBER DO-692 TARGETS)')
    p('  paired               %d' % len(ttn))
    p('  p50 / max            %s / %s' % (fmt_dur(report['timeout_to_next_attempt_p50']),
                                          fmt_dur(report['timeout_to_next_attempt_max'])))
    if timeout_no_next:
        p('  %d timeout(s) with no later attempt in the window' % len(timeout_no_next))
    return 0


if __name__ == '__main__':
    sys.exit(main())
