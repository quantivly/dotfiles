//! The service's face without its bus: the part of `service/dbusService.js`
//! (`ResourcePulseDBusService`) that has no D-Bus in it. It numbers the publishes, remembers the
//! real time of the latest one, writes the text of `Sample` and of `GetState`, and counts detail
//! watches by sender (a bus's unique name), saying when "any watch held" changes: the sampler hears
//! only changes. Exporting the object, answering calls and following senders' names belong to the
//! program.

use crate::payload::{sample_payload, state_payload, PublishedState};
use crate::sampler::{Publish, Sampler};
use std::collections::HashMap;

/// What a watch call did, for the caller to act on: whether the sampler is to be told, and what the
/// sender held before and after, so a first watch and a last unwatch can be told from the others.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WatchChange {
    /// Whether "any watch is held" changed: the sampler is told (`setDetailWatched`) only then.
    pub any_watch_changed: bool,
    /// Whether the sender holds a watch after the call.
    pub sender_has_watches: bool,
    /// Whether the sender held a watch before the call.
    pub sender_had_watches: bool,
}

/// The service's bookkeeping, without a bus (`ResourcePulseDBusService`'s `_sequence`,
/// `_latestSampledAtUsec`, `_watchCountBySender` and `_serviceStartedAtUsec`).
#[derive(Debug)]
pub struct ServiceFace {
    service_started_at_usec: u64,
    /// The sequence of the latest Sample numbered; 0 before the first.
    sequence: u64,
    /// Real time of the latest publish; `None` before the first.
    latest_sampled_at_usec: Option<u64>,
    /// Watches held, by the sender's unique name; a sender holding none has no entry.
    watch_count_by_sender: HashMap<String, u64>,
}

impl ServiceFace {
    /// A face for a service that started at `service_started_at_usec` (real time, microseconds),
    /// with no publish and no watch.
    pub fn new(service_started_at_usec: u64) -> ServiceFace {
        ServiceFace {
            service_started_at_usec,
            sequence: 0,
            latest_sampled_at_usec: None,
            watch_count_by_sender: HashMap::new(),
        }
    }

    /// Numbers a publish from 1 and returns the Sample's JSON (`_emitSample`), recording
    /// `real_usec` as the real time of the latest publish. The sequence moves on even if sending the
    /// text then fails, so a client sees the gap.
    pub fn next_sample(&mut self, publish: &Publish, real_usec: u64) -> String {
        self.sequence = self.sequence.saturating_add(1);
        self.latest_sampled_at_usec = Some(real_usec);
        sample_payload(publish, self.sequence, real_usec)
    }

    /// `GetState`'s JSON (`_buildStatePayload`): the sampler's latest snapshot and both histories,
    /// the start time, the real time of the latest publish and the current sequence.
    pub fn state_text(&self, sampler: &Sampler) -> String {
        state_payload(&PublishedState {
            snapshot: sampler.latest_snapshot(),
            cpu_history: sampler.cpu_history(),
            memory_history: sampler.memory_history(),
            service_started_at_usec: self.service_started_at_usec,
            latest_sampled_at_usec: self.latest_sampled_at_usec,
            sequence: self.sequence,
        })
    }

    /// Counts one more watch for a sender (`_addWatch`).
    pub fn add_watch(&mut self, sender: &str) -> WatchChange {
        let state_before = self.watch_state_of(sender);
        let senders_watch_count = self
            .watch_count_by_sender
            .entry(sender.to_string())
            .or_insert(0);
        *senders_watch_count = senders_watch_count.saturating_add(1);
        self.change_since(sender, state_before)
    }

    /// Counts one watch fewer for a sender (`_removeWatch`). A sender holding none is left alone:
    /// no change, and not an error.
    pub fn remove_watch(&mut self, sender: &str) -> WatchChange {
        let state_before = self.watch_state_of(sender);
        match self.watch_count_by_sender.get_mut(sender) {
            Some(senders_watch_count) if *senders_watch_count > 1 => {
                *senders_watch_count = senders_watch_count.saturating_sub(1);
            }
            Some(_) => {
                self.watch_count_by_sender.remove(sender);
            }
            None => {}
        }
        self.change_since(sender, state_before)
    }

    /// Forgets every watch of a sender whose connection closed (`_onSenderVanished`).
    pub fn drop_sender(&mut self, sender: &str) -> WatchChange {
        let state_before = self.watch_state_of(sender);
        self.watch_count_by_sender.remove(sender);
        self.change_since(sender, state_before)
    }

    /// Detail watches held now, across every sender (`detailWatchCount`).
    pub fn detail_watch_count(&self) -> u64 {
        self.watch_count_by_sender
            .values()
            .fold(0, |total, senders_count| {
                total.saturating_add(*senders_count)
            })
    }

    /// What is held before a call: whether any watch is, and whether this sender holds one.
    fn watch_state_of(&self, sender: &str) -> WatchState {
        WatchState {
            is_any_watch_held: !self.watch_count_by_sender.is_empty(),
            does_sender_hold_watch: self.watch_count_by_sender.contains_key(sender),
        }
    }

    /// What a call changed, against what was held before it.
    fn change_since(&self, sender: &str, state_before: WatchState) -> WatchChange {
        let state_after = self.watch_state_of(sender);
        WatchChange {
            any_watch_changed: state_before.is_any_watch_held != state_after.is_any_watch_held,
            sender_has_watches: state_after.does_sender_hold_watch,
            sender_had_watches: state_before.does_sender_hold_watch,
        }
    }
}

/// What the watch counts say at one moment.
#[derive(Debug, Clone, Copy)]
struct WatchState {
    is_any_watch_held: bool,
    does_sender_hold_watch: bool,
}

#[cfg(test)]
mod tests;
