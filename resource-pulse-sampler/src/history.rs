//! The fixed-capacity sample history, ported from `lib/history.js`.

use std::collections::VecDeque;

/// Fixed-capacity history of samples; `None` marks a gap (no data).
#[derive(Debug, Clone, PartialEq)]
pub struct RingBuffer {
    capacity: usize,
    samples: VecDeque<Option<f64>>,
}

impl RingBuffer {
    /// An empty buffer keeping at most `capacity` samples; `None` for a capacity of zero (the
    /// gjs constructor throws for anything that is not a positive integer).
    pub fn new(capacity: usize) -> Option<Self> {
        (capacity > 0).then(|| Self {
            capacity,
            samples: VecDeque::new(),
        })
    }

    /// Appends a sample, dropping the oldest when full.
    pub fn push(&mut self, value: Option<f64>) {
        self.samples.push_back(value);
        if self.samples.len() > self.capacity {
            self.samples.pop_front();
        }
    }

    /// All samples, oldest first (a copy).
    pub fn values(&self) -> Vec<Option<f64>> {
        self.samples.iter().copied().collect()
    }

    /// The newest `count` samples, oldest first: all of them when `count` is more than are kept,
    /// none when it is 0.
    pub fn last_values(&self, count: usize) -> Vec<Option<f64>> {
        let skipped_count = self.samples.len().saturating_sub(count);
        self.samples.iter().skip(skipped_count).copied().collect()
    }

    /// Forgets every sample.
    pub fn clear(&mut self) {
        self.samples.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A buffer of `capacity` that must exist.
    fn buffer_of(capacity: usize) -> RingBuffer {
        RingBuffer::new(capacity).unwrap()
    }

    /// row: ring buffer drops the oldest and keeps null gaps
    #[test]
    fn ring_buffer_drops_the_oldest_and_keeps_null_gaps() {
        let mut ring = buffer_of(3);
        for value in [Some(1.0), None, Some(3.0), Some(4.0)] {
            ring.push(value);
        }
        assert_eq!(ring.values(), vec![None, Some(3.0), Some(4.0)]);
    }

    /// row: ring buffer lastValues returns the newest, oldest first, and clear empties it
    #[test]
    fn ring_buffer_last_values_returns_the_newest_oldest_first_and_clear_empties_it() {
        let mut ring = buffer_of(5);
        for value in [1.0, 2.0, 3.0] {
            ring.push(Some(value));
        }
        let newest_two = ring.last_values(2);
        ring.clear();
        assert_eq!(newest_two, vec![Some(2.0), Some(3.0)]);
        assert_eq!(ring.values(), Vec::<Option<f64>>::new());
    }

    /// A capacity of zero is no buffer. gjs throws for 0, -1, 1.5 and NaN; a `usize` cannot be
    /// the other three.
    #[test]
    fn a_capacity_of_zero_is_no_buffer() {
        assert_eq!(RingBuffer::new(0), None);
    }

    /// `lastValues(0)` is empty, a count above the length is everything, a capacity of one keeps
    /// only the newest (a gap included). Expected values are `RingBuffer` run under gjs.
    #[test]
    fn last_values_at_the_edges_and_a_buffer_of_one() {
        let mut ring = buffer_of(3);
        ring.push(Some(1.0));
        ring.push(Some(2.0));
        assert_eq!(ring.last_values(0), Vec::<Option<f64>>::new());
        assert_eq!(ring.last_values(1), vec![Some(2.0)]);
        assert_eq!(ring.last_values(3), vec![Some(1.0), Some(2.0)]);
        assert_eq!(ring.last_values(99), vec![Some(1.0), Some(2.0)]);
        let mut single = buffer_of(1);
        for value in [Some(1.0), Some(2.0), None] {
            single.push(value);
        }
        assert_eq!(single.values(), vec![None]);
    }

    /// NaN and infinity are kept as pushed (gjs keeps them too), and `values` is a copy: pushing
    /// to it changes nothing, and a push after `clear` starts afresh.
    #[test]
    fn values_are_a_copy_and_non_finite_samples_are_kept() {
        let mut ring = buffer_of(2);
        for value in [f64::NAN, 1.0, f64::INFINITY] {
            ring.push(Some(value));
        }
        assert_eq!(ring.values(), vec![Some(1.0), Some(f64::INFINITY)]);
        let mut copy = ring.values();
        copy.push(Some(9.0));
        assert_eq!(ring.values(), vec![Some(1.0), Some(f64::INFINITY)]);
        ring.clear();
        ring.push(Some(7.0));
        assert_eq!(ring.values(), vec![Some(7.0)]);
    }
}
