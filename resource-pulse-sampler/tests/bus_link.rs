//! The bus link's start-up order, proved deterministically on a PRIVATE bus: the stream of
//! incoming messages is open when `connect_listening()` returns, and no name is asked for until
//! `request_name()`. The end-to-end row (`gnome-shell/tests/sampler-program-dbus.test.js`, 50
//! starts) catches asking for the name before opening the stream only about once in 150 starts,
//! as the window is microseconds wide; these two catch it every time.
//!
//! Both tests are `#[ignore]`d, so a plain `cargo test` never runs them, on any bus.
//! `scripts/test-resource-pulse-sampler.sh` runs them with `--ignored` under `dbus-run-session`,
//! and each first refuses (fails) unless the session bus is that private one, by the same test
//! `gnome-shell/tests/privateBus.js` makes: a run that could not prove its bus private fails, it
//! never passes.

// Tests may unwrap, expect and panic: a failing test should say so loudly.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::env;
use std::thread;
use std::time::Duration;

use resource_pulse_sampler::bus::{BusEvent, BusLink, NameOutcome};
use resource_pulse_sampler::constants::{
    RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH,
};
use zbus::connection::Builder;
use zbus::{Connection, Message};

/// Names the directory the private bus listens in; the state table sets it.
const PRIVATE_BUS_DIRECTORY_VARIABLE: &str = "RESOURCE_PULSE_TEST_BUS_DIR";
const SESSION_BUS_ADDRESS_VARIABLE: &str = "DBUS_SESSION_BUS_ADDRESS";
const RUNTIME_DIRECTORY_VARIABLE: &str = "XDG_RUNTIME_DIR";
const PATH_SOCKET_ADDRESS_PREFIX: &str = "unix:path=";
/// Where the live session bus listens, under XDG_RUNTIME_DIR.
const LIVE_SESSION_BUS_SOCKET_NAME: &str = "bus";
/// What may lead an address that starts inside the bus directory out of it: an address list, a
/// parent segment, and a percent escape (D-Bus decodes them, so %2e%2e is ..).
const ADDRESS_ESCAPE_MARKERS: [&str; 3] = [";", "/../", "%"];
/// Long enough for the socket reader to have handled a message already sent.
const SOCKET_READER_SETTLE_TIME: Duration = Duration::from_millis(200);
/// How long `next_event` may take to yield a call that is already queued.
const QUEUED_CALL_WAIT: Duration = Duration::from_secs(2);
/// The method the early call names; the link hands any call over, known or not.
const EARLY_CALL_METHOD_NAME: &str = "EarlyCall";
const BUS_DAEMON_NAME: &str = "org.freedesktop.DBus";
const BUS_DAEMON_OBJECT_PATH: &str = "/org/freedesktop/DBus";
const BUS_DAEMON_INTERFACE_NAME: &str = "org.freedesktop.DBus";
/// The bus daemon's method that says whether a name has an owner.
const NAME_HAS_OWNER_METHOD_NAME: &str = "NameHasOwner";
/// The bus daemon's method that says which unique name owns a name.
const GET_NAME_OWNER_METHOD_NAME: &str = "GetNameOwner";

/// Panics unless the session bus is provably the private one: one path socket inside the
/// directory `RESOURCE_PULSE_TEST_BUS_DIR` names, with nothing that could lead it out, and never
/// the live bus's socket under `XDG_RUNTIME_DIR`. The twin of `requirePrivateBusAddress`.
fn require_private_bus_address() {
    let bus_directory = env::var(PRIVATE_BUS_DIRECTORY_VARIABLE).unwrap_or_default();
    let address = env::var(SESSION_BUS_ADDRESS_VARIABLE).unwrap_or_default();
    let address_prefix_inside = format!("{PATH_SOCKET_ADDRESS_PREFIX}{bus_directory}/");
    let is_inside_bus_directory =
        !bus_directory.is_empty() && address.starts_with(&address_prefix_inside);
    let is_live_bus = env::var(RUNTIME_DIRECTORY_VARIABLE).is_ok_and(|runtime_directory| {
        let live_bus_address_prefix = format!(
            "{PATH_SOCKET_ADDRESS_PREFIX}{runtime_directory}/{LIVE_SESSION_BUS_SOCKET_NAME}"
        );
        address.starts_with(&live_bus_address_prefix)
    });
    let can_lead_elsewhere = ADDRESS_ESCAPE_MARKERS
        .iter()
        .any(|marker| address.contains(marker));
    assert!(
        is_inside_bus_directory && !is_live_bus && !can_lead_elsewhere,
        "refusing to run: {SESSION_BUS_ADDRESS_VARIABLE} ({address}) is not a private bus inside \
         {PRIVATE_BUS_DIRECTORY_VARIABLE} ({bus_directory})"
    );
}

/// A second, plain connection to the (checked) private bus.
fn open_plain_connection() -> Connection {
    require_private_bus_address();
    zbus::block_on(Builder::session().build()).expect("a plain connection to the private bus")
}

/// Asks the bus daemon a question about the program's bus name, with one string argument.
fn ask_bus_daemon(connection: &Connection, method_name: &str) -> Message {
    zbus::block_on(connection.call_method(
        Some(BUS_DAEMON_NAME),
        BUS_DAEMON_OBJECT_PATH,
        Some(BUS_DAEMON_INTERFACE_NAME),
        method_name,
        &RESOURCE_PULSE_BUS_NAME,
    ))
    .unwrap_or_else(|error| panic!("{method_name} failed: {error}"))
}

/// Whether the program's bus name has an owner, as the bus daemon says.
fn bus_name_has_owner(connection: &Connection) -> bool {
    ask_bus_daemon(connection, NAME_HAS_OWNER_METHOD_NAME)
        .body()
        .deserialize::<bool>()
        .expect("NameHasOwner answers a boolean")
}

// The reason is a literal, as `#[ignore]` requires; both tests give the same one.
#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn connect_listening_delivers_a_call_sent_before_any_name() {
    require_private_bus_address();
    let mut bus_link = BusLink::connect_listening().expect("connect_listening on the private bus");
    let caller = open_plain_connection();
    let link_unique_name = bus_link.unique_name().to_owned();
    assert!(!link_unique_name.is_empty(), "the link has no unique name");
    // No name is requested: the call is addressed to the link's unique name, and sent without
    // waiting for a reply, so it is in the link's socket before next_event is ever called.
    let early_call = Message::method_call(RESOURCE_PULSE_OBJECT_PATH, EARLY_CALL_METHOD_NAME)
        .destination(link_unique_name.as_str())
        .interface(RESOURCE_PULSE_INTERFACE_NAME)
        .build(&())
        .expect("the early call builds");
    zbus::block_on(caller.send(&early_call)).expect("the early call is sent");
    thread::sleep(SOCKET_READER_SETTLE_TIME);
    let event = bus_link
        .next_event(QUEUED_CALL_WAIT)
        .expect("next_event does not fail");
    let caller_unique_name = caller
        .unique_name()
        .map(ToString::to_string)
        .expect("the caller has a unique name");
    match event {
        Some(BusEvent::Call(call)) => {
            assert_eq!(
                (call.member.as_str(), call.sender.as_str()),
                (EARLY_CALL_METHOD_NAME, caller_unique_name.as_str())
            );
            bus_link.reply_empty(&call).expect("the reply is sent");
        }
        other => panic!("expected the early call, got {other:?}"),
    }
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn connect_listening_requests_no_name() {
    require_private_bus_address();
    let bus_link = BusLink::connect_listening().expect("connect_listening on the private bus");
    let observer = open_plain_connection();
    let has_owner_after_connect = bus_name_has_owner(&observer);
    let outcome = bus_link
        .request_name(RESOURCE_PULSE_BUS_NAME)
        .expect("request_name does not fail");
    let has_owner_after_request = bus_name_has_owner(&observer);
    let owner_after_request = ask_bus_daemon(&observer, GET_NAME_OWNER_METHOD_NAME)
        .body()
        .deserialize::<String>()
        .expect("GetNameOwner answers a string");
    assert_eq!(
        (
            has_owner_after_connect,
            outcome,
            has_owner_after_request,
            owner_after_request.as_str()
        ),
        (false, NameOutcome::Owned, true, bus_link.unique_name())
    );
}
