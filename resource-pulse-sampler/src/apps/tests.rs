//! The gjs rows of `gnome-shell/tests/apps.test.js`, carried over (each is marked
//! `/// row: <title>`), the brief's new rows, and the rows that pin where JavaScript's matching,
//! string handling and ordering differ from Rust's. Expected values that are not a gjs row's
//! own are the answer of `lib/apps.js` run under gjs.

use super::*;
use crate::constants::APP_RANKING_LENGTH;

/// A leaf name with what `describeCgroup` gives for it under gjs: (leaf, kind summary, group key,
/// fallback name). The kind summary is `app:<appId>`, `snap:<snapName>/<snapAppName>`, `docker` or
/// `unit`.
type DescribedLeaf = (&'static str, &'static str, &'static str, &'static str);

/// App scopes: the launcher backtracks, digits are ASCII, a line terminator breaks `.`.
const APP_SCOPE_EDGES: [DescribedLeaf; 13] = [
    ("app-gnome-1.scope", "app:gnome", "app:gnome", "Gnome"),
    ("app-gnome--5.scope", "app:gnome-", "app:gnome-", "Gnome-"),
    ("app--5.scope", "unit", "unit:app--5", "app--5"),
    ("app-foo-12-34.scope", "app:foo-12", "app:foo-12", "Foo-12"),
    (
        "app-foo-bar.scope",
        "unit",
        "unit:app-foo-bar",
        "app-foo-bar",
    ),
    (
        "app-foo-5.scope\u{a}",
        "unit",
        "unit:app-foo-5.scope\u{a}",
        "app-foo-5.scope\u{a}",
    ),
    (
        "app-fo\u{a}o-5.scope",
        "unit",
        "unit:app-fo\u{a}o-5.scope",
        "app-fo\u{a}o-5.scope",
    ),
    (
        "app-a\\x0ab-5.scope",
        "app:a\u{a}b",
        "app:a\u{a}b",
        "A\u{a}b",
    ),
    (
        "app-flatpak-1.scope",
        "app:flatpak",
        "app:flatpak",
        "Flatpak",
    ),
    ("app-kde-x-1.scope", "app:x", "app:x", "X"),
    (
        "app-gnome-flatpak-x-1.scope",
        "app:flatpak-x",
        "app:flatpak-x",
        "Flatpak-x",
    ),
    (
        "app-foo-5.scopes",
        "unit",
        "unit:app-foo-5.scopes",
        "app-foo-5.scopes",
    ),
    (
        "app-foo-\u{663}.scope",
        "unit",
        "unit:app-foo-\u{663}",
        "app-foo-\u{663}",
    ),
];
/// Snaps: the lazy app name, the lowercase-only uuid, a dot in the app name.
const SNAP_EDGES: [DescribedLeaf; 14] = [
    (
        "snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope",
        "snap:slack/slack",
        "snap:slack",
        "slack",
    ),
    ("snap.foo.bar.service", "snap:foo/bar", "snap:foo", "foo"),
    (
        "snap.foo.bar.baz.service",
        "snap:foo/foo",
        "snap:foo",
        "foo",
    ),
    (
        "snap.foo.-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope",
        "snap:foo/-6dac35ea-863e-4f4f-a9a2-1c50d93840a1",
        "snap:foo",
        "foo",
    ),
    (
        "snap.foo.bar-6DAC35EA-863E-4F4F-A9A2-1C50D93840A1.scope",
        "snap:foo/bar-6DAC35EA-863E-4F4F-A9A2-1C50D93840A1",
        "snap:foo",
        "foo",
    ),
    (
        "snap.foo.bar-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.service",
        "snap:foo/bar",
        "snap:foo",
        "foo",
    ),
    ("snap.foo.bar.scope", "snap:foo/bar", "snap:foo", "foo"),
    ("snap.foo.bar", "snap:foo/foo", "snap:foo", "foo"),
    ("snap.foo.", "snap:foo/foo", "snap:foo", "foo"),
    (
        "snap.foo\u{a}.x.scope",
        "snap:foo\u{a}/x",
        "snap:foo\u{a}",
        "foo\u{a}",
    ),
    ("snap..x.scope", "unit", "unit:snap..x", "snap..x"),
    ("snap.a\\x2eb.x.scope", "snap:a/a", "snap:a", "a"),
    (
        "snap.foo.a-b-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope",
        "snap:foo/a-b",
        "snap:foo",
        "foo",
    ),
    (
        "snap.foo.6dac35ea-863e-4f4f-a9a2-1c50d93840a1-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope",
        "snap:foo/6dac35ea-863e-4f4f-a9a2-1c50d93840a1",
        "snap:foo",
        "foo",
    ),
];
/// Docker scopes: `^docker-.*\\.scope$`.
const DOCKER_EDGES: [DescribedLeaf; 6] = [
    ("docker-.scope", "docker", "docker:docker", "docker"),
    (
        "docker-abc\u{a}.scope",
        "unit",
        "unit:docker-abc\u{a}.scope",
        "docker-abc\u{a}.scope",
    ),
    ("docker-scope", "unit", "unit:docker-scope", "docker-scope"),
    ("docker.scope", "unit", "unit:docker", "docker"),
    ("docker-a.b.scope", "docker", "docker:docker", "docker"),
    (
        "docker-a\\x0a.scope",
        "unit",
        "unit:docker-a\u{a}.scope",
        "docker-a\u{a}.scope",
    ),
];
/// Units: the lazy `(.+?)`, the optional `@.*` instance, the suffix, line terminators.
const UNIT_EDGES: [DescribedLeaf; 12] = [
    ("a@b@c.service", "unit", "unit:a", "a"),
    ("@foo.service", "unit", "unit:@foo", "@foo"),
    ("a@.service", "unit", "unit:a", "a"),
    (".service", "unit", "unit:.service", ".service"),
    ("x.service.scope", "unit", "unit:x.service", "x.service"),
    (
        "a@b\u{a}.service",
        "unit",
        "unit:a@b\u{a}.service",
        "a@b\u{a}.service",
    ),
    ("user@1000.service", "unit", "unit:user", "user"),
    ("a\\x40b.service", "unit", "unit:a", "a"),
    (
        "a@b\u{2028}c.service",
        "unit",
        "unit:a@b\u{2028}c.service",
        "a@b\u{2028}c.service",
    ),
    ("plain", "unit", "unit:plain", "plain"),
    ("a.mount", "unit", "unit:a.mount", "a.mount"),
    ("a@b.scope.service", "unit", "unit:a", "a"),
];
/// Display names of units: aliases, settings daemons, reverse DNS.
const UNIT_DISPLAY_EDGES: [DescribedLeaf; 15] = [
    (
        "org.gnome.SettingsDaemon.\u{130}stanbul.service",
        "unit",
        "unit:org.gnome.SettingsDaemon.\u{130}stanbul",
        "gsd-i\u{307}stanbul",
    ),
    (
        "org.gnome.SettingsDaemon.\u{391}\u{3a3}.service",
        "unit",
        "unit:org.gnome.SettingsDaemon.\u{391}\u{3a3}",
        "gsd-\u{3b1}\u{3c2}",
    ),
    (
        "org.gnome.SettingsDaemon..service",
        "unit",
        "unit:org.gnome.SettingsDaemon.",
        "gsd-",
    ),
    (
        "org.gnome.SettingsDaemon.service",
        "unit",
        "unit:org.gnome.SettingsDaemon",
        "SettingsDaemon",
    ),
    (
        "org.gnome.Shell.service",
        "unit",
        "unit:org.gnome.Shell",
        "GNOME Shell",
    ),
    (
        "org.gnome.Shell@x11.service",
        "unit",
        "unit:org.gnome.Shell",
        "GNOME Shell",
    ),
    ("org.foo.service", "unit", "unit:org.foo", "org.foo"),
    ("org.foo.bar.service", "unit", "unit:org.foo.bar", "bar"),
    ("com.a.b.c.service", "unit", "unit:com.a.b.c", "b.c"),
    ("io.x..service", "unit", "unit:io.x.", ""),
    (
        "Org.foo.bar.service",
        "unit",
        "unit:Org.foo.bar",
        "Org.foo.bar",
    ),
    ("toString.service", "unit", "unit:toString", "toString"),
    ("__proto__.service", "unit", "unit:__proto__", "__proto__"),
    ("net.a.b.scope", "unit", "unit:net.a.b", "b"),
    (
        "herdr-server@x.service",
        "unit",
        "unit:herdr-server",
        "herdr agents",
    ),
];
/// Fallback names of apps: `charAt(0).toUpperCase()` on the last id segment.
const CAPITALISED_FALLBACK_EDGES: [DescribedLeaf; 12] = [
    (
        "app-org.example.\u{df}tool-1.scope",
        "app:org.example.\u{df}tool",
        "app:org.example.\u{df}tool",
        "SStool",
    ),
    (
        "app-\u{10428}x-1.scope",
        "app:\u{10428}x",
        "app:\u{10428}x",
        "\u{10428}x",
    ),
    (
        "app-\u{e9}a-1.scope",
        "app:\u{e9}a",
        "app:\u{e9}a",
        "\u{c9}a",
    ),
    ("app-a.-1.scope", "app:a.", "app:a.", ""),
    (
        "app-.hidden-1.scope",
        "app:.hidden",
        "app:.hidden",
        "Hidden",
    ),
    (
        "app-\u{fb01}sh-1.scope",
        "app:\u{fb01}sh",
        "app:\u{fb01}sh",
        "FIsh",
    ),
    (
        "app-\\xb5x-1.scope",
        "app:\u{b5}x",
        "app:\u{b5}x",
        "\u{39c}x",
    ),
    (
        "app-\\xffx-1.scope",
        "app:\u{ff}x",
        "app:\u{ff}x",
        "\u{178}x",
    ),
    ("app-\\xdfx-1.scope", "app:\u{df}x", "app:\u{df}x", "SSx"),
    (
        "app-\u{1c6}x-1.scope",
        "app:\u{1c6}x",
        "app:\u{1c6}x",
        "\u{1c4}x",
    ),
    (
        "app-\u{149}x-1.scope",
        "app:\u{149}x",
        "app:\u{149}x",
        "\u{2bc}Nx",
    ),
    ("app-\u{131}x-1.scope", "app:\u{131}x", "app:\u{131}x", "Ix"),
];

/// The `appId` of a described app, `None` for any other kind.
fn app_id_of(description: &CgroupDescription) -> Option<&str> {
    match &description.kind {
        CgroupKind::App { app_id } => Some(app_id),
        _ => None,
    }
}

/// The kind summary [`DescribedLeaf`] uses.
fn kind_summary(description: &CgroupDescription) -> String {
    match &description.kind {
        CgroupKind::App { app_id } => format!("app:{app_id}"),
        CgroupKind::Snap {
            snap_name,
            snap_app_name,
        } => format!("snap:{snap_name}/{snap_app_name}"),
        CgroupKind::Docker => "docker".to_string(),
        CgroupKind::Unit => "unit".to_string(),
    }
}

/// Asserts `describe_cgroup` gives each table row's kind, group key and fallback name.
fn assert_described_as_under_gjs(rows: &[DescribedLeaf]) {
    for (leaf, expected_kind, expected_group_key, expected_fallback_name) in rows {
        let description = describe_cgroup(leaf);
        assert_eq!(
            kind_summary(&description),
            *expected_kind,
            "kind of {leaf:?}"
        );
        assert_eq!(
            description.group_key, *expected_group_key,
            "group key of {leaf:?}"
        );
        assert_eq!(
            description.fallback_name, *expected_fallback_name,
            "fallback name of {leaf:?}"
        );
    }
}

/// Runs `display_name_for` with a resolver that answers `answer` and records what it was asked.
fn display_name_asking(
    description: &CgroupDescription,
    answer: Option<&str>,
) -> (String, Vec<String>) {
    let mut asked = Vec::new();
    let mut resolve_app_name = |desktop_id: &str| {
        asked.push(desktop_id.to_string());
        answer.map(str::to_string)
    };
    let name = display_name_for(description, &mut resolve_app_name);
    (name, asked)
}

/// row: Chromium scope → app org.chromium.Chromium
#[test]
fn chromium_scope_is_app_org_chromium_chromium() {
    let description = describe_cgroup("app-org.chromium.Chromium-50164.scope");
    assert_eq!(app_id_of(&description), Some("org.chromium.Chromium"));
}

/// row: gnome launcher with an escaped id
#[test]
fn gnome_launcher_with_an_escaped_id() {
    let description = describe_cgroup("app-gnome-aws\\x2dvpn\\x2dclient-59401.scope");
    assert_eq!(app_id_of(&description), Some("aws-vpn-client"));
}

/// row: snap scope → snap name
#[test]
fn snap_scope_is_the_snap_name() {
    let description =
        describe_cgroup("snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope");
    assert_eq!(description.fallback_name, "slack");
}

/// row: the launcher is matched before unescaping: an escaped hyphen after "gnome" is part of the app id
#[test]
fn the_launcher_is_matched_before_unescaping() {
    let description = describe_cgroup("app-gnome\\x2dcalculator-1234.scope");
    assert_eq!(app_id_of(&description), Some("gnome-calculator"));
}

/// row: a GNOME settings daemon is named gsd-<x> in lowercase
#[test]
fn a_gnome_settings_daemon_is_named_gsd_x_in_lowercase() {
    let description = describe_cgroup("org.gnome.SettingsDaemon.Power.service");
    assert_eq!(description.fallback_name, "gsd-power");
}

/// row: another reverse-DNS unit drops its first two segments
#[test]
fn another_reverse_dns_unit_drops_its_first_two_segments() {
    let description = describe_cgroup("org.freedesktop.IBus.session.GNOME.service");
    assert_eq!(description.fallback_name, "IBus.session.GNOME");
}

/// row: a snap asks the resolver for <snap>_<app>.desktop, and falls back to the snap name
#[test]
fn a_snap_asks_the_resolver_for_snap_app_desktop_and_falls_back_to_the_snap_name() {
    let description =
        describe_cgroup("snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope");
    let (resolved, asked) = display_name_asking(&description, Some("Slack Desktop"));
    let (fallback, _) = display_name_asking(&description, None);
    assert_eq!(asked, ["slack_slack.desktop"]);
    assert_eq!(resolved, "Slack Desktop");
    assert_eq!(fallback, "slack");
}

/// row: herdr service → "herdr agents"
#[test]
fn herdr_service_is_herdr_agents() {
    let description = describe_cgroup("herdr-server.service");
    assert_eq!(description.fallback_name, "herdr agents");
}

/// row: templated unit drops its instance
#[test]
fn templated_unit_drops_its_instance() {
    let description = describe_cgroup("gnome-session-manager@ubuntu.service");
    assert_eq!(description.fallback_name, "gnome-session-manager");
}

/// row: docker scopes group as one "docker"
#[test]
fn docker_scopes_group_as_one_docker() {
    let first = describe_cgroup("docker-0123abcd.scope");
    let second = describe_cgroup("docker-89ef.scope");
    assert_eq!(first.group_key, second.group_key);
}

/// row: display name falls back to the capitalised last id segment
#[test]
fn display_name_falls_back_to_the_capitalised_last_id_segment() {
    let description = describe_cgroup("app-org.chromium.Chromium-1.scope");
    let (name, _) = display_name_asking(&description, None);
    assert_eq!(name, "Chromium");
}

/// row: every \xNN escape is unescaped, not just the first (and a plain name is untouched)
#[test]
fn every_xnn_escape_is_unescaped_not_just_the_first() {
    assert_eq!(unescape_systemd_name("a\\x2db\\x2dc"), "a-b-c");
    assert_eq!(unescape_systemd_name("plain.service"), "plain.service");
}

/// row: a launcherless app id keeps its hyphen; a flatpak launcher is stripped
#[test]
fn a_launcherless_app_id_keeps_its_hyphen_a_flatpak_launcher_is_stripped() {
    let launcherless = describe_cgroup("app-my-tool-12.scope");
    let flatpak = describe_cgroup("app-flatpak-org.mozilla.firefox-9.scope");
    assert_eq!(app_id_of(&launcherless), Some("my-tool"));
    assert_eq!(app_id_of(&flatpak), Some("org.mozilla.firefox"));
}

/// row: the resolver answer for <appId>.desktop wins over the fallback
#[test]
fn the_resolver_answer_for_app_id_desktop_wins_over_the_fallback() {
    let description = describe_cgroup("app-gnome-alacritty-66279.scope");
    let (name, asked) = display_name_asking(&description, Some("Alacritty Terminal"));
    assert_eq!(name, "Alacritty Terminal");
    assert_eq!(asked, ["alacritty.desktop"]);
}

/// row: a non-app kind ignores the resolver
#[test]
fn a_non_app_kind_ignores_the_resolver() {
    let description = describe_cgroup("dbus.service");
    let (name, asked) = display_name_asking(&description, Some("WRONG"));
    assert_eq!(name, "dbus");
    assert!(asked.is_empty(), "the resolver was asked {asked:?}");
}

/// The brief's new row, "apps: an escaped non-ASCII byte becomes one character per byte, as
/// today" (not a gjs row, so unmarked). Expected value: `unescapeSystemdName` run under gjs,
/// U+00C3 U+00A9, never the one character `é` the two bytes spell in UTF-8.
#[test]
fn an_escaped_non_ascii_byte_becomes_one_character_per_byte_as_today() {
    assert_eq!(
        unescape_systemd_name("caf\\xc3\\xa9.service"),
        "caf\u{00C3}\u{00A9}.service"
    );
}

/// `\x` followed by fewer than two hex digits, by a non-hex digit or by nothing is left alone;
/// both letter cases decode; a doubled backslash leaves the second one to start the escape; a
/// matched escape is not rescanned. Expected values: `unescapeSystemdName` run under gjs.
#[test]
fn only_a_backslash_x_and_two_hex_digits_is_an_escape() {
    let cases = [
        ("\\x4", "\\x4"),
        ("\\xZZ", "\\xZZ"),
        ("\\\\x41", "\\A"),
        ("\\\\\\x41", "\\\\A"),
        ("\\x", "\\x"),
        ("a\\x", "a\\x"),
        ("\\xC3\\xa9", "\u{c3}\u{a9}"),
        ("\\x00", "\u{0}"),
        ("\\x41\\x4", "A\\x4"),
        ("\\x4a\\x4A", "JJ"),
        ("\\x\\x41", "\\xA"),
        ("\\xx41", "\\xx41"),
    ];
    for (escaped, expected) in cases {
        assert_eq!(unescape_systemd_name(escaped), expected, "{escaped:?}");
    }
}

/// App scope names: `^app-(?:(?:gnome|flatpak|kde|dbus|systemd)-)?(.+)-\d+\.scope$`.
#[test]
fn app_scope_names_match_the_javascript_patterns() {
    assert_described_as_under_gjs(&APP_SCOPE_EDGES);
}

/// Snap names and the lazy snap app name.
#[test]
fn snap_names_match_the_javascript_patterns() {
    assert_described_as_under_gjs(&SNAP_EDGES);
}

/// Docker scopes: `^docker-.*\.scope$`.
#[test]
fn docker_scopes_match_the_javascript_pattern() {
    assert_described_as_under_gjs(&DOCKER_EDGES);
}

/// Units: `^(.+?)(?:@.*)?\.(?:service|scope)$`.
#[test]
fn units_match_the_javascript_pattern() {
    assert_described_as_under_gjs(&UNIT_EDGES);
}

/// Display names of units, including the case mapping of `toLowerCase` for `İ` and the final sigma.
#[test]
fn unit_display_names_match_the_javascript_function() {
    assert_described_as_under_gjs(&UNIT_DISPLAY_EDGES);
}

/// The fallback name of an app: `charAt(0).toUpperCase() + slice(1)` of the last id segment.
#[test]
fn app_fallback_names_are_capitalised_as_javascript_does() {
    assert_described_as_under_gjs(&CAPITALISED_FALLBACK_EDGES);
}

/// A resolver answer that is the empty string, or no answer, gives the fallback (`||`); the
/// resolver is asked once, and for a snap by `<snap>_<app>.desktop`. Expected values:
/// `displayNameFor` run under gjs.
#[test]
fn an_empty_resolver_answer_falls_back_like_no_answer() {
    let app = describe_cgroup("app-gnome-alacritty-1.scope");
    let snap = describe_cgroup("snap.foo.bar.service");
    assert_eq!(display_name_asking(&app, Some("")).0, "Alacritty");
    assert_eq!(display_name_asking(&app, None).0, "Alacritty");
    assert_eq!(display_name_asking(&snap, Some("")).0, "foo");
    assert_eq!(display_name_asking(&snap, Some("X")).0, "X");
    assert_eq!(display_name_asking(&snap, None).1, ["foo_bar.desktop"]);
}

const GIB: u64 = 1024 * 1024 * 1024;
const ELAPSED_USEC: i64 = 2_000_000;
const CPU_COUNT: u64 = 8;
/// Microseconds of CPU the whole machine has in one scan: 2 s on 8 CPUs.
const MACHINE_CAPACITY_USEC: f64 = 16_000_000.0;
/// 2^53: the first integer a double cannot add 1 to.
const TWO_TO_THE_53: u64 = 9_007_199_254_740_992;

/// One leaf of a ranking input: (path, `usage_usec` last scan, `usage_usec` now, memory bytes).
type LeafSpec = (&'static str, Option<u64>, u64, Option<u64>);

/// What the gjs rows' `input` gives `nameOfCgroup`: each cgroup is named after itself up to a `#`.
fn name_after_itself_up_to_hash(cgroup_path: &str) -> AppGroup {
    let name = cgroup_path.split('#').next().unwrap_or_default();
    AppGroup {
        group_key: name.to_string(),
        name: name.to_string(),
    }
}

/// The gjs rows' `input(spec)`: a scan of the leaves, 2 s long on 8 CPUs, with no root delta.
fn scan_of(leaves: &[LeafSpec]) -> RankingScan {
    let mut scan = RankingScan {
        elapsed_usec: ELAPSED_USEC,
        cpu_count: CPU_COUNT,
        ..RankingScan::default()
    };
    for (path, previous, current, memory) in leaves {
        if let Some(previous_usec) = previous {
            scan.previous_usage_usec
                .insert(path.to_string(), *previous_usec);
        }
        scan.current_usage_usec.insert(path, *current);
        if let Some(memory_bytes) = memory {
            scan.memory_bytes_by_cgroup.insert(path, *memory_bytes);
        }
    }
    scan
}

/// The gjs rows' `parents(spec, parentDeltas, listedPreviously)` applied to `scan`.
fn with_parents(
    scan: RankingScan,
    parent_of: &[(&str, &str)],
    parent_deltas: &[(&str, i64)],
    listed_previously: &[&str],
) -> RankingScan {
    let mut parent_cpu_delta_usec = InsertionOrderedMap::new();
    for (parent_path, delta_usec) in parent_deltas {
        parent_cpu_delta_usec.insert(parent_path, *delta_usec);
    }
    RankingScan {
        parent_of_leaf: parent_of
            .iter()
            .map(|(leaf, parent)| (leaf.to_string(), parent.to_string()))
            .collect(),
        parents_listed_previously: listed_previously
            .iter()
            .map(|parent| parent.to_string())
            .collect(),
        parent_cpu_delta_usec,
        ..scan
    }
}

/// `scan` with a root CPU delta.
fn with_root_delta(scan: RankingScan, root_cpu_delta_usec: i64) -> RankingScan {
    RankingScan {
        root_cpu_delta_usec: Some(root_cpu_delta_usec),
        ..scan
    }
}

/// Ranks `scan`, naming every cgroup after itself up to a `#`.
fn rank(scan: &RankingScan) -> AppRanking {
    rank_apps(scan, &mut name_after_itself_up_to_hash)
}

/// A CPU ranking entry whose group key is its name.
fn cpu_entry(name: &str, cpu_percent: f64) -> CpuRankEntry {
    CpuRankEntry {
        group_key: name.to_string(),
        name: name.to_string(),
        cpu_percent,
    }
}

/// A memory ranking entry whose group key is its name.
fn memory_entry(name: &str, memory_bytes: f64) -> MemoryRankEntry {
    MemoryRankEntry {
        group_key: name.to_string(),
        name: name.to_string(),
        memory_bytes,
    }
}

/// The names of the CPU ranking, in order.
fn cpu_ranking_names(ranking: &AppRanking) -> Vec<&str> {
    ranking
        .cpu_ranking
        .iter()
        .map(|entry| entry.name.as_str())
        .collect()
}

/// The name of the CPU ranking's winner; fails the test when there is none.
fn top_cpu_name(ranking: &AppRanking) -> &str {
    &ranking.top_cpu.as_ref().expect("a CPU winner").name
}

/// The name of the memory ranking's winner; fails the test when there is none.
fn top_memory_name(ranking: &AppRanking) -> &str {
    &ranking.top_memory.as_ref().expect("a memory winner").name
}

/// A group of the pseudo kind (kernel or short jobs) whose key is not its name.
fn pseudo_cpu_entry(group_key: &str, name: &str, cpu_percent: f64) -> CpuRankEntry {
    CpuRankEntry {
        group_key: group_key.to_string(),
        name: name.to_string(),
        cpu_percent,
    }
}

/// row: app CPU is a share of the whole machine (top-style would be 400%)
#[test]
fn app_cpu_is_a_share_of_the_whole_machine() {
    let ranking = rank(&scan_of(&[("herdr agents", Some(0), 8_000_000, Some(GIB))]));
    assert_eq!(ranking.top_cpu, Some(cpu_entry("herdr agents", 50.0)));
}

/// row: two scopes of one app are summed
#[test]
fn two_scopes_of_one_app_are_summed() {
    // chrome 2M + 2M = 4M beats alpha's 3M; ranking scopes singly would pick alpha.
    let ranking = rank(&scan_of(&[
        ("chrome#1", Some(0), 2_000_000, Some(1)),
        ("chrome#2", Some(0), 2_000_000, Some(1)),
        ("alpha", Some(0), 3_000_000, Some(1)),
    ]));
    assert_eq!(ranking.top_cpu, Some(cpu_entry("chrome", 25.0)));
}

/// row: two scopes of one app have their memory summed
#[test]
fn two_scopes_of_one_app_have_their_memory_summed() {
    let ranking = rank(&scan_of(&[
        ("chrome#1", Some(0), 0, Some(3 * GIB)),
        ("chrome#2", Some(0), 0, Some(3 * GIB)),
        ("alpha", Some(0), 0, Some(5 * GIB)),
    ]));
    assert_eq!(
        ranking.top_memory,
        Some(memory_entry("chrome", (6 * GIB) as f64))
    );
}

/// row: a cgroup new this scan is left out of CPU but counted in memory
#[test]
fn a_cgroup_new_this_scan_is_left_out_of_cpu_but_counted_in_memory() {
    // 'fresh' has no previous reading; treating it as 0 would give it 100% CPU.
    let ranking = rank(&scan_of(&[
        ("old", Some(0), 1_000_000, Some(GIB)),
        ("fresh", None, 16_000_000, Some(9 * GIB)),
    ]));
    assert_eq!(top_cpu_name(&ranking), "old");
    assert_eq!(top_memory_name(&ranking), "fresh");
}

/// row: kernel is the root delta minus the parents' delta: root 90 ms, one 40 ms parent, 50 ms of machine time
#[test]
fn kernel_is_the_root_delta_minus_the_parents_delta() {
    // The leaf equals its parent (no short jobs), so kernel's 50 ms of 16 s is the only other candidate.
    let scan = with_parents(
        scan_of(&[("app", Some(0), 40_000, Some(1))]),
        &[("app", "p")],
        &[("p", 40_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 90_000));
    let expected_percent = 50_000.0 / MACHINE_CAPACITY_USEC * 100.0;
    assert_eq!(
        ranking.top_cpu,
        Some(pseudo_cpu_entry(
            "pseudo:kernel",
            "kernel",
            expected_percent
        ))
    );
}

/// row: kernel tops CPU when the parents are small: root 12 s, parents 1 s
#[test]
fn kernel_tops_cpu_when_the_parents_are_small() {
    let scan = with_parents(
        scan_of(&[("app", Some(0), 1_000_000, Some(1))]),
        &[("app", "p")],
        &[("p", 1_000_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 12_000_000));
    assert_eq!(
        ranking.top_cpu,
        Some(pseudo_cpu_entry("pseudo:kernel", "kernel", 68.75))
    );
}

/// row: kernel is root minus parents, not minus leaves: a leaf total below its parent's does not inflate it
#[test]
fn kernel_is_root_minus_parents_not_minus_leaves() {
    // Root 12 s, parent 11 s, its leaf 1 s: kernel is 1 s, short jobs 10 s. Root minus leaves would be 11 s.
    let scan = with_parents(
        scan_of(&[("app", Some(0), 1_000_000, Some(1))]),
        &[("app", "p")],
        &[("p", 11_000_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 12_000_000));
    assert_eq!(
        ranking.top_cpu,
        Some(pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 62.5))
    );
}

/// row: a parent missing from the parent deltas: neither kernel nor short jobs is ranked
#[test]
fn a_parent_missing_from_the_parent_deltas_ranks_neither_kernel_nor_short_jobs() {
    let scan = with_parents(
        scan_of(&[
            ("a", Some(0), 1_000, Some(1)),
            ("b", Some(0), 2_000, Some(1)),
        ]),
        &[("a", "p1"), ("b", "p2")],
        &[("p1", 9_000_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 12_000_000));
    assert_eq!(top_cpu_name(&ranking), "b");
}

/// row: empty parent maps: neither kernel nor short jobs is ranked, even with a root delta
#[test]
fn empty_parent_maps_rank_neither_kernel_nor_short_jobs_even_with_a_root_delta() {
    // Root minus zero parents would name the whole machine as kernel.
    let scan = with_root_delta(scan_of(&[("app", Some(0), 1_000_000, Some(1))]), 12_000_000);
    let ranking = rank(&scan);
    assert_eq!(ranking.top_cpu, Some(cpu_entry("app", 6.25)));
}

/// row: short jobs is a parent's delta beyond its leaves': 300 ms parent, 200 ms of leaves, 100 ms
#[test]
fn short_jobs_is_a_parents_delta_beyond_its_leaves() {
    let parents = |leaves: &[LeafSpec]| {
        with_parents(
            scan_of(leaves),
            &[("a", "p"), ("b", "p")],
            &[("p", 300_000)],
            &[],
        )
    };
    let ranking = rank(&parents(&[
        ("a", Some(0), 120_000, Some(1)),
        ("b", Some(0), 80_000, Some(1)),
    ]));
    assert_eq!(top_cpu_name(&ranking), "a");
    // Lift short jobs above the leaves to read its size: 100 ms of 16 s.
    let small = rank(&parents(&[
        ("a", Some(0), 20_000, Some(1)),
        ("b", Some(0), 20_000, Some(1)),
    ]));
    let expected_percent = 260_000.0 / MACHINE_CAPACITY_USEC * 100.0;
    assert_eq!(
        small.top_cpu,
        Some(pseudo_cpu_entry(
            "pseudo:short-jobs",
            "short jobs",
            expected_percent
        ))
    );
}

/// row: short jobs sums over parents, and a parent whose leaves exceed its delta (read skew) adds 0, never less
#[test]
fn short_jobs_sums_over_parents_and_read_skew_adds_zero() {
    // p1: 900 − 100 = 800. p2: leaf 300 > delta 100 → 0, not −200 (which would leave 600). 800 ms of 16 s is 5%.
    let scan = with_parents(
        scan_of(&[
            ("a", Some(0), 100_000, Some(1)),
            ("b", Some(0), 300_000, Some(1)),
        ]),
        &[("a", "p1"), ("b", "p2")],
        &[("p1", 900_000), ("p2", 100_000)],
        &[],
    );
    let ranking = rank(&scan);
    assert_eq!(
        ranking.top_cpu,
        Some(pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 5.0))
    );
}

/// row: a recreated leaf (counter went backwards: prev 9 s, now 3 s) counts 3 s, not 0
#[test]
fn a_recreated_leaf_counts_its_new_usage_not_zero() {
    let ranking = rank(&scan_of(&[("reset", Some(9_000_000), 3_000_000, Some(1))]));
    let expected_percent = 3_000_000.0 / MACHINE_CAPACITY_USEC * 100.0;
    assert_eq!(ranking.top_cpu, Some(cpu_entry("reset", expected_percent)));
}

/// row: a new leaf counts its full usage when its parent was listed before
#[test]
fn a_new_leaf_counts_its_full_usage_when_its_parent_was_listed_before() {
    let scan = with_parents(
        scan_of(&[
            ("fresh", None, 4_000_000, Some(1)),
            ("old", Some(0), 1_000_000, Some(1)),
        ]),
        &[("fresh", "p"), ("old", "p")],
        &[("p", 5_000_000)],
        &["p"],
    );
    let ranking = rank(&scan);
    assert_eq!(ranking.top_cpu, Some(cpu_entry("fresh", 25.0)));
}

/// row: a new leaf is skipped when its parent was not listed before (a failed listing is not a burst)
#[test]
fn a_new_leaf_is_skipped_when_its_parent_was_not_listed_before() {
    let scan = with_parents(
        scan_of(&[
            ("fresh", None, 4_000_000, Some(1)),
            ("old", Some(0), 1_000_000, Some(1)),
        ]),
        &[("fresh", "p"), ("old", "p")],
        &[("p", 5_000_000)],
        &[],
    );
    let ranking = rank(&scan);
    // fresh is out; short jobs = 5 s − old's 1 s = 4 s would win if fresh were counted too (then 0).
    assert_eq!(top_cpu_name(&ranking), "short jobs");
}

/// row: the memory half is never kernel or short jobs, however much is unattributed
#[test]
fn the_memory_half_is_never_kernel_or_short_jobs_however_much_is_unattributed() {
    // The gjs row also passes a `memoryUsedBytes` field of 10 GiB, which `rankApps` never reads and
    // `RankingScan` has no field for.
    let scan = with_parents(
        scan_of(&[("app", Some(0), 1_000, Some(2 * GIB))]),
        &[("app", "p")],
        &[("p", 11_000_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 12_000_000));
    assert_eq!(
        ranking.top_memory,
        Some(memory_entry("app", (2 * GIB) as f64))
    );
}

/// row: a root CPU counter that went backwards gives kernel 0%, never a negative share
#[test]
fn a_root_cpu_counter_that_went_backwards_gives_kernel_zero_percent() {
    // The parent has no leaf delta and zero delta: short jobs 0 too, so kernel's clamp decides the only candidate.
    let scan = with_parents(
        scan_of(&[("fresh", None, 1_000_000, Some(1))]),
        &[("fresh", "p")],
        &[("p", 0)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, -2_000_000));
    assert_eq!(
        ranking.top_cpu,
        Some(pseudo_cpu_entry("pseudo:kernel", "kernel", 0.0))
    );
}

/// row: without a root CPU delta there is no kernel
#[test]
fn without_a_root_cpu_delta_there_is_no_kernel() {
    let scan = with_parents(
        scan_of(&[("app", Some(0), 0, Some(0))]),
        &[("app", "p")],
        &[("p", 0)],
        &[],
    );
    let ranking = rank(&scan);
    assert_eq!(top_cpu_name(&ranking), "app");
    assert_eq!(top_memory_name(&ranking), "app");
}

/// row: equal values break ties by name ascending, in either insertion order
#[test]
fn equal_values_break_ties_by_name_ascending_in_either_insertion_order() {
    let beta_first = rank(&scan_of(&[
        ("beta", Some(0), 1_000_000, Some(5)),
        ("alpha", Some(0), 1_000_000, Some(5)),
    ]));
    let alpha_first = rank(&scan_of(&[
        ("alpha", Some(0), 1_000_000, Some(5)),
        ("beta", Some(0), 1_000_000, Some(5)),
    ]));
    for ranking in [&beta_first, &alpha_first] {
        assert_eq!(top_cpu_name(ranking), "alpha");
        assert_eq!(top_memory_name(ranking), "alpha");
    }
}

/// row: a real app tied with kernel (always ranked last) wins or loses by name, not by being first
#[test]
fn a_real_app_tied_with_kernel_wins_or_loses_by_name_not_by_being_first() {
    // root Δ 2M, parent Δ 1M, the leaf equals its parent: the leaf and kernel both have 1M.
    let tie = |name: &'static str| {
        let scan = with_parents(
            scan_of(&[(name, Some(0), 1_000_000, Some(5))]),
            &[(name, "p")],
            &[("p", 1_000_000)],
            &[],
        );
        rank(&with_root_delta(scan, 2_000_000))
    };
    assert_eq!(top_cpu_name(&tie("alpha")), "alpha");
    assert_eq!(top_cpu_name(&tie("zeta")), "kernel");
}

/// row: nothing scanned gives null rankings, not zeros
#[test]
fn nothing_scanned_gives_no_rankings_not_zeros() {
    assert_eq!(rank(&scan_of(&[])), AppRanking::default());
    assert_eq!(rank(&scan_of(&[])).top_cpu, None);
    assert_eq!(rank(&scan_of(&[])).top_memory, None);
}

/// row: no cgroup with a delta gives topCpu null while memory still ranks
#[test]
fn no_cgroup_with_a_delta_gives_no_top_cpu_while_memory_still_ranks() {
    let ranking = rank(&scan_of(&[("fresh", None, 5_000_000, Some(2 * GIB))]));
    let fresh_memory = memory_entry("fresh", (2 * GIB) as f64);
    assert_eq!(
        ranking,
        AppRanking {
            top_cpu: None,
            top_memory: Some(fresh_memory.clone()),
            cpu_ranking: vec![],
            memory_ranking: vec![fresh_memory],
        }
    );
}

/// How many groups more than a ranking holds the oversized input has.
const EXTRA_GROUP_COUNT: u64 = 2;

/// The gjs rows' `inputWithMoreGroupsThanTheRankingHolds`: more groups than a ranking holds, each
/// with distinct CPU and memory.
fn scan_with_more_groups_than_the_ranking_holds() -> RankingScan {
    let mut scan = RankingScan {
        elapsed_usec: ELAPSED_USEC,
        cpu_count: CPU_COUNT,
        ..RankingScan::default()
    };
    for group_index in 0..APP_RANKING_LENGTH + EXTRA_GROUP_COUNT {
        let path = format!("app-{group_index}");
        scan.previous_usage_usec.insert(path.clone(), 0);
        scan.current_usage_usec
            .insert(&path, (group_index + 1) * 100_000);
        scan.memory_bytes_by_cgroup
            .insert(&path, (group_index + 1) * GIB);
    }
    scan
}

/// row: apps: rankApps lists every group by CPU and by memory, largest first, at most APP_RANKING_LENGTH
#[test]
fn rank_apps_lists_every_group_by_cpu_and_by_memory_largest_first_at_most_the_ranking_length() {
    let ranking = rank(&scan_with_more_groups_than_the_ranking_holds());
    let ranking_length = usize::try_from(APP_RANKING_LENGTH).expect("a small number");
    assert_eq!(ranking.cpu_ranking.len(), ranking_length);
    assert_eq!(ranking.memory_ranking.len(), ranking_length);
    assert_eq!(ranking.cpu_ranking.first().cloned(), ranking.top_cpu);
    assert_eq!(ranking.memory_ranking.first().cloned(), ranking.top_memory);
    let cpu_percents: Vec<f64> = ranking.cpu_ranking.iter().map(|e| e.cpu_percent).collect();
    let memory_sizes: Vec<f64> = ranking
        .memory_ranking
        .iter()
        .map(|e| e.memory_bytes)
        .collect();
    assert!(cpu_percents.windows(2).all(|pair| pair[1] <= pair[0]));
    assert!(memory_sizes.windows(2).all(|pair| pair[1] <= pair[0]));
}

/// row: apps: equal values rank by name, then group key, so the order never depends on insertion
#[test]
fn equal_values_rank_by_name_then_group_key_so_the_order_never_depends_on_insertion() {
    let ranking = rank(&scan_of(&[
        ("b", Some(0), 1_000_000, Some(1)),
        ("a", Some(0), 1_000_000, Some(1)),
    ]));
    let group_keys: Vec<&str> = ranking
        .cpu_ranking
        .iter()
        .map(|entry| entry.group_key.as_str())
        .collect();
    assert_eq!(group_keys, ["a", "b"]);
    assert_eq!(ranking.cpu_ranking.first().cloned(), ranking.top_cpu);
}

/// row: apps: the memory ranking never names kernel or short jobs
#[test]
fn the_memory_ranking_never_names_kernel_or_short_jobs() {
    let scan = with_parents(
        scan_of(&[("app", Some(0), 1_000_000, Some(1))]),
        &[("app", "p")],
        &[("p", 11_000_000)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 12_000_000));
    assert!(!ranking
        .memory_ranking
        .iter()
        .any(|entry| entry.group_key.starts_with("pseudo:")));
    assert!(ranking
        .cpu_ranking
        .iter()
        .any(|entry| entry.group_key == "pseudo:short-jobs"));
}

/// row: apps: rankApps with nothing to rank gives empty lists
#[test]
fn rank_apps_with_nothing_to_rank_gives_empty_lists() {
    let ranking = rank(&scan_of(&[]));
    assert!(ranking.cpu_ranking.is_empty());
    assert!(ranking.memory_ranking.is_empty());
}

/// row: apps: the CPU ranking is empty whenever the CPU cannot be ranked
#[test]
fn the_cpu_ranking_is_empty_whenever_the_cpu_cannot_be_ranked() {
    let scan = RankingScan {
        elapsed_usec: 0,
        ..scan_of(&[("app", Some(0), 1_000_000, Some(GIB))])
    };
    let ranking = rank(&scan);
    assert_eq!(ranking.top_cpu, None);
    assert!(ranking.cpu_ranking.is_empty());
    assert_eq!(ranking.memory_ranking.len(), 1);
}

/// The brief's new row, "apps: maps iterate in insertion order" (not a gjs row, so unmarked).
/// Expected values: `rankApps` run under gjs. Memory of 2^53, 1 and 1 in one group sums to 2^53
/// in that order (each 1 is lost) and to 2^53 + 2 in the order 1, 1, 2^53; and the group takes the
/// name of the first leaf the CPU map holds and of the first the memory map holds, which can be
/// different leaves.
#[test]
fn maps_iterate_in_insertion_order() {
    let memory_sum = |leaves: &[LeafSpec]| rank(&scan_of(leaves)).memory_ranking;
    let big_first = memory_sum(&[
        ("g#1", Some(0), 0, Some(TWO_TO_THE_53)),
        ("g#2", Some(0), 0, Some(1)),
        ("g#3", Some(0), 0, Some(1)),
    ]);
    let big_last = memory_sum(&[
        ("g#1", Some(0), 0, Some(1)),
        ("g#2", Some(0), 0, Some(1)),
        ("g#3", Some(0), 0, Some(TWO_TO_THE_53)),
    ]);
    assert_eq!(big_first, [memory_entry("g", 9_007_199_254_740_992.0)]);
    assert_eq!(big_last, [memory_entry("g", 9_007_199_254_740_994.0)]);

    let one_group_named_by_leaf = |cgroup_path: &str| AppGroup {
        group_key: "k".to_string(),
        name: cgroup_path.to_string(),
    };
    let mut scan = scan_of(&[
        ("x2", Some(0), 1_000_000, None),
        ("x1", Some(0), 1_000_000, None),
    ]);
    scan.memory_bytes_by_cgroup.insert("x1", 3);
    scan.memory_bytes_by_cgroup.insert("x2", 4);
    let ranking = rank_apps(&scan, &mut |path| one_group_named_by_leaf(path));
    assert_eq!(top_cpu_name(&ranking), "x2");
    assert_eq!(top_memory_name(&ranking), "x1");
}

/// `Map.prototype.set` on a key that is present replaces the value and keeps the key's place;
/// the order of a new key is its first insertion. Expected value: a gjs `Map` set `a`, `b`, `a`, `c`
/// iterates as a, b, c with a's value the second one.
#[test]
fn inserting_a_present_key_replaces_its_value_and_keeps_its_place() {
    let mut map = InsertionOrderedMap::new();
    map.insert("a", 1);
    map.insert("b", 2);
    map.insert("a", 3);
    map.insert("c", 4);
    let entries: Vec<(&str, i32)> = map.iter().map(|(key, value)| (key, *value)).collect();
    assert_eq!(entries, [("a", 3), ("b", 2), ("c", 4)]);
    assert_eq!(map.get("b"), Some(&2));
    assert_eq!(map.get("missing"), None);
    assert_eq!(map.len(), 3);
    assert!(!map.is_empty());
}

/// Two groups with equal values and names that differ only outside the BMP order as JavaScript
/// orders them, by UTF-16 code unit: U+1F600 (D83D DE00) before U+E000, in either insertion order.
/// Rust's own string order would put U+E000 first. Expected order: `rankApps` run under gjs.
#[test]
fn equal_values_with_names_outside_the_bmp_rank_by_utf16_code_unit() {
    let emoji_leaf = "\u{1F600}x";
    let private_use_leaf = "\u{E000}x";
    for leaves in [
        [emoji_leaf, private_use_leaf],
        [private_use_leaf, emoji_leaf],
    ] {
        let scan = scan_of(&[
            (leaves[0], Some(0), 1_000_000, Some(7)),
            (leaves[1], Some(0), 1_000_000, Some(7)),
        ]);
        let ranking = rank(&scan);
        assert_eq!(cpu_ranking_names(&ranking), [emoji_leaf, private_use_leaf]);
        assert_eq!(top_memory_name(&ranking), emoji_leaf);
    }
}

/// Equal values and equal names go to the group key. Expected order: `rankApps` run under gjs.
#[test]
fn equal_values_and_names_rank_by_group_key() {
    let scan = scan_of(&[
        ("b", Some(0), 1_000_000, Some(1)),
        ("a", Some(0), 1_000_000, Some(1)),
    ]);
    let ranking = rank_apps(&scan, &mut |path| AppGroup {
        group_key: path.to_string(),
        name: "n".to_string(),
    });
    let group_keys: Vec<&str> = ranking
        .cpu_ranking
        .iter()
        .map(|entry| entry.group_key.as_str())
        .collect();
    assert_eq!(group_keys, ["a", "b"]);
}

/// Counters near the top of a `u64` are doubles in the gjs; sums, differences and shares of them
/// round as doubles do. Expected values: `rankApps` run under gjs (a counter of 2^63 + 1 reads as
/// 2^63, so one that fell from 2^63 + 1 to 2^63 has not gone backwards and its delta is 0).
#[test]
fn counters_near_the_top_of_a_u64_round_as_doubles_do() {
    let big = rank(&scan_of(&[
        ("big", Some(0), u64::MAX, Some(u64::MAX)),
        ("small", Some(0), 1, Some(1)),
    ]));
    assert_eq!(
        big.cpu_ranking,
        [
            cpu_entry("big", 115_292_150_460_684.69),
            cpu_entry("small", 0.0000062499999999999995),
        ]
    );
    assert_eq!(
        big.memory_ranking,
        [
            memory_entry("big", 18_446_744_073_709_552_000.0),
            memory_entry("small", 1.0)
        ]
    );
    let summed = rank(&scan_of(&[
        ("h#1", Some(0), 0, Some(u64::MAX)),
        ("h#2", Some(0), 0, Some(u64::MAX)),
    ]));
    assert_eq!(
        summed.memory_ranking,
        [memory_entry("h", 36_893_488_147_419_103_000.0)]
    );
    let two_to_the_63 = 1_u64 << 63;
    let not_backwards = rank(&scan_of(&[(
        "r",
        Some(two_to_the_63 + 1),
        two_to_the_63,
        Some(1),
    )]));
    assert_eq!(not_backwards.cpu_ranking, [cpu_entry("r", 0.0)]);
    let rounded_up = rank(&scan_of(&[("g#1", Some(0), 0, Some(TWO_TO_THE_53 + 1))]));
    assert_eq!(
        rounded_up.memory_ranking,
        [memory_entry("g", 9_007_199_254_740_992.0)]
    );
}

/// A root delta above 2^53 reads as a double: kernel's share is the double the gjs computes.
/// Expected values: `rankApps` run under gjs, whose literal 9007199254740993 is 2^53.
#[test]
fn a_root_delta_above_two_to_the_53_is_a_double() {
    let scan = with_parents(
        scan_of(&[("a", Some(0), 1_000_000, Some(1))]),
        &[("a", "p")],
        &[("p", 1)],
        &[],
    );
    let ranking = rank(&with_root_delta(scan, 9_007_199_254_740_993_i64));
    assert_eq!(
        ranking.cpu_ranking,
        [
            pseudo_cpu_entry("pseudo:kernel", "kernel", 56_294_995_342.131195),
            cpu_entry("a", 6.25),
            pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 0.0),
        ]
    );
}

/// `nameOfCgroup` is called for each leaf with a delta in the CPU loop, then for each leaf with
/// memory: new leaf `b` is skipped by the first loop only. Expected order: the calls under gjs.
#[test]
fn names_are_asked_for_in_the_cpu_loop_then_the_memory_loop() {
    let mut scan = with_parents(
        scan_of(&[
            ("a", Some(0), 5, None),
            ("b", None, 7, None),
            ("c", Some(0), 9, None),
        ]),
        &[("a", "p"), ("b", "p"), ("c", "p")],
        &[],
        &[],
    );
    scan.memory_bytes_by_cgroup.insert("c", 3);
    scan.memory_bytes_by_cgroup.insert("b", 2);
    scan.memory_bytes_by_cgroup.insert("a", 1);
    let mut asked_paths = Vec::new();
    rank_apps(&scan, &mut |path| {
        asked_paths.push(path.to_string());
        name_after_itself_up_to_hash(path)
    });
    assert_eq!(asked_paths, ["a", "c", "c", "b", "a"]);
}

/// A leaf with a previous reading counts even when no parent is recorded for it, and a new leaf
/// with no parent is never counted (it has no listed parent); a parent recorded for no leaf does
/// not stop kernel and short jobs. Expected values: `rankApps` run under gjs.
#[test]
fn a_leaf_with_no_recorded_parent_counts_only_with_a_previous_reading() {
    let scan = RankingScan {
        parent_cpu_delta_usec: {
            let mut deltas = InsertionOrderedMap::new();
            deltas.insert("p", 1_000_000);
            deltas
        },
        ..with_root_delta(
            scan_of(&[
                ("a", Some(0), 1_000_000, Some(1)),
                ("b", None, 1_000_000, Some(1)),
            ]),
            3_000_000,
        )
    };
    let ranking = rank(&scan);
    assert_eq!(
        ranking.cpu_ranking,
        [
            pseudo_cpu_entry("pseudo:kernel", "kernel", 12.5),
            cpu_entry("a", 6.25),
            pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 6.25),
        ]
    );
    assert_eq!(
        ranking.memory_ranking,
        [memory_entry("a", 1.0), memory_entry("b", 1.0)]
    );
}

/// No CPU count, or a negative elapsed time, leaves the CPU unranked and memory ranked.
#[test]
fn no_cpu_count_or_a_negative_elapsed_time_leaves_only_memory_ranked() {
    let no_cpus = RankingScan {
        cpu_count: 0,
        ..scan_of(&[("a", Some(0), 1_000_000, Some(1))])
    };
    let time_went_backwards = RankingScan {
        elapsed_usec: -5,
        ..scan_of(&[("a", Some(0), 1_000_000, Some(1))])
    };
    for scan in [no_cpus, time_went_backwards] {
        let ranking = rank(&scan);
        assert_eq!(ranking.top_cpu, None);
        assert!(ranking.cpu_ranking.is_empty());
        assert_eq!(ranking.memory_ranking, [memory_entry("a", 1.0)]);
    }
}

/// A group whose key is `pseudo:kernel` shares its total with kernel, under the name of the first
/// to be added; kernel and short jobs of equal value rank by name. Expected values: `rankApps`
/// run under gjs.
#[test]
fn a_real_group_with_a_pseudo_key_merges_with_kernel() {
    let scan = with_parents(
        scan_of(&[("k", Some(0), 1_000_000, Some(1))]),
        &[("k", "p")],
        &[("p", 1_000_000)],
        &[],
    );
    let ranking = rank_apps(&with_root_delta(scan, 3_000_000), &mut |_| AppGroup {
        group_key: "pseudo:kernel".to_string(),
        name: "impostor".to_string(),
    });
    assert_eq!(
        ranking.cpu_ranking,
        [
            pseudo_cpu_entry("pseudo:kernel", "impostor", 18.75),
            pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 0.0),
        ]
    );
}

/// Kernel and short jobs of equal value, and a parent whose delta fell below zero, which raises
/// kernel (root minus a negative total) and adds nothing to short jobs. Expected values: `rankApps`
/// run under gjs.
#[test]
fn kernel_and_short_jobs_of_equal_value_and_a_negative_parent_delta() {
    let leaf = [("a", Some(0), 1_000_000, Some(1))];
    let equal = with_parents(scan_of(&leaf), &[("a", "p")], &[("p", 3_000_000)], &[]);
    let equal_ranking = rank(&with_root_delta(equal, 3_000_000));
    assert_eq!(
        equal_ranking.cpu_ranking,
        [
            pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 12.5),
            cpu_entry("a", 6.25),
            pseudo_cpu_entry("pseudo:kernel", "kernel", 0.0),
        ]
    );
    let negative = with_parents(scan_of(&leaf), &[("a", "p")], &[("p", -1_000_000)], &[]);
    let negative_ranking = rank(&with_root_delta(negative, 3_000_000));
    assert_eq!(
        negative_ranking.cpu_ranking,
        [
            pseudo_cpu_entry("pseudo:kernel", "kernel", 25.0),
            cpu_entry("a", 6.25),
            pseudo_cpu_entry("pseudo:short-jobs", "short jobs", 0.0),
        ]
    );
}

/// A share too small for its digits is the double the gjs computes. Expected value: `rankApps`
/// run under gjs.
#[test]
fn a_tiny_share_is_the_double_the_javascript_computes() {
    let ranking = rank(&scan_of(&[("a", Some(0), 1, Some(1))]));
    assert_eq!(
        ranking.cpu_ranking,
        [cpu_entry("a", 0.0000062499999999999995)]
    );
}

/// How many pseudo-random leaf names the no-panic row feeds the naming functions.
const NO_PANIC_NAME_COUNT: usize = 5000;
/// The pieces the no-panic row builds names from: the ones every pattern of `describeCgroup` reads.
const NO_PANIC_PIECES: [&str; 24] = [
    "app-",
    "gnome",
    "-",
    ".scope",
    ".service",
    "snap.",
    "docker-",
    "@",
    ".",
    "\\x",
    "4",
    "z",
    "0",
    "\n",
    "\u{2028}",
    "\u{1F600}",
    "\u{e9}",
    "-1",
    "-6dac35ea-863e-4f4f-a9a2-1c50d93840a1",
    "org.gnome.SettingsDaemon.",
    "org",
    "\u{130}",
    "\u{3a3}",
    "",
];
/// A fixed seed, so a failure repeats.
const NO_PANIC_SEED: u64 = 0x2545_F491_4F6C_DD1D;
/// The most pieces one pseudo-random name is built from.
const NO_PANIC_MAX_PIECES: u64 = 9;

/// A step of xorshift64: the pseudo-random sequence of the no-panic row.
fn next_pseudo_random(state: u64) -> u64 {
    let mut next = state;
    next ^= next << 13;
    next ^= next >> 7;
    next ^ (next << 17)
}

/// Every function that reads a leaf name survives a name built from the pieces of its patterns,
/// and each description's names are consistent: an app's key is `app:` and its id, and so on.
#[test]
fn no_leaf_name_made_of_pattern_pieces_panics_the_naming_functions() {
    let mut state = NO_PANIC_SEED;
    for _ in 0..NO_PANIC_NAME_COUNT {
        state = next_pseudo_random(state);
        let piece_count = state % NO_PANIC_MAX_PIECES;
        let mut leaf_name = String::new();
        for _ in 0..piece_count {
            state = next_pseudo_random(state);
            let piece_index = usize::try_from(state % NO_PANIC_PIECES.len() as u64).unwrap();
            leaf_name.push_str(NO_PANIC_PIECES[piece_index]);
        }
        let description = describe_cgroup(&leaf_name);
        let (name, _) = display_name_asking(&description, Some("resolved"));
        let _ = unescape_systemd_name(&leaf_name);
        match &description.kind {
            CgroupKind::App { app_id } => {
                assert_eq!(
                    description.group_key,
                    format!("app:{app_id}"),
                    "{leaf_name:?}"
                )
            }
            CgroupKind::Snap { snap_name, .. } => {
                assert_eq!(description.group_key, format!("snap:{snap_name}"));
                assert_eq!(name, "resolved");
            }
            CgroupKind::Docker => assert_eq!(description.group_key, "docker:docker"),
            CgroupKind::Unit => assert!(description.group_key.starts_with("unit:")),
        }
    }
}
