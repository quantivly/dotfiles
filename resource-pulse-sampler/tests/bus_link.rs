//! The bus link's rules, proved deterministically on a PRIVATE bus, where the end-to-end rows of
//! `gnome-shell/tests/sampler-program-dbus.test.js` cannot pin them:
//!
//! - the stream of incoming messages is open when `connect_listening()` returns, and no name is
//!   asked for until `request_name()` (the end-to-end start-up row catches asking for the name
//!   before opening the stream about once in 150 starts, as the window is microseconds wide);
//! - the name is asked for with "do not queue" only: it neither takes a name whose owner allows
//!   replacement nor waits in the queue behind the owner (no exit status can show the queue);
//! - a call flagged "no reply expected" gets no reply;
//! - a followed caller that had already left is reported, once, and an unfollowed one is not;
//! - the program exits 0 when its bus goes away after it owned the name.
//!
//! Every test is `#[ignore]`d, so a plain `cargo test` never runs one, on any bus.
//! `scripts/test-resource-pulse-sampler.sh` runs each with `--ignored`, in a process and on a
//! private bus of its own under `dbus-run-session`, and each first refuses (fails) unless its bus
//! is that private one, by the test `gnome-shell/tests/privateBus.js` makes: a run that could not
//! prove its bus private fails, it never passes. The waits are bounds on a failure, never what a
//! pass relies on: each test orders the bus with round trips instead.

// Tests may unwrap, expect and panic: a failing test should say so loudly.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::env;
use std::fs;
use std::future::poll_fn;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use futures_core::Stream;
use resource_pulse_sampler::bus::{BusEvent, BusLink, IncomingCall, NameOutcome};
use resource_pulse_sampler::constants::{
    RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH,
};
use zbus::connection::Builder;
use zbus::fdo::{RequestNameFlags, RequestNameReply};
use zbus::message::Flags;
use zbus::{Connection, Message, MessageStream};

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
/// How long `next_event` may take to yield an event that is already on its way.
const QUEUED_EVENT_WAIT: Duration = Duration::from_secs(2);
/// How long a second report of the same departure is waited for, to be sure there is none.
const NO_SECOND_REPORT_WAIT: Duration = Duration::from_millis(500);
/// How long the bus may take to drop a name whose connection closed.
const NAME_RELEASED_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a started program may take to own the name, and to exit once its bus is gone.
const NAME_OWNED_TIMEOUT: Duration = Duration::from_secs(5);
const PROGRAM_EXIT_TIMEOUT: Duration = Duration::from_secs(5);
/// How often a condition with a time-out is looked at.
const POLL_INTERVAL: Duration = Duration::from_millis(20);
/// The methods the tests' own calls name; the link hands any call over, known or not.
const EARLY_CALL_METHOD_NAME: &str = "EarlyCall";
const SILENT_CALL_METHOD_NAME: &str = "SilentCall";
const ANSWERED_CALL_METHOD_NAME: &str = "AnsweredCall";
/// The call the unrequested-reply control answers without it ever being sent.
const CONTROL_CALL_METHOD_NAME: &str = "NeverSentCall";
const BUS_DAEMON_NAME: &str = "org.freedesktop.DBus";
const BUS_DAEMON_OBJECT_PATH: &str = "/org/freedesktop/DBus";
const BUS_DAEMON_INTERFACE_NAME: &str = "org.freedesktop.DBus";
/// The bus daemon's method that says whether a name has an owner.
const NAME_HAS_OWNER_METHOD_NAME: &str = "NameHasOwner";
/// The bus daemon's method that says which unique name owns a name.
const GET_NAME_OWNER_METHOD_NAME: &str = "GetNameOwner";
/// The bus daemon's method that lists a name's owner and the connections queued for it.
const LIST_QUEUED_OWNERS_METHOD_NAME: &str = "ListQueuedOwners";
/// The bus daemon's method that answers its ID: a round trip with no effect.
const GET_ID_METHOD_NAME: &str = "GetId";
/// The program the second bus is, the program under test, and the second bus's files.
const DBUS_DAEMON_PROGRAM: &str = "dbus-daemon";
const SAMPLER_PROGRAM_PATH: &str = env!("CARGO_BIN_EXE_resource-pulse-sampler");
const SECOND_BUS_DIRECTORY_PREFIX: &str = "second-bus-";
const SECOND_BUS_CONFIG_FILE_NAME: &str = "bus.conf";
/// Owner-only, as the table's private bus directory is.
const PRIVATE_DIRECTORY_MODE: u32 = 0o700;

/// Panics unless `address` is provably on the private bus: one path socket inside the directory
/// `RESOURCE_PULSE_TEST_BUS_DIR` names, with nothing that could lead it out, and never the live
/// bus's socket under `XDG_RUNTIME_DIR`. The twin of `requirePrivateBusAddress`.
fn require_private_address(address: &str) {
    let bus_directory = env::var(PRIVATE_BUS_DIRECTORY_VARIABLE).unwrap_or_default();
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
        "refusing to run: {address} is not a private bus inside \
         {PRIVATE_BUS_DIRECTORY_VARIABLE} ({bus_directory})"
    );
}

/// Panics unless the session bus, which every connection here goes to, is the private one.
fn require_private_bus_address() {
    let address = env::var(SESSION_BUS_ADDRESS_VARIABLE).unwrap_or_default();
    require_private_address(&address);
}

/// A second, plain connection to the (checked) private bus.
fn open_plain_connection() -> Connection {
    require_private_bus_address();
    zbus::block_on(Builder::session().build()).expect("a plain connection to the private bus")
}

/// A link on the (checked) private bus.
fn connect_link() -> BusLink {
    require_private_bus_address();
    BusLink::connect_listening().expect("connect_listening on the private bus")
}

/// A connection's unique name.
fn unique_name_of(connection: &Connection) -> String {
    connection
        .unique_name()
        .map(ToString::to_string)
        .expect("a bus connection has a unique name")
}

/// Calls a method of the bus daemon about `name` and waits for its reply.
fn ask_bus_daemon(connection: &Connection, method_name: &str, name: &str) -> Message {
    zbus::block_on(connection.call_method(
        Some(BUS_DAEMON_NAME),
        BUS_DAEMON_OBJECT_PATH,
        Some(BUS_DAEMON_INTERFACE_NAME),
        method_name,
        &name,
    ))
    .unwrap_or_else(|error| panic!("{method_name} failed: {error}"))
}

/// Whether `name` has an owner, as the bus daemon says.
fn name_has_owner(connection: &Connection, name: &str) -> bool {
    ask_bus_daemon(connection, NAME_HAS_OWNER_METHOD_NAME, name)
        .body()
        .deserialize::<bool>()
        .expect("NameHasOwner answers a boolean")
}

/// The unique name that owns `name`, as the bus daemon says.
fn name_owner(connection: &Connection, name: &str) -> String {
    ask_bus_daemon(connection, GET_NAME_OWNER_METHOD_NAME, name)
        .body()
        .deserialize::<String>()
        .expect("GetNameOwner answers a string")
}

/// The owner of `name` and the connections queued behind it, in queue order.
fn queued_owners(connection: &Connection, name: &str) -> Vec<String> {
    ask_bus_daemon(connection, LIST_QUEUED_OWNERS_METHOD_NAME, name)
        .body()
        .deserialize::<Vec<String>>()
        .expect("ListQueuedOwners answers a list of names")
}

/// A round trip to the bus daemon. When it returns, everything this connection sent before it
/// has been routed by the daemon.
fn round_trip_to_bus_daemon(connection: &Connection) {
    zbus::block_on(connection.call_method(
        Some(BUS_DAEMON_NAME),
        BUS_DAEMON_OBJECT_PATH,
        Some(BUS_DAEMON_INTERFACE_NAME),
        GET_ID_METHOD_NAME,
        &(),
    ))
    .expect("GetId answers");
}

/// Closes a connection, then waits until the bus has dropped its unique name.
fn close_and_wait_until_gone(connection: Connection, observer: &Connection) {
    let unique_name = unique_name_of(&connection);
    zbus::block_on(connection.close()).expect("the connection closes");
    let deadline = Instant::now() + NAME_RELEASED_TIMEOUT;
    while name_has_owner(observer, &unique_name) {
        assert!(
            Instant::now() < deadline,
            "{unique_name} is still on the bus {NAME_RELEASED_TIMEOUT:?} after it closed"
        );
        thread::sleep(POLL_INTERVAL);
    }
}

/// A method call of the program's interface to `destination`, flagged as given.
fn method_call_to(destination: &str, method_name: &str, flags: Flags) -> Message {
    Message::method_call(RESOURCE_PULSE_OBJECT_PATH, method_name)
        .destination(destination)
        .interface(RESOURCE_PULSE_INTERFACE_NAME)
        .with_flags(flags)
        .build(&())
        .unwrap_or_else(|error| panic!("{method_name} builds: {error}"))
}

/// Every message the connection receives from now on, through a channel a thread of its own
/// fills, so that the test can wait for one with a time-out.
fn forward_incoming_messages(connection: &Connection) -> Receiver<Message> {
    let incoming_stream = MessageStream::from(connection);
    let (message_sender, incoming_messages) = mpsc::channel();
    thread::spawn(move || {
        zbus::block_on(async move {
            let mut incoming_stream = pin!(incoming_stream);
            while let Some(Ok(message)) =
                poll_fn(|context| incoming_stream.as_mut().poll_next(context)).await
            {
                if message_sender.send(message).is_err() {
                    return;
                }
            }
        });
    });
    incoming_messages
}

/// Panics unless the bus passes a reply nobody asked for. A stock bus drops one, so on it the
/// no-reply test could not see a reply the link should not have sent, and would pass whatever the
/// link did; the table's private bus allows such replies. A helper sends the caller a reply to a
/// call it never made, and the caller must receive it.
fn require_unrequested_replies_pass(caller: &Connection, caller_messages: &Receiver<Message>) {
    let helper = open_plain_connection();
    let caller_unique_name = unique_name_of(caller);
    let never_sent_call = method_call_to(
        &caller_unique_name,
        CONTROL_CALL_METHOD_NAME,
        Flags::empty(),
    );
    let control_serial = never_sent_call.primary_header().serial_num();
    let unrequested_reply = Message::method_return(&never_sent_call.header())
        .destination(caller_unique_name)
        .build(&())
        .expect("the unrequested reply builds");
    zbus::block_on(helper.send(&unrequested_reply)).expect("the unrequested reply is sent");
    loop {
        let message = caller_messages.recv_timeout(QUEUED_EVENT_WAIT).expect(
            "could not run: this bus drops a reply nobody asked for, so it cannot show one",
        );
        if message.header().reply_serial() == Some(control_serial) {
            return;
        }
    }
}

/// One line for an event, to compare in assertions.
fn describe(event: Option<BusEvent>) -> String {
    match event {
        Some(BusEvent::Call(call)) => format!("Call({})", call.member),
        Some(BusEvent::NameVanished(name)) => format!("NameVanished({name})"),
        Some(BusEvent::Disconnected) => "Disconnected".to_owned(),
        None => "nothing".to_owned(),
    }
}

/// The next event, which must be a call of `method_name`.
fn expect_call(bus_link: &mut BusLink, method_name: &str) -> IncomingCall {
    match bus_link.next_event(QUEUED_EVENT_WAIT) {
        Ok(Some(BusEvent::Call(call))) if call.member == method_name => call,
        Ok(other) => panic!("expected a call of {method_name}, got {}", describe(other)),
        Err(error) => panic!("next_event failed: {error}"),
    }
}

/// A child process that is killed and reaped when the test lets go of it, however it ends.
struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A `dbus-daemon` of the test's own, in a directory inside the private bus's, so that its
/// address passes the same check. It is killed when the test lets go of it.
struct SecondBusDaemon {
    daemon: ChildGuard,
    address: String,
    directory: PathBuf,
    /// Held open, so the daemon never writes to a closed pipe.
    _address_pipe: BufReader<ChildStdout>,
}

impl SecondBusDaemon {
    /// Starts the daemon and reads the address it listens on.
    fn start() -> SecondBusDaemon {
        let bus_directory = env::var(PRIVATE_BUS_DIRECTORY_VARIABLE).expect("a private bus");
        let directory_name = format!("{SECOND_BUS_DIRECTORY_PREFIX}{}", std::process::id());
        let directory = Path::new(&bus_directory).join(directory_name);
        fs::create_dir(&directory).expect("the second bus's directory is created");
        fs::set_permissions(
            &directory,
            fs::Permissions::from_mode(PRIVATE_DIRECTORY_MODE),
        )
        .expect("the second bus's directory is made owner-only");
        let config_path = directory.join(SECOND_BUS_CONFIG_FILE_NAME);
        fs::write(&config_path, second_bus_config(&directory)).expect("the config is written");
        let config_argument = format!("--config-file={}", config_path.display());
        let mut daemon = ChildGuard(
            Command::new(DBUS_DAEMON_PROGRAM)
                .args([config_argument.as_str(), "--nofork", "--print-address=1"])
                .stdout(Stdio::piped())
                .spawn()
                .expect("dbus-daemon starts"),
        );
        let mut address_pipe = BufReader::new(daemon.0.stdout.take().expect("a stdout pipe"));
        let mut address_line = String::new();
        address_pipe
            .read_line(&mut address_line)
            .expect("dbus-daemon prints its address");
        let address = address_line.trim().to_owned();
        require_private_address(&address);
        SecondBusDaemon {
            daemon,
            address,
            directory,
            _address_pipe: address_pipe,
        }
    }

    /// Kills the daemon, as a logout ends the session bus under a running program.
    fn kill(&mut self) {
        self.daemon.0.kill().expect("the second bus is killed");
        self.daemon.0.wait().expect("the second bus is reaped");
    }
}

impl Drop for SecondBusDaemon {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

/// The second bus's configuration: the table's private bus, listening in `directory`.
fn second_bus_config(directory: &Path) -> String {
    format!(
        r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir={}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
        directory.display()
    )
}

// Every reason below is a literal, as `#[ignore]` requires; all give the same one.

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn connect_listening_delivers_a_call_sent_before_any_name() {
    require_private_bus_address();
    let mut bus_link = connect_link();
    let caller = open_plain_connection();
    let caller_unique_name = unique_name_of(&caller);
    let link_unique_name = bus_link.unique_name().to_owned();
    assert!(!link_unique_name.is_empty(), "the link has no unique name");
    // No name is requested: the call is addressed to the link's unique name, and sent without
    // waiting for a reply.
    let early_call = method_call_to(&link_unique_name, EARLY_CALL_METHOD_NAME, Flags::empty());
    zbus::block_on(caller.send(&early_call)).expect("the early call is sent");
    // The caller's round trip returns once the daemon has routed the early call to the link. The
    // link's own round trip (follow_name asks the daemon twice) then returns with a reply that sat
    // behind the early call on the link's socket: by then the socket reader has handled the call,
    // and dropped it if nothing was listening, whatever the load. next_event comes only after.
    round_trip_to_bus_daemon(&caller);
    bus_link
        .follow_name(&caller_unique_name)
        .expect("follow_name round-trips to the daemon");
    let call = expect_call(&mut bus_link, EARLY_CALL_METHOD_NAME);
    assert_eq!(call.sender, caller_unique_name);
    bus_link.reply_empty(&call).expect("the reply is sent");
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn connect_listening_requests_no_name() {
    require_private_bus_address();
    let bus_link = connect_link();
    let observer = open_plain_connection();
    let has_owner_after_connect = name_has_owner(&observer, RESOURCE_PULSE_BUS_NAME);
    let outcome = bus_link
        .request_name(RESOURCE_PULSE_BUS_NAME)
        .expect("request_name does not fail");
    let has_owner_after_request = name_has_owner(&observer, RESOURCE_PULSE_BUS_NAME);
    let owner_after_request = name_owner(&observer, RESOURCE_PULSE_BUS_NAME);
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

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn request_name_does_not_take_a_name_whose_owner_allows_replacement() {
    require_private_bus_address();
    let bus_link = connect_link();
    let helper = open_plain_connection();
    // An owner that allows replacement: only a request with REPLACE_EXISTING could take it over.
    let helper_reply = zbus::block_on(helper.request_name_with_flags(
        RESOURCE_PULSE_BUS_NAME,
        RequestNameFlags::ALLOW_REPLACEMENT | RequestNameFlags::DO_NOT_QUEUE,
    ))
    .expect("the helper asks for the name");
    assert_eq!(helper_reply, RequestNameReply::PrimaryOwner);
    let outcome = bus_link
        .request_name(RESOURCE_PULSE_BUS_NAME)
        .expect("request_name does not fail");
    assert_eq!(
        (outcome, name_owner(&helper, RESOURCE_PULSE_BUS_NAME)),
        (NameOutcome::HeldByAnother, unique_name_of(&helper))
    );
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn request_name_does_not_queue_behind_the_owner() {
    require_private_bus_address();
    let bus_link = connect_link();
    let helper = open_plain_connection();
    let helper_reply = zbus::block_on(
        helper.request_name_with_flags(RESOURCE_PULSE_BUS_NAME, RequestNameFlags::DO_NOT_QUEUE),
    )
    .expect("the helper asks for the name");
    assert_eq!(helper_reply, RequestNameReply::PrimaryOwner);
    let outcome = bus_link
        .request_name(RESOURCE_PULSE_BUS_NAME)
        .expect("request_name does not fail");
    // Asked while the link is still connected: a queued link would be listed after the helper.
    assert_eq!(
        (outcome, queued_owners(&helper, RESOURCE_PULSE_BUS_NAME)),
        (NameOutcome::HeldByAnother, vec![unique_name_of(&helper)])
    );
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn a_call_flagged_no_reply_expected_gets_no_reply() {
    require_private_bus_address();
    let mut bus_link = connect_link();
    let caller = open_plain_connection();
    let caller_messages = forward_incoming_messages(&caller);
    require_unrequested_replies_pass(&caller, &caller_messages);
    let link_unique_name = bus_link.unique_name().to_owned();
    let silent_call = method_call_to(
        &link_unique_name,
        SILENT_CALL_METHOD_NAME,
        Flags::NO_REPLY_EXPECTED,
    );
    let answered_call =
        method_call_to(&link_unique_name, ANSWERED_CALL_METHOD_NAME, Flags::empty());
    zbus::block_on(caller.send(&silent_call)).expect("the silent call is sent");
    zbus::block_on(caller.send(&answered_call)).expect("the answered call is sent");
    for method_name in [SILENT_CALL_METHOD_NAME, ANSWERED_CALL_METHOD_NAME] {
        let call = expect_call(&mut bus_link, method_name);
        bus_link
            .reply_empty(&call)
            .expect("reply_empty does not fail");
    }
    // The link answered in this order, so a reply to the silent call would arrive first.
    let silent_serial = silent_call.primary_header().serial_num();
    let answered_serial = answered_call.primary_header().serial_num();
    let mut serials_replied_to = Vec::new();
    loop {
        let message = caller_messages
            .recv_timeout(QUEUED_EVENT_WAIT)
            .expect("the answered call's reply arrives");
        let Some(reply_serial) = message.header().reply_serial() else {
            continue;
        };
        if reply_serial == silent_serial || reply_serial == answered_serial {
            serials_replied_to.push(reply_serial);
        }
        if reply_serial == answered_serial {
            break;
        }
    }
    assert_eq!(serials_replied_to, vec![answered_serial]);
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn follow_name_reports_a_caller_that_already_left_once() {
    require_private_bus_address();
    let mut bus_link = connect_link();
    let observer = open_plain_connection();
    let departed_caller = open_plain_connection();
    let departed_name = unique_name_of(&departed_caller);
    // Gone before it is followed: no NameOwnerChanged can reach the link's match for it.
    close_and_wait_until_gone(departed_caller, &observer);
    bus_link
        .follow_name(&departed_name)
        .expect("follow_name does not fail");
    let first_event = describe(bus_link.next_event(QUEUED_EVENT_WAIT).expect("next_event"));
    let second_event = describe(
        bus_link
            .next_event(NO_SECOND_REPORT_WAIT)
            .expect("next_event"),
    );
    assert_eq!(
        [first_event, second_event],
        [
            format!("NameVanished({departed_name})"),
            "nothing".to_owned()
        ]
    );
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn unfollow_name_stops_reporting_that_caller() {
    require_private_bus_address();
    let mut bus_link = connect_link();
    let observer = open_plain_connection();
    let unfollowed_caller = open_plain_connection();
    let followed_caller = open_plain_connection();
    let unfollowed_name = unique_name_of(&unfollowed_caller);
    let followed_name = unique_name_of(&followed_caller);
    for name in [&unfollowed_name, &followed_name] {
        bus_link
            .follow_name(name)
            .expect("follow_name does not fail");
    }
    bus_link
        .unfollow_name(&unfollowed_name)
        .expect("unfollow_name does not fail");
    // The unfollowed caller leaves first, and is gone before the other leaves: were it still
    // followed, its departure would be the first event.
    close_and_wait_until_gone(unfollowed_caller, &observer);
    close_and_wait_until_gone(followed_caller, &observer);
    let first_event = describe(bus_link.next_event(QUEUED_EVENT_WAIT).expect("next_event"));
    assert_eq!(first_event, format!("NameVanished({followed_name})"));
}

#[test]
#[ignore = "private bus only: scripts/test-resource-pulse-sampler.sh runs it"]
fn program_exits_0_when_its_bus_goes_away() {
    require_private_bus_address();
    let mut second_bus = SecondBusDaemon::start();
    let mut program = ChildGuard(
        Command::new(SAMPLER_PROGRAM_PATH)
            .env(SESSION_BUS_ADDRESS_VARIABLE, &second_bus.address)
            .spawn()
            .expect("the program starts"),
    );
    let observer = zbus::block_on(Builder::address(second_bus.address.as_str()).build())
        .expect("a connection to the second bus");
    let owned_deadline = Instant::now() + NAME_OWNED_TIMEOUT;
    while !name_has_owner(&observer, RESOURCE_PULSE_BUS_NAME) {
        let early_exit = program.0.try_wait().expect("the program can be waited for");
        assert!(
            early_exit.is_none(),
            "the program exited ({early_exit:?}) before it owned the name"
        );
        assert!(
            Instant::now() < owned_deadline,
            "the program never owned the name"
        );
        thread::sleep(POLL_INTERVAL);
    }
    // Only the test's own daemon is killed; the bus the other tests use is never touched.
    second_bus.kill();
    let exit_deadline = Instant::now() + PROGRAM_EXIT_TIMEOUT;
    let ending = loop {
        if let Some(status) = program.0.try_wait().expect("the program can be waited for") {
            break format!("{status}");
        }
        if Instant::now() >= exit_deadline {
            break format!("still running {PROGRAM_EXIT_TIMEOUT:?} after its bus went away");
        }
        thread::sleep(POLL_INTERVAL);
    };
    assert_eq!(ending, "exit status: 0");
}
