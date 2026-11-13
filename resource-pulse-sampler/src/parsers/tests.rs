//! The gjs rows of `gnome-shell/tests/parsers.test.js`, carried over (each is marked
//! `/// row: <title>`), and the rows that pin where JavaScript's matching and Rust's differ.
//! The real captures under `gnome-shell/tests/fixtures/real/` are read in place.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::PathBuf;

use super::cgroup::{
    parse_cpu_stat_usage_usec, parse_memory_stat_reclaimable_bytes, parse_single_number,
};
use super::proc::{
    parse_meminfo, parse_pressure_some_avg10, parse_proc_stat, parse_proc_swaps, parse_uid,
    parse_zram_mm_stat, CpuTimes, SwapArea, ZramMmStat,
};

/// The CPU count of the committed `proc-stat` capture.
const EXPECTED_REAL_CPU_COUNT: usize = 8;
const BYTES_PER_KIB: u64 = 1024;
/// `/proc/swaps`'s header, as the kernel writes it (tab separated).
const PROC_SWAPS_HEADER: &str = "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n";
/// The fixed seed of the no-panic row's pseudo-random texts.
const NO_PANIC_RANDOM_SEED: u64 = 0x5DEE_CE66_D1CE_4E5B;
/// How many pseudo-random texts the no-panic row feeds every parser.
const NO_PANIC_RANDOM_TEXT_COUNT: usize = 2000;
/// The longest pseudo-random text the no-panic row builds, in bytes.
const NO_PANIC_MAX_TEXT_BYTES: u64 = 200;
/// The names of the committed captures under `fixtures/real/`.
const REAL_FIXTURE_NAMES: [&str; 5] = [
    "meminfo",
    "pressure-cpu",
    "proc-stat",
    "proc-swaps",
    "zram-mm_stat",
];
/// A number of 30 digits: more than a `u64` holds.
const THIRTY_DIGITS: &str = "123456789012345678901234567890";

/// Reads a committed real capture from `gnome-shell/tests/fixtures/real/`.
fn read_real_fixture(file_name: &str) -> String {
    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../gnome-shell/tests/fixtures/real")
        .join(file_name);
    fs::read_to_string(&fixture_path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", fixture_path.display()))
}

/// A `CpuTimes` with the four counters every line has and the rest zero.
fn cpu_times(user: u64, nice: u64, system: u64, idle: u64) -> CpuTimes {
    CpuTimes {
        user,
        nice,
        system,
        idle,
        ..CpuTimes::default()
    }
}

/// Feeds `text` to every parser, to see that none panics; the answers are not looked at.
fn run_every_parser(text: &str) {
    let _ = parse_proc_stat(text);
    let _ = parse_meminfo(text);
    let _ = parse_pressure_some_avg10(text);
    let _ = parse_zram_mm_stat(text);
    let _ = parse_proc_swaps(text);
    let _ = parse_uid(text);
    let _ = parse_cpu_stat_usage_usec(text);
    let _ = parse_memory_stat_reclaimable_bytes(text);
    let _ = parse_single_number(text);
}

/// row: mm_stat: RAM cost is mem_used_total (field 3), not compr_data_size (field 2)
#[test]
fn zram_ram_cost_is_mem_used_total_not_compressed_size() {
    let zram = parse_zram_mm_stat(
        "1567870976 386016017 397680640        0 397688832     2083     3855     2147     2687\n",
    );
    assert_eq!(
        zram,
        Some(ZramMmStat {
            stored_bytes: 1_567_870_976,
            ram_bytes: 397_680_640
        })
    );
}

/// row: mm_stat: the real capture parses
#[test]
fn zram_real_capture_parses() {
    let zram = parse_zram_mm_stat(&read_real_fixture("zram-mm_stat")).unwrap();
    assert!(zram.stored_bytes > 0 && zram.ram_bytes > 0);
}

/// row: meminfo: kB values become bytes
#[test]
fn meminfo_kb_values_become_bytes() {
    let meminfo = parse_meminfo("MemTotal:       32000000 kB\nMemAvailable:   12000000 kB\n");
    assert_eq!(meminfo.get("MemAvailable"), Some(&(12_000_000 * 1024)));
}

/// row: meminfo: the real capture has MemTotal and MemAvailable
#[test]
fn meminfo_real_capture_has_total_and_available() {
    let meminfo = parse_meminfo(&read_real_fixture("meminfo"));
    assert!(meminfo.contains_key("MemTotal") && meminfo.contains_key("MemAvailable"));
}

/// row: PSI: reads the some line avg10, ignores the full line
#[test]
fn pressure_reads_the_some_line_and_ignores_the_full_line() {
    let text = "some avg10=4.70 avg60=5.19 avg300=4.63 total=1\nfull avg10=9.00 avg60=0 avg300=0 total=0\n";
    assert_eq!(parse_pressure_some_avg10(text), Some(4.7));
}

/// `\b` in `PSI_SOME_AVG10_PATTERN` is ASCII-only: `é` is not a word character, so `avg10` after it
/// is at a word boundary and matches. Expected value: `parsePressureSomeAvg10("some \u00e9avg10=2\n")`
/// run under gjs, which gives 2.
#[test]
fn pressure_word_boundary_is_ascii_only() {
    assert_eq!(parse_pressure_some_avg10("some \u{e9}avg10=2\n"), Some(2.0));
}

/// row: PSI: the real capture parses to a number
#[test]
fn pressure_real_capture_parses() {
    assert!(parse_pressure_some_avg10(&read_real_fixture("pressure-cpu")).is_some());
}

/// row: /proc/stat: guest and guest_nice parse into their own fields
#[test]
fn proc_stat_guest_and_guest_nice_have_their_own_fields() {
    let parsed =
        parse_proc_stat("cpu  100 0 100 700 100 0 0 0 50 7\ncpu0 100 0 100 700 100 0 0 0 50 7\n");
    let aggregate = parsed.aggregate.unwrap();
    assert_eq!((aggregate.guest, aggregate.guest_nice), (50, 7));
}

/// row: /proc/stat: the real capture yields 8 per-CPU entries
#[test]
fn proc_stat_real_capture_yields_eight_cpus() {
    let parsed = parse_proc_stat(&read_real_fixture("proc-stat"));
    assert_eq!(parsed.per_cpu.len(), EXPECTED_REAL_CPU_COUNT);
}

/// row: malformed lines yield null, never NaN
#[test]
fn malformed_lines_yield_none() {
    assert_eq!(parse_zram_mm_stat("garbage\n"), None);
    assert_eq!(parse_pressure_some_avg10("garbage\n"), None);
    assert_eq!(parse_uid("Name:\tx\n"), None);
    assert_eq!(parse_cpu_stat_usage_usec("garbage\n"), None);
}

/// row: memory.stat: reclaimable = active_file + inactive_file
#[test]
fn memory_stat_reclaimable_is_active_plus_inactive_file() {
    let text = "anon 10\nactive_file 300\ninactive_file 200\nshmem 5\n";
    assert_eq!(parse_memory_stat_reclaimable_bytes(text), Some(500));
}

/// row: cpu.stat: usage_usec
#[test]
fn cpu_stat_reads_usage_usec() {
    assert_eq!(
        parse_cpu_stat_usage_usec("usage_usec 89812225000\nuser_usec 1\n"),
        Some(89_812_225_000)
    );
}

/// row: status: Uid
#[test]
fn status_reads_the_real_uid() {
    let text = "Name:\tgnome-shell\nUid:\t1000\t1000\t1000\t1000\n";
    assert_eq!(parse_uid(text), Some(1000));
}

/// row: memory.current: a single number parses, "max" is null
#[test]
fn single_number_parses_and_max_is_none() {
    assert_eq!(parse_single_number("4096\n"), Some(4096));
    assert_eq!(parse_single_number("max\n"), None);
}

/// row: /proc/swaps: each area's Used column, KiB → bytes, from the real tab-and-space-separated capture
#[test]
fn swaps_used_column_in_bytes_from_the_real_capture() {
    assert_eq!(
        parse_proc_swaps(&read_real_fixture("proc-swaps")),
        Some(vec![
            SwapArea {
                filename: "/swap.img".to_string(),
                used_bytes: 0
            },
            SwapArea {
                filename: "/dev/zram0".to_string(),
                used_bytes: 5_594_672 * BYTES_PER_KIB
            },
        ])
    );
}

/// row: /proc/swaps: a header with no area under it is an empty list (no swap), not no data
#[test]
fn swaps_header_alone_is_an_empty_list() {
    assert_eq!(parse_proc_swaps(PROC_SWAPS_HEADER), Some(Vec::new()));
}

/// row: /proc/swaps: a malformed Used, a row short of a column or a header without Used is no data (null)
#[test]
fn swaps_malformed_used_short_row_or_headerless_used_is_none() {
    assert_eq!(
        parse_proc_swaps(&format!(
            "{PROC_SWAPS_HEADER}/swap.img\tfile\t8388604\tmany\t-1\n"
        )),
        None
    );
    // Every column up to Used is there, so only the column count can refuse it.
    assert_eq!(
        parse_proc_swaps(&format!("{PROC_SWAPS_HEADER}/swap.img\tfile\t8388604\t0\n")),
        None
    );
    assert_eq!(
        parse_proc_swaps("Filename\tType\tSize\tPriority\n/swap.img\tfile\t8388604\t-1\n"),
        None
    );
    assert_eq!(parse_proc_swaps(""), None);
}

/// A zram parse as (stored bytes, RAM bytes), `None` for no data.
type StoredAndRamBytes = Option<(u64, u64)>;

/// The one field value a test splices into each parser's text, and what each parser answers.
struct ReadDifferentlyCase {
    field: &'static str,
    /// `parse_proc_stat` on `cpu  F 0 0 0` and `cpu0 F 0 0 0`: the aggregate, and whether cpu 0 parsed.
    stat_aggregate_and_cpu_zero_parsed: (Option<u64>, bool),
    /// `parse_meminfo` on `Foo:  F kB`, `Bar:  F` and `Baz: 7`: which of Foo and Bar parsed.
    meminfo_foo_and_bar: (Option<u64>, Option<u64>),
    /// `parse_pressure_some_avg10` on `some avg10=F avg60=0`.
    pressure: Option<f64>,
    /// `parse_zram_mm_stat` on `F 0 5 0` and `5 0 F 0`.
    zram_field_one_and_three: (StoredAndRamBytes, StoredAndRamBytes),
    /// `parse_uid` on `Uid:\tF\t0` and on `Uid:\tF` then `Uid:\t5`.
    uid_alone_and_before_a_good_line: (Option<u32>, Option<u32>),
}

/// The fields `1e3`, `0x10`, `+5`, `-1`, an empty one and one too large for a `u64`, with what
/// the gjs parsers answered (`gjs -m` importing `lib/procParsers.js` and `lib/cgroupParsers.js`
/// and printing each call's result). Every parser not listed in a case answered null for every
/// field: `parseProcSwaps` on `<header>/swap\tfile\t8\tF\t-1`, `parseCpuStatUsageUsec` on
/// `usage_usec F`, `parseMemoryStatReclaimableBytes` on `active_file F` + `inactive_file 1`, and
/// `parseSingleNumber` on `F`.
fn read_differently_cases() -> Vec<ReadDifferentlyCase> {
    let no_data = ReadDifferentlyCase {
        field: "",
        stat_aggregate_and_cpu_zero_parsed: (None, false),
        meminfo_foo_and_bar: (None, None),
        pressure: None,
        zram_field_one_and_three: (None, None),
        uid_alone_and_before_a_good_line: (None, Some(5)),
    };
    vec![
        // gjs: psi 1, uid 1 and 1 (parseUid and PSI read the digits they find and stop).
        ReadDifferentlyCase {
            field: "1e3",
            pressure: Some(1.0),
            uid_alone_and_before_a_good_line: (Some(1), Some(1)),
            ..no_data
        },
        // gjs: psi 0, uid 0 and 0.
        ReadDifferentlyCase {
            field: "0x10",
            pressure: Some(0.0),
            uid_alone_and_before_a_good_line: (Some(0), Some(0)),
            ..no_data
        },
        // gjs: psi null, uid null and 5.
        ReadDifferentlyCase {
            field: "+5",
            ..no_data
        },
        ReadDifferentlyCase {
            field: "-1",
            ..no_data
        },
        // gjs: an empty field is nothing between two separators, so `\s+` and `split(/\s+/)`
        // close the gap: mm_stat `{0, 0}` for ` 0 5 0` and `{5, 0}` for `5 0  0`, uid 0 and 5.
        ReadDifferentlyCase {
            field: "",
            zram_field_one_and_three: (Some((0, 0)), Some((5, 0))),
            uid_alone_and_before_a_good_line: (Some(0), Some(5)),
            ..no_data
        },
        // The ONE deliberate difference from gjs, whose parsers answered an inexact
        // 1.2345678901234568e+29 for every one of these but the uid's (and 1.26e+32 for kB
        // values): a field of digits too large for the integer type is no data, exactly as a
        // field that is not a number is. The kernel's counters are 64-bit, so no kernel text
        // holds one. The uid's second answer is 5: the oversized line is no match, so the scan
        // goes on to the next line. Pressure is an f64 and holds the same double as gjs.
        ReadDifferentlyCase {
            field: THIRTY_DIGITS,
            pressure: Some(1.234_567_890_123_456_8e29),
            ..no_data
        },
    ]
}

/// Not a gjs row: pins the rule that each parser answers what the gjs parser answers for a field
/// JavaScript reads differently, except the one stated difference above.
#[test]
fn a_number_javascript_would_read_differently_is_no_data() {
    for case in read_differently_cases() {
        let field = case.field;
        let stat = parse_proc_stat(&format!("cpu  {field} 0 0 0\ncpu0 {field} 0 0 0\n"));
        assert_eq!(
            (
                stat.aggregate.map(|times| times.user),
                !stat.per_cpu.is_empty()
            ),
            case.stat_aggregate_and_cpu_zero_parsed,
            "proc stat, field {field:?}"
        );

        let meminfo = parse_meminfo(&format!("Foo:  {field} kB\nBar:  {field}\nBaz: 7\n"));
        assert_eq!(
            (meminfo.get("Foo").copied(), meminfo.get("Bar").copied()),
            case.meminfo_foo_and_bar,
            "meminfo, field {field:?}"
        );
        assert_eq!(meminfo.get("Baz"), Some(&7), "meminfo Baz, field {field:?}");

        assert_eq!(
            parse_pressure_some_avg10(&format!("some avg10={field} avg60=0\n")),
            case.pressure,
            "pressure, field {field:?}"
        );

        let zram_as_pair = |zram: Option<ZramMmStat>| zram.map(|z| (z.stored_bytes, z.ram_bytes));
        assert_eq!(
            (
                zram_as_pair(parse_zram_mm_stat(&format!("{field} 0 5 0\n"))),
                zram_as_pair(parse_zram_mm_stat(&format!("5 0 {field} 0\n"))),
            ),
            case.zram_field_one_and_three,
            "mm_stat, field {field:?}"
        );

        assert_eq!(
            parse_proc_swaps(&format!("{PROC_SWAPS_HEADER}/swap\tfile\t8\t{field}\t-1\n")),
            None,
            "swaps, field {field:?}"
        );
        assert_eq!(
            (
                parse_uid(&format!("Uid:\t{field}\t0\n")),
                parse_uid(&format!("Uid:\t{field}\nUid:\t5\n")),
            ),
            case.uid_alone_and_before_a_good_line,
            "uid, field {field:?}"
        );
        assert_eq!(
            parse_cpu_stat_usage_usec(&format!("usage_usec {field}\n")),
            None,
            "cpu.stat, field {field:?}"
        );
        assert_eq!(
            parse_memory_stat_reclaimable_bytes(&format!("active_file {field}\ninactive_file 1\n")),
            None,
            "memory.stat, field {field:?}"
        );
        assert_eq!(
            parse_single_number(&format!("{field}\n")),
            None,
            "single number, field {field:?}"
        );
    }
}

/// The next number of a xorshift64 sequence: a fixed seed makes the same texts every run.
fn next_pseudo_random(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

/// A pseudo-random text: half of them raw bytes (so invalid UTF-8, made valid by replacement),
/// half drawn from the characters the parsers look at.
fn pseudo_random_text(state: &mut u64) -> String {
    const INTERESTING: [&str; 24] = [
        "0",
        "1",
        "9",
        " ",
        "\t",
        "\n",
        "\r",
        "\u{a0}",
        "\u{85}",
        "\u{feff}",
        "\u{2028}",
        ":",
        "=",
        ".",
        "-",
        "+",
        "kB",
        "cpu",
        "some ",
        "avg10=",
        "Uid:",
        "usage_usec ",
        "Filename ",
        "Used ",
    ];
    let length = next_pseudo_random(state) % NO_PANIC_MAX_TEXT_BYTES;
    if next_pseudo_random(state) & 1 == 0 {
        let bytes: Vec<u8> = (0..length)
            .map(|_| next_pseudo_random(state).to_le_bytes()[0])
            .collect();
        return String::from_utf8_lossy(&bytes).into_owned();
    }
    (0..length)
        .map(|_| INTERESTING[(next_pseudo_random(state) % INTERESTING.len() as u64) as usize])
        .collect()
}

/// Not a gjs row: no text makes any parser panic.
#[test]
fn no_input_makes_one_panic() {
    let mut state = NO_PANIC_RANDOM_SEED;
    for _ in 0..NO_PANIC_RANDOM_TEXT_COUNT {
        run_every_parser(&pseudo_random_text(&mut state));
    }
    for fixture_name in REAL_FIXTURE_NAMES {
        let fixture_bytes = read_real_fixture(fixture_name).into_bytes();
        for prefix_length in 0..=fixture_bytes.len() {
            let prefix = &fixture_bytes[..prefix_length];
            run_every_parser(&String::from_utf8_lossy(prefix));
        }
    }
}

/// Not a gjs row: `\s` and `trim` are JavaScript's: U+FEFF and U+00A0 are whitespace, U+0085 is not.
#[test]
fn whitespace_is_javascripts_not_rusts() {
    let meminfo = parse_meminfo("A:\u{a0}5\u{a0}kB\u{a0}\nB:\u{85}5 kB\nC:\u{feff}5\n");
    let expected: HashMap<String, u64> =
        HashMap::from([("A".to_string(), 5 * BYTES_PER_KIB), ("C".to_string(), 5)]);
    assert_eq!(meminfo, expected);
    assert_eq!(parse_single_number("\u{a0} 5\u{feff}"), Some(5));
    assert_eq!(parse_single_number("\u{85}5"), None);
    assert_eq!(
        parse_zram_mm_stat("\u{feff}5\u{a0}0\t5\n").map(|z| z.ram_bytes),
        Some(5)
    );
    assert_eq!(parse_zram_mm_stat("\u{85}5 0 5"), None);
    assert_eq!(parse_uid("Uid:\u{a0} 7x\n"), Some(7));
    let swaps = parse_proc_swaps("\u{a0}Filename Used\n/a\u{a0}3\n\n  \n/b 4").unwrap();
    assert_eq!(
        swaps.iter().map(|area| area.used_bytes).collect::<Vec<_>>(),
        vec![3 * BYTES_PER_KIB, 4 * BYTES_PER_KIB]
    );
}

/// Not a gjs row: a cgroup file's `^` and `$` are bounded by JavaScript's four line terminators, and
/// `\s+` between a key and its number may cross them.
#[test]
fn cgroup_line_boundaries_are_javascripts_and_whitespace_crosses_them() {
    assert_eq!(parse_cpu_stat_usage_usec("usage_usec\n55\n"), Some(55));
    assert_eq!(
        parse_cpu_stat_usage_usec("x\u{2028}usage_usec 55\u{2029}"),
        Some(55)
    );
    assert_eq!(
        parse_cpu_stat_usage_usec("x\rusage_usec 55\r\ny 1"),
        Some(55)
    );
    // A trailing space is neither a line end nor a digit.
    assert_eq!(parse_cpu_stat_usage_usec("x\rusage_usec 55 \n"), None);
    assert_eq!(parse_cpu_stat_usage_usec("xusage_usec 55\n"), None);
    assert_eq!(parse_cpu_stat_usage_usec("usage_usec_x 55\n"), None);
    // The first line that matches wins.
    assert_eq!(
        parse_cpu_stat_usage_usec("usage_usec 1 x\nusage_usec 2\n"),
        Some(2)
    );
    assert_eq!(parse_single_number("5 5"), None);
    assert_eq!(parse_single_number(""), None);
}

/// Not a gjs row: the PSI pattern's `.*` takes the LAST `avg10=` on the `some` line, cannot cross a
/// line terminator, and `\b` needs a non-word character before it.
#[test]
fn pressure_picks_the_last_avg10_and_dot_stops_at_a_line_terminator() {
    assert_eq!(
        parse_pressure_some_avg10("some avg10=1 avg10=2\n"),
        Some(2.0)
    );
    assert_eq!(parse_pressure_some_avg10("some x\ravg10=2\n"), None);
    assert_eq!(parse_pressure_some_avg10("some\ravg10=2\n"), Some(2.0));
    assert_eq!(parse_pressure_some_avg10("some xavg10=2\n"), None);
    assert_eq!(parse_pressure_some_avg10("some avg10=2.\n"), Some(2.0));
    assert_eq!(parse_pressure_some_avg10("some avg10=2.5.7\n"), Some(2.5));
    assert_eq!(parse_pressure_some_avg10("somex avg10=2\n"), None);
    assert_eq!(parse_pressure_some_avg10(" some avg10=2\n"), None);
}

/// Not a gjs row: the shapes of a `/proc/meminfo` line and of `/proc/stat`'s, as the gjs patterns
/// accept them (gjs answers, from `gjs -m`).
#[test]
fn meminfo_and_stat_line_shapes() {
    let meminfo = parse_meminfo("A:  5kB\nB:  5 kBx\nC:  5   \nD: 5 kB \r\nE:5\n:6\nF G: 7\n");
    let expected: HashMap<String, u64> =
        HashMap::from([("C".to_string(), 5), ("D".to_string(), 5 * BYTES_PER_KIB)]);
    assert_eq!(meminfo, expected);
    // A later line wins, and its unit decides its own scale.
    assert_eq!(
        parse_meminfo("A: 1\nA: 2 kB\n").get("A"),
        Some(&(2 * BYTES_PER_KIB))
    );

    // A malformed later `cpu` line replaces the aggregate with no data.
    assert_eq!(parse_proc_stat("cpu 1 2 3 4\ncpu x\n").aggregate, None);
    let parsed =
        parse_proc_stat("cpu1 1 2 3 4\ncpu01 5 6 7 8\ncpu 1 2 3\n  cpu2 1 1 1 1 9 9 9 9 9 9 9 9\n");
    assert_eq!(parsed.aggregate, None, "three counters are too few");
    let expected_per_cpu: BTreeMap<u32, CpuTimes> = BTreeMap::from([
        (1, cpu_times(5, 6, 7, 8)),
        (
            2,
            CpuTimes {
                iowait: 9,
                irq: 9,
                softirq: 9,
                steal: 9,
                guest: 9,
                guest_nice: 9,
                ..cpu_times(1, 1, 1, 1)
            },
        ),
    ]);
    assert_eq!(parsed.per_cpu, expected_per_cpu);
    // A `cpu` index too large for a u32 is no CPU line.
    assert!(parse_proc_stat("cpu99999999999 1 2 3 4\n")
        .per_cpu
        .is_empty());
}

/// Not a gjs row: Uid's shape, and the overflow rule: a value that does not fit is a non-number
/// (never wrapped or saturated), whether it is read, summed or multiplied.
#[test]
fn uid_shape_and_overflow_is_no_data() {
    assert_eq!(parse_uid(" Uid:\t7\n"), None);
    assert_eq!(parse_uid("Uid:7\n"), None);
    assert_eq!(parse_uid("Uid:\t7abc\n"), Some(7));
    assert_eq!(parse_uid("Uid:\t4294967295\n"), Some(u32::MAX));
    assert_eq!(parse_uid("Uid:\t4294967296\n"), None);

    let u64_max = u64::MAX.to_string();
    assert_eq!(parse_single_number(&u64_max), Some(u64::MAX));
    assert_eq!(parse_single_number("18446744073709551616"), None);
    assert_eq!(
        parse_memory_stat_reclaimable_bytes(&format!("active_file {u64_max}\ninactive_file 1\n")),
        None,
        "the sum overflows"
    );
    // 2^54 kB is 2^64 bytes.
    assert_eq!(
        parse_meminfo("A: 18014398509481984 kB\nB: 1 kB\n").get("A"),
        None
    );
    assert_eq!(
        parse_proc_swaps(&format!(
            "{PROC_SWAPS_HEADER}/a\tfile\t8\t18014398509481984\t-1\n"
        )),
        None
    );
    // The first matching line that is a number wins.
    assert_eq!(
        parse_cpu_stat_usage_usec("usage_usec 99999999999999999999\nusage_usec 4\n"),
        Some(4)
    );
}
