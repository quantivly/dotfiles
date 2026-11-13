//! The program's link to the session bus, on `zbus`'s message-level API.
//!
//! Four rules shape it; each has a row in `gnome-shell/tests/sampler-program-dbus.test.js`, and
//! `tests/bus_link.rs` pins the first, the second and the fourth's exception deterministically.
//!
//! - **It listens before it is named.** `zbus` discards a message that arrives while no stream is
//!   listening, and a client calls `GetState` the instant the name has an owner. So
//!   [`BusLink::connect_listening`] connects with no name and opens the stream of incoming
//!   messages, and only [`BusLink::request_name`], called after it, asks for the name.
//! - **The name is asked for with "do not queue" only.** `zbus`'s default adds "replace the
//!   existing owner" and "allow replacement", with which a second copy would take the name from
//!   the first.
//! - **One thread sends every message.** No interface is registered with `zbus`'s object server,
//!   which would answer calls on a task of its own. Every reply and signal goes out from the thread
//!   that owns the `BusLink`, each send awaited before the next, and `zbus` writes a send on the
//!   caller's own task under the socket's write lock: the order of the calls is the order on the
//!   wire. A second thread only receives: it moves each incoming message into a channel that
//!   [`BusLink::next_event`] waits on, and it never sends.
//! - **Every call is answered.** With no object server nothing answers for the program, so each
//!   call reaches it as [`BusEvent::Call`], whatever its path, interface or member.

use std::cell::RefCell;
use std::collections::{HashSet, VecDeque};
use std::fmt;
use std::future::poll_fn;
use std::pin::pin;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use futures_core::Stream;
use zbus::fdo::{RequestNameFlags, RequestNameReply};
use zbus::message::{Flags, Type as MessageType};
use zbus::{Connection, MatchRule, Message, MessageStream};

use crate::constants::{RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH};

/// The standard error for a call to a method the object does not have.
pub const UNKNOWN_METHOD_ERROR_NAME: &str = "org.freedesktop.DBus.Error.UnknownMethod";
/// The standard interface every object answers `Introspect` on.
pub const INTROSPECTABLE_INTERFACE_NAME: &str = "org.freedesktop.DBus.Introspectable";
/// The one method of [`INTROSPECTABLE_INTERFACE_NAME`].
pub const INTROSPECT_METHOD_NAME: &str = "Introspect";

/// The bus daemon's well-known name, which is also the sender of its signals.
const BUS_DAEMON_NAME: &str = "org.freedesktop.DBus";
/// The bus daemon's object path.
const BUS_DAEMON_OBJECT_PATH: &str = "/org/freedesktop/DBus";
/// The bus daemon's interface.
const BUS_DAEMON_INTERFACE_NAME: &str = "org.freedesktop.DBus";
/// The bus daemon's signal for a name changing owner: (name, old owner, new owner), the new owner
/// empty once the name has none.
const NAME_OWNER_CHANGED_SIGNAL_NAME: &str = "NameOwnerChanged";
/// The bus daemon's method that starts routing the signals a match rule describes to the caller.
const ADD_MATCH_METHOD_NAME: &str = "AddMatch";
/// The bus daemon's method that stops routing them.
const REMOVE_MATCH_METHOD_NAME: &str = "RemoveMatch";
/// The bus daemon's method that says whether a name has an owner.
const NAME_HAS_OWNER_METHOD_NAME: &str = "NameHasOwner";
/// The name of the thread that receives, as `top -H` shows it (Linux keeps 15 bytes of it).
const RECEIVING_THREAD_NAME: &str = "rp-bus-receiver";

/// What [`BusLink::next_event`] hands the program.
#[derive(Debug)]
pub enum BusEvent {
    /// A method call, to be answered with one of the `reply_*` methods.
    Call(IncomingCall),
    /// A unique name the program followed has left the bus. It is followed no more.
    NameVanished(String),
    /// The connection to the bus is gone, and nothing more will arrive. Carries `zbus`'s error as
    /// text when the stream ended on a read error, and nothing when it simply ended.
    Disconnected(Option<String>),
}

/// A method call received from the bus.
#[derive(Debug)]
pub struct IncomingCall {
    /// The caller's unique name.
    pub sender: String,
    /// The method's name.
    pub member: String,
    /// The interface the call names; D-Bus lets a call leave it out.
    pub interface: Option<String>,
    /// The object path the call is addressed to.
    pub object_path: String,
    /// The call itself, which its reply is addressed by.
    message: Message,
}

impl IncomingCall {
    /// Whether the caller wants a reply: a call flagged "no reply expected" gets none.
    pub fn expects_reply(&self) -> bool {
        !self
            .message
            .primary_header()
            .flags()
            .contains(Flags::NO_REPLY_EXPECTED)
    }
}

/// How a request for the bus name ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameOutcome {
    /// The program owns the name.
    Owned,
    /// Another connection owns it, and the program was not queued for it.
    HeldByAnother,
}

/// A failure on the bus link.
#[derive(Debug)]
pub enum BusError {
    /// Connecting, a call to the bus daemon, or a send failed in `zbus`.
    Bus(zbus::Error),
    /// The thread that receives could not be started.
    ReceivingThread(std::io::Error),
}

impl fmt::Display for BusError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BusError::Bus(error) => write!(formatter, "D-Bus: {error}"),
            BusError::ReceivingThread(error) => {
                write!(formatter, "cannot start the receiving thread: {error}")
            }
        }
    }
}

impl std::error::Error for BusError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            BusError::Bus(error) => Some(error),
            BusError::ReceivingThread(error) => Some(error),
        }
    }
}

impl From<zbus::Error> for BusError {
    fn from(error: zbus::Error) -> Self {
        BusError::Bus(error)
    }
}

/// What the receiving thread passes on: only what [`BusLink::next_event`] can act on.
enum IncomingMessage {
    Call(IncomingCall),
    /// The bus daemon says this name has no owner any more.
    NameLeftBus(String),
    /// The stream of incoming messages has ended: the connection is gone. Carries `zbus`'s error
    /// as text when the stream ended on a read error, and nothing when it simply ended.
    StreamEnded(Option<String>),
}

/// The connection, the channel the receiving thread fills, and the names being followed.
pub struct BusLink {
    connection: Connection,
    incoming_messages: Receiver<IncomingMessage>,
    /// Unique names whose departure is reported as [`BusEvent::NameVanished`].
    followed_names: RefCell<HashSet<String>>,
    /// Events found outside [`BusLink::next_event`], which it hands out first.
    pending_events: RefCell<VecDeque<BusEvent>>,
}

impl BusLink {
    /// Connects to the session bus with NO name and opens the stream of incoming messages.
    pub fn connect_listening() -> Result<BusLink, BusError> {
        let connection = zbus::block_on(zbus::connection::Builder::session().build())?;
        // Opened before the name is asked for, so that no call addressed to the name can arrive
        // while nothing is listening.
        let incoming_stream = MessageStream::from(&connection);
        let (message_sender, incoming_messages) = mpsc::channel();
        thread::Builder::new()
            .name(RECEIVING_THREAD_NAME.to_owned())
            .spawn(move || forward_incoming_messages(incoming_stream, message_sender))
            .map_err(BusError::ReceivingThread)?;
        Ok(BusLink {
            connection,
            incoming_messages,
            followed_names: RefCell::default(),
            pending_events: RefCell::default(),
        })
    }

    /// The link's unique name on the bus, which a call can be addressed to before the program
    /// owns any other. The bus assigns it in its reply to `Hello`, inside `build()`, so a bus
    /// connection always has one; the empty string would mean a peer-to-peer connection, which a
    /// `BusLink` never makes.
    pub fn unique_name(&self) -> &str {
        self.connection
            .unique_name()
            .map_or("", |unique_name| unique_name.as_str())
    }

    /// Asks for the name with DO_NOT_QUEUE only.
    pub fn request_name(&self, name: &str) -> Result<NameOutcome, BusError> {
        let request = self
            .connection
            .request_name_with_flags(name, RequestNameFlags::DO_NOT_QUEUE);
        match zbus::block_on(request) {
            Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner) => {
                Ok(NameOutcome::Owned)
            }
            // `zbus` reports the bus's "exists" as `NameTaken`. "In queue" cannot come back for a
            // request that said not to queue; were it to, another connection still owns the name.
            Ok(RequestNameReply::Exists | RequestNameReply::InQueue)
            | Err(zbus::Error::NameTaken) => Ok(NameOutcome::HeldByAnother),
            Err(error) => Err(error.into()),
        }
    }

    /// The next call or name loss, or None once `wait` has passed.
    pub fn next_event(&mut self, wait: Duration) -> Result<Option<BusEvent>, BusError> {
        if let Some(pending_event) = self.pending_events.get_mut().pop_front() {
            return Ok(Some(pending_event));
        }
        // A wait too long for the clock to represent is waited out in full on every turn instead.
        let deadline = Instant::now().checked_add(wait);
        loop {
            let remaining_wait = deadline.map_or(wait, |deadline| {
                deadline.saturating_duration_since(Instant::now())
            });
            let incoming_message = match self.incoming_messages.recv_timeout(remaining_wait) {
                Ok(incoming_message) => incoming_message,
                Err(RecvTimeoutError::Timeout) => return Ok(None),
                // The receiving thread ends only once the stream has: the connection is gone.
                Err(RecvTimeoutError::Disconnected) => {
                    return Ok(Some(BusEvent::Disconnected(None)))
                }
            };
            match incoming_message {
                IncomingMessage::Call(call) => return Ok(Some(BusEvent::Call(call))),
                IncomingMessage::StreamEnded(reason) => {
                    return Ok(Some(BusEvent::Disconnected(reason)))
                }
                IncomingMessage::NameLeftBus(name) => {
                    if self.followed_names.get_mut().contains(&name) {
                        self.stop_following_departed(&name)?;
                        return Ok(self.pending_events.get_mut().pop_front());
                    }
                    // A name not followed, or one already reported: wait on.
                }
            }
        }
    }

    /// Replies to a call with one string.
    pub fn reply_with_string(&self, call: &IncomingCall, text: &str) -> Result<(), BusError> {
        if call.expects_reply() {
            zbus::block_on(self.connection.reply(&call.message.header(), &text))?;
        }
        Ok(())
    }

    /// Replies to a call with nothing.
    pub fn reply_empty(&self, call: &IncomingCall) -> Result<(), BusError> {
        if call.expects_reply() {
            zbus::block_on(self.connection.reply(&call.message.header(), &()))?;
        }
        Ok(())
    }

    /// Replies to a call with a D-Bus error and its message.
    pub fn reply_with_error(
        &self,
        call: &IncomingCall,
        error_name: &str,
        message: &str,
    ) -> Result<(), BusError> {
        if call.expects_reply() {
            let header = call.message.header();
            zbus::block_on(self.connection.reply_error(&header, error_name, &message))?;
        }
        Ok(())
    }

    /// Emits a signal of the program's interface, from its object, with one string.
    pub fn emit_string_signal(&self, signal_name: &str, text: &str) -> Result<(), BusError> {
        zbus::block_on(self.connection.emit_signal(
            None::<&str>,
            RESOURCE_PULSE_OBJECT_PATH,
            RESOURCE_PULSE_INTERFACE_NAME,
            signal_name,
            &text,
        ))?;
        Ok(())
    }

    /// From now on, the caller's disappearance from the bus arrives as BusEvent::NameVanished.
    pub fn follow_name(&self, unique_name: &str) -> Result<(), BusError> {
        if self.followed_names.borrow().contains(unique_name) {
            return Ok(());
        }
        self.call_bus_daemon(ADD_MATCH_METHOD_NAME, &name_left_bus_rule(unique_name)?)?;
        self.followed_names
            .borrow_mut()
            .insert(unique_name.to_owned());
        // A caller that left before the match was in place sent no signal the program will see,
        // so the bus is asked as well. If it leaves between the two, both report it, and
        // `followed_names` lets only the first through.
        let has_owner = self
            .call_bus_daemon(NAME_HAS_OWNER_METHOD_NAME, unique_name)?
            .body()
            .deserialize::<bool>()?;
        if !has_owner {
            self.stop_following_departed(unique_name)?;
        }
        Ok(())
    }

    /// Stops following a name; its departure is no longer reported.
    pub fn unfollow_name(&self, unique_name: &str) -> Result<(), BusError> {
        if !self.followed_names.borrow_mut().remove(unique_name) {
            return Ok(());
        }
        self.call_bus_daemon(REMOVE_MATCH_METHOD_NAME, &name_left_bus_rule(unique_name)?)?;
        Ok(())
    }

    /// Ends the following of a name that has left the bus: queues its NameVanished, then removes
    /// its match rule from the bus. The event is queued first, so that a failure to remove the
    /// rule, which is returned, does not lose it.
    fn stop_following_departed(&self, unique_name: &str) -> Result<(), BusError> {
        self.followed_names.borrow_mut().remove(unique_name);
        self.pending_events
            .borrow_mut()
            .push_back(BusEvent::NameVanished(unique_name.to_owned()));
        self.call_bus_daemon(REMOVE_MATCH_METHOD_NAME, &name_left_bus_rule(unique_name)?)?;
        Ok(())
    }

    /// Calls a method of the bus daemon with one string and waits for its reply, on this thread.
    fn call_bus_daemon(&self, method_name: &str, argument: &str) -> Result<Message, BusError> {
        let reply = zbus::block_on(self.connection.call_method(
            Some(BUS_DAEMON_NAME),
            BUS_DAEMON_OBJECT_PATH,
            Some(BUS_DAEMON_INTERFACE_NAME),
            method_name,
            &argument,
        ))?;
        Ok(reply)
    }
}

/// The match rule for the bus daemon's signal that `unique_name` changed owner.
fn name_left_bus_rule(unique_name: &str) -> Result<String, BusError> {
    let rule = MatchRule::builder()
        .msg_type(MessageType::Signal)
        .sender(BUS_DAEMON_NAME)
        .interface(BUS_DAEMON_INTERFACE_NAME)
        .member(NAME_OWNER_CHANGED_SIGNAL_NAME)
        .arg(0, unique_name)
        .build()?;
    Ok(rule.to_string())
}

/// The receiving thread: moves each message the program acts on from the stream into the
/// channel, and says when the stream ends. It never sends anything on the bus.
fn forward_incoming_messages(
    incoming_stream: MessageStream,
    message_sender: Sender<IncomingMessage>,
) {
    zbus::block_on(async move {
        let mut incoming_stream = pin!(incoming_stream);
        loop {
            let next_item = poll_fn(|context| incoming_stream.as_mut().poll_next(context)).await;
            let incoming_message = match next_item {
                Some(Ok(message)) => match pass_on(message) {
                    Some(incoming_message) => incoming_message,
                    None => continue,
                },
                // `zbus` ends the stream after its first read error, so an error is its end too.
                Some(Err(error)) => IncomingMessage::StreamEnded(Some(error.to_string())),
                None => IncomingMessage::StreamEnded(None),
            };
            let is_stream_end = matches!(incoming_message, IncomingMessage::StreamEnded(_));
            // A send fails only once the BusLink is gone, and then nobody is left to tell.
            if message_sender.send(incoming_message).is_err() || is_stream_end {
                return;
            }
        }
    });
}

/// What of a message the program acts on: every method call, and the bus daemon's word that a
/// name has left. Replies are not passed on: `zbus` hands them to the call that awaits them.
fn pass_on(message: Message) -> Option<IncomingMessage> {
    match message.message_type() {
        MessageType::MethodCall => Some(IncomingMessage::Call(incoming_call(message))),
        MessageType::Signal => name_left_bus(&message).map(IncomingMessage::NameLeftBus),
        MessageType::MethodReturn | MessageType::Error => None,
    }
}

/// A method call as the program sees it. A call always has a sender, a member and a path on a
/// bus; were one missing, it would read as empty, so the call is still handed over and answered.
fn incoming_call(message: Message) -> IncomingCall {
    let header = message.header();
    let sender = header.sender().map(ToString::to_string).unwrap_or_default();
    let member = header.member().map(ToString::to_string).unwrap_or_default();
    let interface = header.interface().map(ToString::to_string);
    let object_path = header.path().map(ToString::to_string).unwrap_or_default();
    IncomingCall {
        sender,
        member,
        interface,
        object_path,
        message,
    }
}

/// The name a `NameOwnerChanged` from the bus daemon says has no owner any more, if the message
/// is one. Only the daemon's own signal counts: its sender cannot be forged, as the bus sets it.
fn name_left_bus(message: &Message) -> Option<String> {
    let header = message.header();
    let is_from_bus_daemon = header
        .sender()
        .is_some_and(|sender| sender.as_str() == BUS_DAEMON_NAME);
    let is_owner_change = header
        .interface()
        .is_some_and(|interface| interface.as_str() == BUS_DAEMON_INTERFACE_NAME)
        && header
            .member()
            .is_some_and(|member| member.as_str() == NAME_OWNER_CHANGED_SIGNAL_NAME);
    if !(is_from_bus_daemon && is_owner_change) {
        return None;
    }
    // The daemon's signal always has this body; one that did not would be dropped as unreadable.
    let (name, _old_owner, new_owner) = message
        .body()
        .deserialize::<(String, String, String)>()
        .ok()?;
    new_owner.is_empty().then_some(name)
}
