//! The sampler program. Until the later tasks wire the sampler, it serves a placeholder on the
//! session bus: a counter in place of the sampler, through the real bus link, so that the rows of
//! `gnome-shell/tests/sampler-program-dbus.test.js` hold the link to its orders. Each tick raises
//! the counter and emits `Sample` with `{"sequence": n}`; `GetState` answers
//! `{"sequence": n, "vanishedCallers": k}`, where k counts the callers of `WatchDetail` that have
//! since left the bus.
//!
//! `--print-constants` prints every constant for the gjs comparison row
//! (`gnome-shell/tests/sampler-constants.js`) and opens no connection.
//!
//! Exit status: 0 once the bus has gone away after the name was owned; 1 when another copy holds
//! the name or the bus cannot be reached; 2 for a flag it does not know.

use std::process::ExitCode;
use std::time::{Duration, Instant};

use resource_pulse_sampler::bus::{
    BusError, BusEvent, BusLink, IncomingCall, NameOutcome, INTROSPECTABLE_INTERFACE_NAME,
    INTROSPECT_METHOD_NAME, UNKNOWN_METHOD_ERROR_NAME,
};
use resource_pulse_sampler::constants::{
    constant_lines, GET_STATE_METHOD_NAME, LOG_PREFIX, RESOURCE_PULSE_BUS_NAME,
    RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH, SAMPLE_INTERVAL_SECONDS,
    SAMPLE_SIGNAL_NAME, UNWATCH_DETAIL_METHOD_NAME, WATCH_DETAIL_METHOD_NAME,
};

/// Prints the constants and exits.
const PRINT_CONSTANTS_FLAG: &str = "--print-constants";
/// Sets the interval between ticks, in milliseconds (the rows tick fast).
const TICK_INTERVAL_FLAG: &str = "--tick-interval-ms";
/// What the program says to stderr when it is called with anything else.
const USAGE_LINE: &str =
    "usage: resource-pulse-sampler [--print-constants] [--tick-interval-ms <milliseconds>]";
/// Exit status for a call the program does not understand.
const USAGE_EXIT_CODE: u8 = 2;
/// Exit status when the name was never owned: another copy holds it, or there is no bus.
const NAME_NOT_OWNED_EXIT_CODE: u8 = 1;
/// The interval between ticks without the flag: the sampler's own.
const DEFAULT_TICK_INTERVAL: Duration = Duration::from_secs(SAMPLE_INTERVAL_SECONDS);

/// What the flags ask for.
enum ProgramMode {
    PrintConstants,
    Serve { tick_interval: Duration },
}

/// The placeholder for the sampler: a counter raised on each tick, and how many followed callers
/// have left the bus.
#[derive(Debug, Default)]
struct PlaceholderService {
    /// The sequence of the latest Sample, 0 before the first.
    sequence: u64,
    /// How many NameVanished events the followed callers have produced.
    vanished_caller_count: u64,
}

impl PlaceholderService {
    /// The Sample's text: `{"sequence": n}`.
    fn sample_text(&self) -> String {
        format!("{{\"sequence\":{}}}", self.sequence)
    }

    /// The state's text: `{"sequence": n, "vanishedCallers": k}`.
    fn state_text(&self) -> String {
        format!(
            "{{\"sequence\":{},\"vanishedCallers\":{}}}",
            self.sequence, self.vanished_caller_count
        )
    }
}

/// Prints the constants, or serves the placeholder; a flag it does not know is a usage error.
fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match parse_arguments(&arguments) {
        Some(ProgramMode::PrintConstants) => {
            for line in constant_lines() {
                println!("{line}");
            }
            ExitCode::SUCCESS
        }
        Some(ProgramMode::Serve { tick_interval }) => serve(tick_interval),
        None => {
            eprintln!("{USAGE_LINE}");
            ExitCode::from(USAGE_EXIT_CODE)
        }
    }
}

/// Reads the flags: `--print-constants`, `--tick-interval-ms <n>` with n a whole number of at
/// least 1, or neither. Anything else, or a flag without its value, is None.
fn parse_arguments(arguments: &[String]) -> Option<ProgramMode> {
    let mut remaining_arguments = arguments.iter();
    let mut should_print_constants = false;
    let mut tick_interval = DEFAULT_TICK_INTERVAL;
    while let Some(argument) = remaining_arguments.next() {
        match argument.as_str() {
            PRINT_CONSTANTS_FLAG => should_print_constants = true,
            TICK_INTERVAL_FLAG => tick_interval = parse_tick_interval(remaining_arguments.next()?)?,
            _ => return None,
        }
    }
    if should_print_constants {
        Some(ProgramMode::PrintConstants)
    } else {
        Some(ProgramMode::Serve { tick_interval })
    }
}

/// A tick interval in milliseconds; zero is refused, as it would never wait.
fn parse_tick_interval(milliseconds_text: &str) -> Option<Duration> {
    let milliseconds: u64 = milliseconds_text.parse().ok()?;
    (milliseconds > 0).then(|| Duration::from_millis(milliseconds))
}

/// Connects listening, asks for the name, then serves until the bus goes away.
fn serve(tick_interval: Duration) -> ExitCode {
    let mut bus_link = match BusLink::connect_listening() {
        Ok(bus_link) => bus_link,
        Err(error) => {
            eprintln!("{LOG_PREFIX} cannot reach the session bus: {error}");
            return ExitCode::from(NAME_NOT_OWNED_EXIT_CODE);
        }
    };
    match bus_link.request_name(RESOURCE_PULSE_BUS_NAME) {
        Ok(NameOutcome::Owned) => {}
        Ok(NameOutcome::HeldByAnother) => {
            eprintln!("{LOG_PREFIX} {RESOURCE_PULSE_BUS_NAME} is held by another copy; exiting");
            return ExitCode::from(NAME_NOT_OWNED_EXIT_CODE);
        }
        Err(error) => {
            eprintln!("{LOG_PREFIX} cannot ask for {RESOURCE_PULSE_BUS_NAME}: {error}");
            return ExitCode::from(NAME_NOT_OWNED_EXIT_CODE);
        }
    }
    run_service_loop(&mut bus_link, tick_interval);
    ExitCode::SUCCESS
}

/// Ticks and answers until the bus goes away. A tick that is due runs before any call waiting is
/// answered, so a stream of calls cannot hold the Samples back. Everything is sent from this one
/// thread, so a state reply carrying N leaves after Sample N and before Sample N+1.
fn run_service_loop(bus_link: &mut BusLink, tick_interval: Duration) {
    let mut service = PlaceholderService::default();
    let started_at = Instant::now();
    let mut next_tick_at = next_tick_after(started_at, tick_interval, started_at);
    loop {
        let now = Instant::now();
        if now >= next_tick_at {
            service.sequence = service.sequence.saturating_add(1);
            if let Err(error) =
                bus_link.emit_string_signal(SAMPLE_SIGNAL_NAME, &service.sample_text())
            {
                eprintln!("{LOG_PREFIX} cannot emit {SAMPLE_SIGNAL_NAME}: {error}");
            }
            next_tick_at = next_tick_after(next_tick_at, tick_interval, now);
            continue;
        }
        match bus_link.next_event(next_tick_at.saturating_duration_since(now)) {
            Ok(None) => {}
            Ok(Some(BusEvent::Call(call))) => answer_call(bus_link, &call, &service),
            Ok(Some(BusEvent::NameVanished(_))) => {
                service.vanished_caller_count = service.vanished_caller_count.saturating_add(1);
            }
            Ok(Some(BusEvent::Disconnected)) => return,
            Err(error) => eprintln!("{LOG_PREFIX} bus: {error}"),
        }
    }
}

/// The first tick time after `now` on the grid of `previous_tick_at` plus whole intervals, so
/// ticks do not drift and a missed one is skipped rather than replayed. `interval` is never zero
/// (`parse_tick_interval` refuses it), so the walk ends.
fn next_tick_after(previous_tick_at: Instant, interval: Duration, now: Instant) -> Instant {
    let mut candidate = previous_tick_at;
    while candidate <= now {
        match candidate.checked_add(interval) {
            Some(later) => candidate = later,
            // Past the end of the clock's range, nothing later exists: tick now.
            None => return now,
        }
    }
    candidate
}

/// Answers one call, logging a reply that could not be sent.
fn answer_call(bus_link: &BusLink, call: &IncomingCall, service: &PlaceholderService) {
    if let Err(error) = route_call(bus_link, call, service) {
        eprintln!(
            "{LOG_PREFIX} cannot answer {} from {}: {error}",
            call.member, call.sender
        );
    }
}

/// Picks the answer to a call: the three methods of the interface and `Introspect` on the object,
/// the standard "unknown method" error for anything else. A call may leave its interface out.
fn route_call(
    bus_link: &BusLink,
    call: &IncomingCall,
    service: &PlaceholderService,
) -> Result<(), BusError> {
    let is_on_object = call.object_path == RESOURCE_PULSE_OBJECT_PATH;
    let called_interface = call.interface.as_deref();
    let is_interface_method = is_on_object
        && called_interface.is_none_or(|interface| interface == RESOURCE_PULSE_INTERFACE_NAME);
    let is_introspection = is_on_object
        && call.member == INTROSPECT_METHOD_NAME
        && called_interface.is_none_or(|interface| interface == INTROSPECTABLE_INTERFACE_NAME);
    match call.member.as_str() {
        GET_STATE_METHOD_NAME if is_interface_method => {
            bus_link.reply_with_string(call, &service.state_text())
        }
        WATCH_DETAIL_METHOD_NAME if is_interface_method => {
            // Followed before the reply, so the follow is in place by the time the caller hears
            // it has a watch. A follow that fails is logged; the call is answered all the same.
            if let Err(error) = bus_link.follow_name(&call.sender) {
                eprintln!("{LOG_PREFIX} cannot follow {}: {error}", call.sender);
            }
            bus_link.reply_empty(call)
        }
        UNWATCH_DETAIL_METHOD_NAME if is_interface_method => bus_link.reply_empty(call),
        _ if is_introspection => bus_link.reply_with_string(call, &introspection_xml()),
        _ => bus_link.reply_with_error(call, UNKNOWN_METHOD_ERROR_NAME, &unknown_method_text(call)),
    }
}

/// The error text for a call to a method the object does not have.
fn unknown_method_text(call: &IncomingCall) -> String {
    let interface_text = call.interface.as_deref().unwrap_or("(none)");
    format!(
        "No such method \"{}\" on interface \"{interface_text}\" at object path \"{}\"",
        call.member, call.object_path
    )
}

/// What `Introspect` returns: the interface `lib/protocol.js` describes as
/// `RESOURCE_PULSE_INTERFACE_XML`, and the standard interface that answers `Introspect`.
fn introspection_xml() -> String {
    format!(
        r#"<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="{INTROSPECTABLE_INTERFACE_NAME}">
    <method name="{INTROSPECT_METHOD_NAME}">
      <arg name="xml_data" type="s" direction="out"/>
    </method>
  </interface>
  <interface name="{RESOURCE_PULSE_INTERFACE_NAME}">
    <method name="{GET_STATE_METHOD_NAME}">
      <arg name="state" type="s" direction="out"/>
    </method>
    <method name="{WATCH_DETAIL_METHOD_NAME}"/>
    <method name="{UNWATCH_DETAIL_METHOD_NAME}"/>
    <signal name="{SAMPLE_SIGNAL_NAME}">
      <arg name="sample" type="s"/>
    </signal>
  </interface>
</node>
"#
    )
}
