# Resource Pulse compiled sampler: implementation plan, part one

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Land the Rust sampler program, proved equal to the gjs sampler and installed, with nothing starting
it: the design's first two pull requests.

**Architecture:** A single Cargo crate at the repository's top level holds a library (parsers, arithmetic,
naming, cadence, the sampler core, the payload writer, the bus face) and a thin binary. The core takes its
file reader, directory lister, clocks and app-name lookup as ports, so the gjs sampler's rows carry over
as unit tests and golden files generated from the gjs sampler pin the published JSON. One thread samples and
produces every bus message through the library's message-level API.

**Tech Stack:** Rust (stable, `rust-version = "1.89"`), `zbus` 6.2 (message-level API only, no object
server), `libc`; `serde_json` with `float_roundtrip` as a dev-dependency; gjs for the golden generator and
the private-bus rows; bash for the state table.

**Spec:** [`docs/superpowers/specs/2026-11-12-resource-pulse-compiled-sampler-design.md`](../specs/2026-11-12-resource-pulse-compiled-sampler-design.md)
(approved 2026-11-13). Read it first; this plan argues from it and does not repeat it.

**Status:** approved by the owner on 2026-11-13, with the five items under "Decided in planning".

**What this plan does not cover:** the switch of the unit, the deletion of the gjs sampler and the slow
signal (the design's third, fourth and fifth pull requests). Each is planned when the gate before it has
passed, because each depends on something measured here.

## Global Constraints

- **The live desktop is the owner's.** No task runs `./install`, starts, stops or restarts
  `resource-pulse.service`, touches the live session bus, or runs `gsettings set` or `gnome-extensions`.
  Every bus row runs under `dbus-run-session`. Never read `/proc/*/cmdline` or `environ`.
- **Nothing starts the program.** `systemd/resource-pulse.service` is not edited by any task here.
- **The bus name** is `io.github.quantivly.dotfiles.ResourcePulse1`, the object path
  `/io/github/quantivly/dotfiles/ResourcePulse1`, the interface the same string as the name, the protocol
  version 1. They are requested and served only on a private bus in this plan.
- **Name request flags:** "do not queue" only. Never `REPLACE_EXISTING`, never `ALLOW_REPLACEMENT`.
- **Order:** the connection is made without a name, the stream of incoming messages is opened, then the
  name is requested. The thread that samples sends every reply and every signal. No interface is registered
  with `zbus`'s object server.
- **Equality:** published JSON equals the gjs sampler's as parsed values: the same keys, `null` where `null`,
  every number the same double bit for bit. The state's text is compact, with `protocol`,
  `serviceStartedAtUsec`, `latestSampledAtUsec` and `sequence` before `snapshot`, whole numbers as plain
  digits, and never a negative zero.
- **No panic reaches the process.** `panic = "unwind"`; a catch around each tick and each call. Clippy denies
  `unwrap_used`, `expect_used`, `indexing_slicing`, `string_slice` and `panic` outside tests.
- **Test switches are command-line flags, never environment variables.**
- **House rules:** every new shell script passes `shellcheck -x`; `grep` is ugrep and `awk` is mawk here, so
  use `rg` and POSIX awk; every state table asserts its own row total (`EXPECTED_ROWS=`, compared); "could
  not run" is exit 2, never a pass; CI installs through `.github/actions/apt-install`; builds and tests run
  under the caps of `zsh/zshrc.buildlimits`.
- **Names:** every constant with a role is named, with its unit in the name. The crate is
  `resource-pulse-sampler/`, the program `resource-pulse-sampler`, installed at
  `~/.local/lib/resource-pulse/resource-pulse-sampler`.
- **Each pull request** runs `pre-commit run --all-files`, `./scripts/check-claude-md.sh` and
  `scripts/test-resource-pulse.sh`, and from pull request B on `scripts/test-resource-pulse-sampler.sh`,
  each at its asserted total.

## Decided in planning

These go beyond the design's text. Each is for the owner to check with this plan.

1. **The design's second pull request lands as five** (B to F below), each reviewable on its own and each
   leaving `main` working, since the program is unused throughout.
2. **Four more flags than the design's two,** none of them set by the unit, which the `ExecStart` row pins
   when the switch comes: `--tick-interval-ms` (the order row needs fast ticks), `--list-leaf-names` (the
   shadow run needs every leaf's name, and a publish carries ten), `--source-hash` (prints the hash the
   program carries) and `--print-constants` (for the row that compares the two languages' constants).
3. **Carried rows are checked by a list, not by eye:** `resource-pulse-sampler/tests/carried-rows.txt` holds
   the title of every gjs sampler row, and a check fails unless each title appears exactly once as a
   `/// row: <title>` comment on a Rust test, or in `carried-rows-exempt.txt` with a reason.
4. **Cargo's build directory** is `${XDG_CACHE_HOME:-$HOME/.cache}/resource-pulse/cargo-target`, set by the
   build step and by the test script. `.gitignore` also ignores `resource-pulse-sampler/target/`, for a
   `cargo` run by hand.
5. **The golden generator runs the real gjs face on a private bus,** so the golden files hold what a client
   actually received.

## Review Focus

Inputs the design implies and no carried row exercises. Each has its test in the task named.

1. **A cgroup tree with thousands of leaves** (containers). The scan finishes, the publish still carries ten
   entries, and the name cache does not grow without bound. Task 10.
2. **A `.desktop` file that is unreadable, not text, enormous or a symlink loop.** The lookup is a miss; it
   never hangs and never panics. Task 9.
3. **The bus going away mid-run** (a logout). The program exits cleanly, as the gjs service does, and prints
   no panic. Task 13.
4. **A CPU going offline or coming online between two samples.** The cluster percentages are a number or no
   data, never a division by zero or an index out of range. Task 6.
5. **The wall clock set backwards, and the process frozen for longer than a tick.** `sampledAtUsec` follows
   the wall clock, no interval goes negative, and no burst of catch-up Samples follows. Task 12.

---

## Pull request A: the gjs sampler takes its children in name order

The design's first pull request. It changes live behaviour on purpose: a group whose leaves resolve to
different names can change its name once. Its deploy restarts the gjs sampler once (its module changed).

### Task 1: Sort the listing

**Files:**
- Modify: `gnome-shell/extensions/resource-pulse@dotfiles/service/sampler.js` (`_listChildPaths`)
- Test: `gnome-shell/tests/service-sampler.test.js`
- Modify: `scripts/test-resource-pulse.sh` (`EXPECTED_ROWS=1213` → `1215`),
  `docs/GNOME_CONFIGURATION_GUIDE.md` ("1213 checks" → "1215 checks"), `CHANGELOG.md`

**Interfaces:**
- Produces: every cgroup listing the sampler uses is in JavaScript's default string order
  (`Array.prototype.sort()` with no comparator). Tasks 7, 10 and 11 reproduce exactly that order.

- [ ] **Step 1: Write the two failing rows** in `service-sampler.test.js`, with an in-memory lister that
  returns names in a given order:

  - `'app scan: a group takes the name of its first leaf in name order, whatever order the directory lists them in'`:
    under `app.slice`, leaves `snap.demo.daemon.service` and
    `snap.demo.gui-11111111-2222-3333-4444-555555555555.scope`; `resolveAppName` answers `'Demo'` for
    `demo_gui.desktop` and `null` otherwise. Run two scans' worth of ticks once with the lister returning the
    names in that order and once reversed. Assert in both runs that the memory ranking's entry with
    `groupKey` `'snap:demo'` has `name` `'demo'`.
  - `'app scan: name order is JavaScript default string order'`: leaves `a.service`, `B.service`,
    `_c.service`, listed in that order; a reader that records the paths it is asked for. Assert the three
    `cpu.stat` reads come in the order `B.service`, `_c.service`, `a.service`.

- [ ] **Step 2: Run them and see both fail**

  Run: `gjs -m gnome-shell/tests/run.js 2>&1 | rg 'name order|first leaf in name order'`
  Expected: two failing rows (the first reads `'Demo'` in the reversed run).

- [ ] **Step 3: Sort in `_listChildPaths`:** map over a sorted copy of `childNames` (`[...childNames].sort()`),
  and say in the method's JSDoc why: a group takes its first leaf's name, and the port must list in the same
  order.

- [ ] **Step 4: Run the table**

  Run: `bash scripts/test-resource-pulse.sh | tail -2`
  Expected: `1215 passed, 0 failed` after raising `EXPECTED_ROWS` and the guide's count.

- [ ] **Step 5: Commit, open the pull request.** Its description states the behaviour change and the one
  restart, and what `bash scripts/resource-pulse-module-closure.sh` shows for `service/main.js`.

---

## Pull request B: the crate, the bus link, and the proof that decides the library

### Task 2: The crate, its state table, its CI job and the caps

**Files:**
- Create: `resource-pulse-sampler/Cargo.toml`, `resource-pulse-sampler/Cargo.lock`,
  `resource-pulse-sampler/src/lib.rs`, `resource-pulse-sampler/src/main.rs`,
  `resource-pulse-sampler/src/constants.rs`, `resource-pulse-sampler/tests/carried-rows.txt`,
  `resource-pulse-sampler/tests/carried-rows-exempt.txt`
- Create: `scripts/test-resource-pulse-sampler.sh`, `scripts/resource-pulse-sampler-carried-rows.sh`
- Modify: `.gitignore`, `.github/workflows/ci.yml`, `zsh/zshrc.buildlimits`, `CHANGELOG.md`

**Interfaces:**
- Produces: `resource_pulse_sampler::constants`, one `pub const` per value below, named as
  `lib/constants.js` names it: `SAMPLE_INTERVAL_SECONDS = 2`, `APP_SCAN_INTERVAL_SECONDS = 20`,
  `APP_SCAN_UNWATCHED_INTERVAL_SECONDS = 60`, `BURST_CPU_RISE_POINTS = 15`, `BURST_COOLDOWN_TICKS = 2`,
  `REVEAL_SCAN_COOLDOWN_TICKS = 2`, `MIN_CPU_RANKING_WINDOW_SECONDS = 1`,
  `APP_SCAN_SKIPPED_UNIT_SUFFIXES` (seven, in the same order), `APP_MEMORY_STAT_MIN_BYTES = 64 MiB`,
  `CARD_HISTORY_SAMPLES = 150`, `PRESSURE_BAND_THRESHOLDS_PERCENT = [10, 25, 50]`,
  `PERFORMANCE_CAPACITY_RATIO = 0.9`, `ERROR_LOG_REPEAT_INTERVAL_USEC = 600_000_000`, `LOG_PREFIX`,
  `KERNEL_LABEL`, `SHORT_JOBS_LABEL`, `UNIT_DISPLAY_ALIASES`, `APP_RANKING_LENGTH = 10`; and from
  `lib/protocol.js`: `PROTOCOL_VERSION = 1`, `RESOURCE_PULSE_BUS_NAME`, `RESOURCE_PULSE_INTERFACE_NAME`,
  `RESOURCE_PULSE_OBJECT_PATH`, the three method names and `SAMPLE_SIGNAL_NAME`.
- Produces: `scripts/test-resource-pulse-sampler.sh`, the crate's state table. It sets `CARGO_TARGET_DIR`
  and `RUST_TEST_THREADS`, runs `cargo test --locked`, sums the `test result:` lines, runs each later
  task's checks, and compares the total with `EXPECTED_ROWS`. Exit 2 when cargo, gjs or `dbus-run-session`
  is missing.

- [ ] **Step 1: Write `Cargo.toml`.** `edition = "2021"`, `rust-version = "1.89"`; dependencies
  `zbus = { version = "6.2", default-features = false, features = ["default-rt"] }` and `libc = "0.2"`;
  dev-dependency `serde_json = { version = "1", features = ["float_roundtrip"] }`;
  `[profile.release]` with `panic = "unwind"`, `opt-level = 3`, `lto = true`, `codegen-units = 1`,
  `strip = true`; `[lints.clippy]` denying `unwrap_used`, `expect_used`, `indexing_slicing`, `string_slice`
  and `panic`. `lib.rs` allows those five under `cfg(test)` only.

- [ ] **Step 2: Write `constants.rs` and the row that compares it with the JavaScript.** The row is a gjs
  script run by the state table: it imports `lib/constants.js` and `lib/protocol.js`, runs
  `resource-pulse-sampler --print-constants` (a hidden flag that prints `NAME=value` lines), and fails on
  any name whose values differ or that one side lacks. One row per name.

- [ ] **Step 3: Generate `carried-rows.txt`** after pull request A has merged: the title of every `test(`
  in `service-sampler`, `service-dbus`, `parsers`, `math`, `apps` and `cadence` under `gnome-shell/tests/`,
  one per line, under a `# <file>` heading each. It must have exactly 179 titles (55, 9, 16, 22, 41, 36).
  `scripts/resource-pulse-sampler-carried-rows.sh` fails (exit 1) unless each title is found exactly once as
  `/// row: <title>` in the crate, or in `carried-rows-exempt.txt` as `<title><TAB><reason>`; exit 2 when it
  cannot read a file. In this task every title is exempt with the reason `not yet ported (task N)`; each
  later task removes the lines it ports. The state table counts one row per title.

- [ ] **Step 4: Add the CI job** `resource-pulse-sampler-test` (`ubuntu-latest`): the apt-install action
  with `gjs dbus-daemon libglib2.0-bin`; then `cargo fmt --check`, `cargo clippy --locked -- -D warnings`
  and `./scripts/test-resource-pulse-sampler.sh`, each with `--manifest-path resource-pulse-sampler/Cargo.toml`
  where it applies.

- [ ] **Step 5: Add the test-thread cap** to `zsh/zshrc.buildlimits` beside `CARGO_BUILD_JOBS`:
  `export RUST_TEST_THREADS="${RUST_TEST_THREADS:-$_bl_jobs}"`, and list it where `build-limits` lists
  `CARGO_BUILD_JOBS`.

- [ ] **Step 6: Run and commit**

  Run: `bash scripts/test-resource-pulse-sampler.sh | tail -2` and `bash scripts/check-state-table-totals.sh`
  Expected: the table passes at the total it prints, which becomes `EXPECTED_ROWS`; the totals check passes.

### Task 3: The bus link and the two orders

**Files:**
- Create: `resource-pulse-sampler/src/bus.rs`
- Modify: `resource-pulse-sampler/src/main.rs` (a placeholder service: a counter in place of the sampler)
- Test: `gnome-shell/tests/sampler-program-dbus.test.js` (private bus; run by the state table)

**Interfaces:**
- Produces, in `bus.rs`:

  ```rust
  pub enum BusEvent { Call(IncomingCall), NameVanished(String), Disconnected }
  pub struct IncomingCall { pub sender: String, pub member: String, pub interface: Option<String> /* + what a reply needs */ }
  pub enum NameOutcome { Owned, HeldByAnother }
  pub struct BusLink { /* the connection and the stream of incoming messages */ }
  impl BusLink {
      /// Connects to the session bus with NO name and opens the stream of incoming messages.
      pub fn connect_listening() -> Result<BusLink, BusError>;
      /// Asks for the name with DO_NOT_QUEUE only.
      pub fn request_name(&self, name: &str) -> Result<NameOutcome, BusError>;
      /// The next call or name loss, or None once `wait` has passed.
      pub fn next_event(&mut self, wait: std::time::Duration) -> Result<Option<BusEvent>, BusError>;
      pub fn reply_with_string(&self, call: &IncomingCall, text: &str) -> Result<(), BusError>;
      pub fn reply_empty(&self, call: &IncomingCall) -> Result<(), BusError>;
      pub fn reply_with_error(&self, call: &IncomingCall, error_name: &str, message: &str) -> Result<(), BusError>;
      pub fn emit_string_signal(&self, signal_name: &str, text: &str) -> Result<(), BusError>;
      /// From now on, the caller's disappearance from the bus arrives as BusEvent::NameVanished.
      pub fn follow_name(&self, unique_name: &str) -> Result<(), BusError>;
      pub fn unfollow_name(&self, unique_name: &str) -> Result<(), BusError>;
  }
  ```

- Produces: the flag `--tick-interval-ms <n>` (default 2000).

- [ ] **Step 1: Write the failing rows** in `sampler-program-dbus.test.js`. Each starts the program (path
  from the runner's first argument) on the private bus with `Gio.Subprocess`:

  - `'program: a state reply carrying sequence N arrives after Sample N and before Sample N+1'`: start with
    `--tick-interval-ms 20`; one connection subscribes to `Sample` and calls `GetState` in a loop for 10 s,
    recording the arrival order. For every reply with sequence N: no Sample with a sequence above N arrived
    before it, and the first Sample after it has sequence exactly N+1. Assert at least 200 replies and 400
    Samples were seen, so the row cannot pass on an idle run.
  - `'program: a call made the instant the name appears is answered, 50 starts out of 50'`: each time, watch
    the name, call `GetState` from the name-appeared handler with a 2 s timeout, stop the program.
  - `'program: a second copy exits 1 and the first still owns the name'`: assert the second's exit status is
    1, `GetNameOwner` still answers the first's unique name, and the first still answers `GetState`.
  - `'program: an unknown method is answered with org.freedesktop.DBus.Error.UnknownMethod'`, within 2 s.
  - `'program: Introspect returns the interface with its three methods and its signal'`.
  - `'program: the name was asked for with DO_NOT_QUEUE only'`: after the program owns the name, a helper
    connection asks for it with `REPLACE_EXISTING | DO_NOT_QUEUE`; assert the reply is "exists" (3), and
    that the program still owns the name.

- [ ] **Step 2: Run them and see them fail** (the program does not serve yet).

- [ ] **Step 3: Implement `BusLink`** on `zbus`'s message-level API: a builder with no name and no interface,
  a `MessageStream` made before `request_name_with_flags`, and each send awaited in turn on the calling
  thread. The placeholder `main.rs` loop: wait for an event until the next tick is due; on a tick, raise the
  counter and emit `Sample` with `{"sequence": n}`; answer `GetState` with the counter's JSON, the two watch
  calls with an empty reply, `Introspect` with the interface text, anything else with the unknown-method
  error.

- [ ] **Step 4: Run the rows until all six pass, three runs in a row.** If the order row or the start-up row
  cannot be made to pass with `zbus`, STOP and go to Task 4's "if it fails".

- [ ] **Step 5: Commit**

### Task 4: Measure it as used, and record the library decision

**Files:**
- Create: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-12-stage-two/library-decision/result.md`
  (outside the repository: a measurement record)
- Modify: `docs/superpowers/specs/2026-11-12-resource-pulse-compiled-sampler-design.md` ("Measured for this
  design": one added row and one sentence)

- [ ] **Step 1: Measure** the Task 3 program beside the spike's floor for 120 s, twice, on a private bus,
  with the spike's own `measure.sh` (under `dbus-spike/sources/`, pointed at the new program): CPU, resident
  and private memory, threads, binary size, and the count of hand-written lines in `bus.rs`.
- [ ] **Step 2: Record** the table in `result.md`, and add its row to the design under the spike's table, as
  "`zbus` 6.2.1, as this design uses it".
- [ ] **Step 3: Decide.** If both order rows passed three runs in a row and resident memory is under 6 MiB:
  the library is final; say so in the design in one sentence. **If it fails:** stop the build, write what
  failed and how in `result.md`, and report to the owner. The design names `rustbus` as the fallback, and
  taking it is his decision to confirm, not the builder's.
- [ ] **Step 4: Commit, open pull request B.**

---

## Pull request C: the pure modules

Each task ports one group of functions with its rows. A ported row is a Rust test with the gjs row's inputs
and expected values, marked `/// row: <title>`, and its line leaves `carried-rows-exempt.txt`.

### Task 5: The file parsers

**Files:**
- Create: `resource-pulse-sampler/src/parsers/mod.rs`, `proc.rs`, `cgroup.rs`
- Rows carried: all 16 of `gnome-shell/tests/parsers.test.js`; the fixtures under
  `gnome-shell/tests/fixtures/real/` are read in place.

**Interfaces:**
- Produces (names and nullability as `lib/procParsers.js` and `lib/cgroupParsers.js`; `None` where they
  return `null`):

  ```rust
  pub fn parse_proc_stat(text: &str) -> ProcStat;            // { aggregate: Option<CpuTimes>, per_cpu: BTreeMap<u32, CpuTimes> }
  pub fn parse_meminfo(text: &str) -> HashMap<String, u64>;  // bytes, or a bare count
  pub fn parse_pressure_some_avg10(text: &str) -> Option<f64>;
  pub fn parse_zram_mm_stat(text: &str) -> Option<ZramMmStat>;   // { stored_bytes, ram_bytes }
  pub fn parse_proc_swaps(text: &str) -> Option<Vec<SwapArea>>;  // { filename, used_bytes }
  pub fn parse_uid(status_text: &str) -> Option<u32>;
  pub fn parse_cpu_stat_usage_usec(text: &str) -> Option<u64>;
  pub fn parse_memory_stat_reclaimable_bytes(text: &str) -> Option<u64>;
  pub fn parse_single_number(text: &str) -> Option<u64>;
  ```

- [ ] **Step 1: Write the 16 carried rows and two new ones, failing:**
  - `'parsers: a number JavaScript would read differently is no data'`: for each parser, a field holding
    `1e3`, `0x10`, `+5`, `-1`, an empty string and a 30-digit number gives what the gjs parser gives for the
    same text. Take the expected values by running the gjs parser, and say so in the test.
  - `'parsers: no input makes one panic'`: 2,000 pseudo-random byte strings (a fixed seed, no new
    dependency) and every prefix of each real fixture, through every parser.
- [ ] **Step 2: Run, see them fail. Step 3: Implement. Step 4: Run, see them pass,** with clippy clean.
- [ ] **Step 5: Remove the 16 titles from the exempt list, run the state table, commit.**

### Task 6: CPU, memory, pressure and the ring buffer

**Files:**
- Create: `resource-pulse-sampler/src/cpu.rs`, `memory.rs`, `pressure.rs`, `history.rs`
- Rows carried: all 22 of `gnome-shell/tests/math.test.js`

**Interfaces:**
- Produces:

  ```rust
  pub fn cpu_busy_fraction(previous: &CpuTimes, current: &CpuTimes) -> Option<f64>;
  pub fn cluster_busy_fraction(previous: &BTreeMap<u32, CpuTimes>, current: &BTreeMap<u32, CpuTimes>, cpus: &[u32]) -> Option<f64>;
  pub fn parse_cpu_list(text: &str) -> Vec<u32>;
  pub fn build_cluster_map(input: ClusterMapInput) -> Option<ClusterMap>;   // { performance_cpus, efficiency_cpus }
  pub fn zram_swap_device_names(swap_areas: &[SwapArea]) -> Vec<String>;
  pub fn memory_usage(meminfo: &HashMap<String, u64>) -> Option<MemoryUsage>;        // { used_bytes, total_bytes }
  pub fn swap_summary(swap_areas: &[SwapArea], zram_devices: &[ZramDevice]) -> SwapSummary;   // ZramDevice: device_name + ZramMmStat's two
  pub fn pressure_band(avg10_percent: Option<f64>) -> Option<u8>;                    // 0..=3
  pub struct RingBuffer { /* capacity, values: Option<f64> */ }                      // push, values, last_values, clear
  ```

- [ ] **Step 1: Write the 22 carried rows and one new one, failing:**
  `'cpu: a CPU that appears or vanishes between two samples gives a number or no data, never a panic'`: two
  per-CPU maps whose key sets differ in each direction, and one empty. (Review Focus 4.)
- [ ] **Step 2 to 4: Run, implement, run.** The arithmetic is in `f64`, in the order the JavaScript writes it;
  an integer becomes `f64` where the JavaScript first divides or multiplies by a non-integer.
- [ ] **Step 5: Remove the 22 titles from the exempt list, run the state table, commit.**

### Task 7: JavaScript's strings, and the naming and ranking of apps

**Files:**
- Create: `resource-pulse-sampler/src/js_string.rs`, `apps.rs`
- Rows carried: all 41 of `gnome-shell/tests/apps.test.js`

**Interfaces:**
- Produces:

  ```rust
  /// Orders as JavaScript's default sort and its `<` do: by UTF-16 code unit.
  pub fn js_string_order(left: &str, right: &str) -> std::cmp::Ordering;
  /// Turns each `\xNN` into the one character U+00NN, as String.fromCharCode does.
  pub fn unescape_systemd_name(name: &str) -> String;
  pub fn describe_cgroup(leaf_name: &str) -> CgroupDescription;   // group_key, kind, fallback_name, app ids
  pub fn display_name_for(description: &CgroupDescription, resolve_app_name: &mut dyn FnMut(&str) -> Option<String>) -> String;
  pub fn rank_apps(scan: &RankingScan, name_of_cgroup: &mut dyn FnMut(&str) -> AppGroup) -> AppRanking;
  ```

  `RankingScan` has the fields of `rankApps`' `scan` in `lib/apps.js`, with maps that iterate in insertion
  order where the JavaScript's do. `AppGroup` is `{ group_key: String, name: String }`. `AppRanking` has
  `top_cpu`, `top_memory`, `cpu_ranking`, `memory_ranking`.

- [ ] **Step 1: Write the 41 carried rows and three new ones, failing:**
  - `'js strings: order is by UTF-16 code unit'`: `js_string_order("\u{1F600}", "\u{E000}")` is `Less`
    (the first is the surrogate pair D83D DE00), where Rust's own `str` order gives `Greater`; and for
    ASCII, `js_string_order("B", "_c")` and `js_string_order("_c", "a")` are both `Less`.
  - `'apps: an escaped non-ASCII byte becomes one character per byte, as today'`:
    `unescape_systemd_name("caf\\xc3\\xa9.service")` is `"caf\u{00C3}\u{00A9}.service"`.
  - `'apps: maps iterate in insertion order'`: two groups with equal values keep the order the JavaScript
    gives them; take the expected ranking by running `rankApps` in gjs, and say so in the test.
- [ ] **Step 2 to 4: Run, implement, run.**
- [ ] **Step 5: Remove the 41 titles from the exempt list, run the state table, commit.**

### Task 8: The scan cadence

**Files:**
- Create: `resource-pulse-sampler/src/cadence.rs`
- Rows carried: all 36 of `gnome-shell/tests/cadence.test.js`

**Interfaces:**
- Produces:

  ```rust
  pub enum ScanReason { First, Interval, Burst, WatchStart, WarmUp }
  pub struct CadenceState { /* the nine fields of decideAppScan's state */ }
  pub fn decide_app_scan(state: &CadenceState) -> Option<ScanReason>;   // None: no scan
  pub fn arms_warm_up(reason: ScanReason) -> bool;
  pub fn is_triggered_scan(reason: ScanReason) -> bool;
  ```

- [ ] **Step 1: Write the 36 carried rows, failing. Steps 2 to 4: Run, implement, run.**
- [ ] **Step 5: Remove the 36 titles from the exempt list, run the state table, commit, open pull request C.**

---

## Pull request D: the sampler core and the golden files

### Task 9: App names from `.desktop` files

**Files:**
- Create: `resource-pulse-sampler/src/desktop_names.rs`,
  `resource-pulse-sampler/tests/fixtures/desktop/` (data directories with `.desktop` files)
- Create: `gnome-shell/tests/desktop-names-reference.js` (prints what `GioUnix.DesktopAppInfo` answers for
  the fixture directories)

**Interfaces:**
- Produces:

  ```rust
  pub struct DesktopNameLookup { /* data directories in search order, the language list, PATH */ }
  impl DesktopNameLookup {
      pub fn from_environment(environment: &dyn Fn(&str) -> Option<String>, home: &std::path::Path) -> DesktopNameLookup;
      /// The app's name for a `.desktop` id, or None for a miss. Never panics, never follows more than one file.
      pub fn name_of(&self, desktop_id: &str) -> Option<String>;
  }
  ```

- [ ] **Step 1: Read the rule from the source of the GLib installed here.** `dpkg-query -W libglib2.0-0t64`
  gives the version; read `gio/gdesktopappinfo.c` and `glib/gkeyfile.c` at that tag. Write the rule as the
  module's header comment, with the file and function for each clause: the directory order (user first),
  ids formed from subdirectories, a hidden entry masking later directories, `Type`, `TryExec`, a missing
  `Name`, and the language order of `g_get_language_names`.
- [ ] **Step 2: Write the failing rows,** one per clause of that header, against the fixture directories, plus:
  - `'desktop names: the reference agrees'`: `desktop-names-reference.js`, run with `XDG_DATA_HOME` and
    `XDG_DATA_DIRS` pointed at the fixtures, prints id and name for every fixture id; the Rust lookup must
    print the same lines.
  - `'desktop names: a file that names a gettext catalogue is read by its own Name keys'`.
  - `'desktop names: an unreadable file, a directory, a file of random bytes, a 20 MiB file and a symlink loop are each a miss'`,
    each within 100 ms. (Review Focus 2.)
- [ ] **Step 3 and 4: Implement, run. Step 5: Commit.**

### Task 10: The sampler core

**Files:**
- Create: `resource-pulse-sampler/src/ports.rs`, `sampler.rs`, `rate_limited_log.rs`
- Rows carried: all 55 of `gnome-shell/tests/service-sampler.test.js`, on in-memory trees and on the
  fixture roots under `gnome-shell/tests/fixtures/`.

**Interfaces:**
- Produces, in `ports.rs`:

  ```rust
  pub enum ReadFailure { Vanished, Other(String) }   // Vanished: ENOENT or ENODEV, and nothing else
  pub trait FileReader { fn read_to_text(&self, path: &std::path::Path) -> Result<String, ReadFailure>; }   // bad bytes replaced
  pub trait DirectoryLister { fn subdirectory_names(&self, path: &std::path::Path) -> Result<Vec<String>, ReadFailure>; } // unsorted
  pub trait Clock { fn monotonic_usec(&self) -> u64; fn clock_label(&self) -> Result<String, String>; }
  ```

- Produces, in `sampler.rs`:

  ```rust
  pub struct Publish { pub snapshot: Snapshot, pub appended_history: Option<AppendedHistory> }
  pub struct SamplerPorts { pub reader: Box<dyn FileReader>, pub lister: Box<dyn DirectoryLister>, pub clock: Box<dyn Clock>,
                            pub resolve_app_name: Box<dyn FnMut(&str) -> Option<String>>, pub log: Box<dyn FnMut(&str)> }
  impl Sampler {
      pub fn new(fs_root: std::path::PathBuf, ports: SamplerPorts) -> Sampler;
      pub fn initialize(&mut self);
      /// One tick: a fast sample, a scan when due, one publish. Never panics outward.
      pub fn run_tick(&mut self, tick_number: u64) -> Publish;
      /// A watch starting or ending. Some(publish) for a reveal.
      pub fn set_detail_watched(&mut self, is_watched: bool) -> Option<Publish>;
      pub fn latest_snapshot(&self) -> Option<&Snapshot>;
      pub fn cpu_history(&self) -> &RingBuffer;
      pub fn memory_history(&self) -> &RingBuffer;
  }
  ```

  `Snapshot` has the nine fields of `service/sampler.js`'s `Snapshot` typedef, in that order.

- [ ] **Step 1: Write the 55 carried rows and four new ones, failing:**
  - `'sampler: a "no such device" read is a vanished cgroup, silent; any other failure is counted'`, with
    each handed in through the reader.
  - `'sampler: a file with invalid text is read with the bad bytes replaced'`, through the real reader on a
    file of bytes `66 6f 6f ff 0a`.
  - `'sampler: 5,000 leaves scan and publish ten entries, and the name cache holds at most 4,096 ids'`.
    (Review Focus 1.)
  - `'sampler: a tick whose scan panics publishes no data for the ranking, logs once, and the next tick runs'`,
    with a lister that panics.
- [ ] **Step 2 to 4: Run, implement, run.** Everything that can fail is worked out before any state changes.
  The listing is sorted with `js_string_order` in the one place the gjs sampler sorts.
- [ ] **Step 5: Remove the 55 titles from the exempt list, run the state table, commit.**

### Task 11: The payloads, the face, and the scenario and golden files

**Files:**
- Create: `resource-pulse-sampler/src/payload.rs`, `resource-pulse-sampler/src/service.rs`,
  `resource-pulse-sampler/tests/golden.rs`
- Rows carried: the 9 of `gnome-shell/tests/service-dbus.test.js`, as unit tests of `ServiceFace`
- Create: `gnome-shell/tests/golden/scenarios/*.json`, `gnome-shell/tests/golden/expected/*.json`,
  `gnome-shell/tests/golden/generate.js`
- Modify: `gnome-shell/tests/protocol.test.js` (one row), `scripts/test-resource-pulse.sh` (its total),
  `docs/GNOME_CONFIGURATION_GUIDE.md` (its count)

**Interfaces:**
- Produces, in `payload.rs`:

  ```rust
  pub fn sample_payload(publish: &Publish, sequence: u64, sampled_at_usec: u64) -> String;
  pub struct PublishedState<'a> { pub snapshot: Option<&'a Snapshot>, pub cpu_history: &'a RingBuffer, pub memory_history: &'a RingBuffer,
                                  pub service_started_at_usec: u64, pub latest_sampled_at_usec: Option<u64>, pub sequence: u64 }
  pub fn state_payload(state: &PublishedState) -> String;   // protocol, the two times, the sequence, then snapshot, then histories
  ```

- Produces, in `service.rs`, with no bus in it:

  ```rust
  pub struct WatchChange { pub any_watch_changed: bool, pub sender_has_watches: bool }
  pub struct ServiceFace { /* sequence, latest sampled time, watch counts by sender */ }
  impl ServiceFace {
      pub fn new(service_started_at_usec: u64) -> ServiceFace;
      /// Numbers a publish from 1 and returns the Sample's JSON. The sequence moves on even if sending then fails.
      pub fn next_sample(&mut self, publish: &Publish, real_usec: u64) -> String;
      pub fn state_text(&self, sampler: &Sampler) -> String;
      pub fn add_watch(&mut self, sender: &str) -> WatchChange;
      pub fn remove_watch(&mut self, sender: &str) -> WatchChange;   // a sender holding none: no change, no error
      pub fn drop_sender(&mut self, sender: &str) -> WatchChange;
  }
  ```

- Produces: a scenario file is
  `{"description": s, "serviceStartedAtUsec": n, "appNames": {id: name}, "steps": [step...]}`; a step is
  `{"tick": {"fsRoot": "root-a", "monotonicUsec": n, "realUsec": n, "clockLabel": "14:02"}}` or
  `{"watchDetail": true}` or `{"watchDetail": false}`. An expected file is
  `{"samples": [object...], "state": object}`.

- [ ] **Step 1: Write the scenarios:** one per fixture root (`root-a` then `root-b` for the deltas, and each of
  `root-bad-pmu`, `root-no-psi`, `root-no-stat`, `root-no-swaps`, `root-small-leaf`, `root-swap-disk`,
  `root-unit-types`, `root-vanished`); a watch started and ended around a burst; a snap whose two units
  resolve to different names; a unit name with `\xc3\xa9`. Add a fixture root for the last two.
- [ ] **Step 2: Write `generate.js`.** Under `dbus-run-session` it runs the real `ServiceSampler` and
  `ResourcePulseDBusService` through a scenario, with the clock, the label and the names from the file, and
  writes what a second connection received: each Sample and the last `GetState` reply.
  `generate.js --check` writes nothing and exits 1 when a committed expected file differs.
- [ ] **Step 3: Write the failing rows:**
  - the 9 carried rows of `service-dbus.test.js`, on `ServiceFace`;
  - in `tests/golden.rs`, `'golden: <scenario>'` for each: the Rust sampler, face and payload writer, run
    through the scenario with the same ports, give the expected file's values: the same keys, `null` where
    `null`, strings equal, numbers equal by `f64::to_bits`.
  - `'payload: the state is compact, with its four top-level numbers before the snapshot, as plain digits'`:
    the text before `"snapshot":` matches
    `^\{"protocol":1,"serviceStartedAtUsec":\d+,"latestSampledAtUsec":(\d+|null),"sequence":\d+,$`.
  - `'payload: a negative zero is written as 0'`.
  - in `protocol.test.js`, `'protocol: the parsers read every golden file'`: `parseSamplePayload` and
    `parseStatePayload` over every expected file give no `null` where the file has a value.
  - in the state table, `'golden: the gjs sampler still produces the committed files'` (`generate.js --check`).
- [ ] **Step 4: Implement `payload.rs`** as a hand-written writer (the shape is fixed, and the text is
  contract) and `service.rs`.
- [ ] **Step 5: Remove the 9 titles from the exempt list, which is now empty; run everything; commit; open
  pull request D.**

---

## Pull request E: the program

### Task 12: The wiring, the flags, the tick and the watchdog

**Files:**
- Create: `resource-pulse-sampler/src/real_ports.rs`, `tick_schedule.rs`, `watchdog.rs`
- Modify: `resource-pulse-sampler/src/main.rs`

**Interfaces:**
- Consumes: `BusLink` (Task 3), `Sampler` (Task 10), `ServiceFace` (Task 11), `DesktopNameLookup` (Task 9).
  A sender's first watch calls `follow_name`, its last `unfollow_name`; a `NameVanished` calls
  `drop_sender`; `any_watch_changed` calls `set_detail_watched`, and a reveal it returns is sent at once.
- Produces, in `tick_schedule.rs`:
  `pub fn next_tick_at_usec(first_tick_at_usec: u64, interval_usec: u64, now_usec: u64) -> u64`, the
  first whole interval after `now`, so a missed tick is skipped.
- Produces: the program's flags: `--fs-root <path>` (default `/`), `--print` (no bus; one JSON line per
  publish on stdout), `--tick-interval-ms <n>`, `--list-leaf-names`, `--source-hash`, `--print-constants`.
  Exit status 0 after the name was owned and the bus went away, 1 when the name is held by another or the bus
  cannot be reached, 2 for a flag it does not know.
- Produces, in `watchdog.rs`: `pub fn notify_alive()`, which sends `WATCHDOG=1` to `$NOTIFY_SOCKET` (a path or
  an abstract name starting with `@`) and does nothing when it is unset.

- [ ] **Step 1: Write these rows, failing:**
  - `'program: ticks do not drift and a missed tick is skipped'`: with a first tick at 0 and an interval of
    2 s, `next_tick_at_usec` gives 2 s at 0.1 s, 4 s at 2.0 s, and 10 s at 9.3 s (after a 7 s stall): one
    tick, not three. (Review Focus 5.)
  - `'program: sampledAtUsec follows the wall clock when it is set backwards'`, with no panic and no negative
    figure in the payload. (Review Focus 5.)
  - `'program: a panic inside a tick is caught, logged under one key, and the next tick publishes'`.
  - `'watchdog: a path and an abstract address each get WATCHDOG=1'`, against two datagram sockets the test
    opens; `'watchdog: no NOTIFY_SOCKET sends nothing'`.
  - `'program: the clock label is local time'`: run `--print --tick-interval-ms 50` under `TZ=UTC` and under
    `TZ=Asia/Tokyo` and assert the two labels differ by nine hours modulo 24, give or take one minute.
- [ ] **Step 2 to 4: Run, implement, run.** `main.rs`: parse flags; build the real ports; connect listening;
  request the name; then one loop that waits for a bus event until the next tick is due, runs the tick inside
  `catch_unwind`, sends the Sample, calls `notify_alive`, and answers each call inside `catch_unwind`. The
  real clock label calls `tzset` and then `localtime_r` for each label.
- [ ] **Step 5: Run the state table, commit.**

### Task 13: The real program on a private bus, and its conformance with the gjs face

**Files:**
- Modify: `gnome-shell/tests/sampler-program-dbus.test.js`

- [ ] **Step 1: Write the failing rows,** each starting the real program with `--fs-root` on a fixture root:
  - `'program: GetState, then a Sample, on root-a'`: the state has `protocol` 1 and memory, and the Sample's
    sequence is one more than the state's.
  - `'program: WatchDetail reveals the ranking at once'`: a Sample with `appendedHistory` `null` and an
    `apps` ranking arrives within 1 s of the call, without waiting for a tick (`--tick-interval-ms 5000`).
  - `'program: a caller that disconnects loses its watches'`: client A calls `WatchDetail` and gets its
    reveal, then closes its connection; 1.5 s later client B calls `WatchDetail` and must get a reveal of
    its own within 1 s. A watch still held for A would make B's call no watch start, and no reveal.
  - `'program: a tree of truncated and garbage files keeps publishing'`: a fixture root whose every file is
    cut at a random offset or filled with random bytes; 50 ticks at 20 ms; 50 Samples, each parsed by
    `parseSamplePayload`, and the program still alive.
  - `'program: the bus going away ends it cleanly'`: stop the private `dbus-daemon`; the exit status is 0 and
    stderr holds no `panicked`. (Review Focus 3.)
  - `'conformance: the program and the gjs face look the same to a client'`: the same scripted exchange
    (connect, `GetState`, two ticks, `WatchDetail`, a reveal, `UnwatchDetail`, disconnect) against the gjs
    `ServiceSampler` and `ResourcePulseDBusService`, built in the test on `root-a`, and against the program
    on `root-a`. The two transcripts are equal as parsed values once the five clock fields are removed:
    `sampledAtUsec`, `serviceStartedAtUsec`, `latestSampledAtUsec`, `takenAtUsec`, `takenAtClockLabel`.
  - The six rows of Task 3 stay, now against the real program.
- [ ] **Step 2 to 4: Run, fix what they find, run three times in a row.**
- [ ] **Step 5: Commit, open pull request E.**

---

## Pull request F: the build step, the shadow run, and the gate

### Task 14: `./install` builds and installs the program

**Files:**
- Create: `scripts/resource-pulse-sampler-build.sh`, `resource-pulse-sampler/build.rs`
- Modify: `install.conf.yaml` (one step, before the reload-and-refresh step), `scripts/test-resource-pulse-sampler.sh`,
  `docs/GNOME_CONFIGURATION_GUIDE.md`, `CHANGELOG.md`

**Interfaces:**
- Produces: `scripts/resource-pulse-sampler-build.sh [--check]`. It always exits 0 from `./install` (a
  failing step would stop the install for everyone) and prints one line: `✓ … built and installed`,
  `✓ … unchanged`, `· … not opted in`, or `⚠ … not built: <why>`. With `--check` it builds nothing and exits
  0, 1 or 2 for "installed and current", "missing or older than the checkout", "could not tell".
- Produces: `build.rs` computes a SHA-256 over the crate's `src/`, `build.rs`, `Cargo.toml` and `Cargo.lock`
  (file paths and contents, in sorted order; never the commit, never the time) and the program prints it for
  `--source-hash`. The script computes the same hash from the checkout for `--check`.

- [ ] **Step 1: Write the failing rows** in the state table, each against a stub `cargo` on a private `PATH`,
  a private `HOME` and a copy of the crate:
  - not opted in (`~/.gnome-settings.local` absent, or with no line that calls
    `genable_extension resource-pulse@dotfiles`, a commented-out one not counting): cargo is never run;
  - opted in, no cargo: the `⚠ … not built` line names cargo, exit 0, nothing installed;
  - cargo older than `rust-version`: the line names both versions, nothing installed;
  - the build fails: the line says so, the previously installed file is byte-identical and keeps its time;
  - the build succeeds: the file is installed by a rename (a row asserts no moment at which the final path
    is missing or empty, by a reader looping on it during the install);
  - **a second run with nothing changed renames nothing:** the installed file's inode and time are unchanged;
  - the build runs with `CARGO_BUILD_JOBS` set from the same rule as `zsh/zshrc.buildlimits`, and with
    `--locked`;
  - `--check` gives 0, 1 and 2 in the three states;
  - the stub's `cargo --version` line is compared once with the real cargo's shape.
- [ ] **Step 2 to 4: Run, implement, run.** Opted in is read from `~/.gnome-settings.local`, as
  `scripts/apply-gnome-settings.sh` reads it. The install step in `install.conf.yaml` follows the form of the
  refresh step beside it, comment included.
- [ ] **Step 5: Commit.** The pull request's description reports the `install.conf.yaml` diff, as the standing
  rule asks.

### Task 15: The shadow run

**Files:**
- Create: `scripts/resource-pulse-shadow-names.sh`, `gnome-shell/tests/shadow/name-leaves.js`
- Modify: `resource-pulse-sampler/src/main.rs` (`--list-leaf-names`)

**Interfaces:**
- Produces: both namers print one line per leaf, sorted by path:
  `<leaf path>\t<group key>\t<name>\t<desktop id or ->\t<hit|miss|->`.
- Produces: `scripts/resource-pulse-shadow-names.sh <results dir>`. It reads `XDG_DATA_DIRS`,
  `XDG_DATA_HOME`, `PATH`, `LANGUAGE`, `LANG`, `LC_ALL` and `LC_MESSAGES` from
  `systemctl --user show-environment` (through `scripts/redact-secrets.sh`), runs both namers under exactly
  those, and writes both listings, their diff and a summary. Exit 0 when every leaf in both listings has the
  same group key and name and every kind present resolved at least one name; 1 on a difference or a kind with
  no name resolved; 2 when it could not run. It opens no bus connection.

- [ ] **Step 1: Write the failing rows,** against a fixture cgroup tree and fixture data directories: equal
  listings pass; one differing name fails and the summary names the leaf; a tree with snaps where no snap
  resolves a name fails on the floor; an unreadable environment is exit 2.
- [ ] **Step 2 to 4: Run, implement, run. Step 5: Commit.**

### Task 16: The sweep, the documents and the gate report

**Files:**
- Modify: `docs/GNOME_CONFIGURATION_GUIDE.md`, `CHANGELOG.md`,
  `docs/superpowers/specs/2026-11-12-resource-pulse-compiled-sampler-design.md` (what was built, in a section
  "As built, part one")

- [ ] **Step 1: The mutation sweep.** Commit first. Then, one mutant at a time, each dry-run for applicability
  and run with a timeout that kills the group, under `RUST_TEST_THREADS`: at least one mutant per rule in
  "Global Constraints" (the name flags, the order of listening and naming, the sort, the compact state, the
  negative zero, the catch around a tick, the `cmp` before the rename, the shadow run's floor) and one per
  ported module. A survivor is a missing row: add it.
- [ ] **Step 2: The guide** gains what a reader must know: the program exists and is not yet run, how it is
  built, the known limit on translated app names, and the new table's row count.
- [ ] **Step 3: Run the shadow run** several times over a working day (it reads `/sys` and `.desktop` files
  only) and put its summaries in the design's "As built, part one".
- [ ] **Step 4: Report the gate to the owner:** the two order rows, the golden checks, the library decision,
  the shadow run's results, and every deviation from the design, each with its reason. The switch is planned
  only after that report.
- [ ] **Step 5: Commit, open pull request F.**

---

## Self-review of this plan against the design

- **Covered:** the leaf sort (Task 1); the crate, caps, CI (2); the name flags, listening before the name,
  one thread, unknown calls and `Introspect`, the first-task proof and measurement (3, 4); the ported modules
  with every row carried (5 to 8, 10, 11); the three string rules (7, 10); app names without GLib and without
  catalogues (9); the panic rule (2, 10, 12, 13); ticks that do not drift (12); golden files, parsed equality,
  the comparing parser, the state's text, the negative zero, the shell's parser on the same files (11); the
  private-bus round trip and conformance (13); the build step, the unchanged install, the two questions,
  worker caps, the build directory (2, 14); the shadow run in the unit's environment with its floor (15); the
  mutation sweep (16).
- **Left for the next plans, by design:** the unit and its watchdog setting, the refresh rule's look after a
  restart, `gnome-status`, `verify-tools.sh`, the memory caps, the deletion and the single test double, the
  slow signal, burst scans measured under the replayed history, the two live checks.
