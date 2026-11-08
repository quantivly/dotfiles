/** Fixed-capacity history of samples; null marks a gap (no data). */
export class RingBuffer {
    /**
     * @param {number} capacity - Maximum samples kept; must be a positive integer.
     */
    constructor(capacity) {
        if (!Number.isInteger(capacity) || capacity <= 0)
            throw new Error(`RingBuffer capacity must be a positive integer, got ${capacity}`);
        this._capacity = capacity;
        this._items = [];
    }

    /**
     * Appends a sample, dropping the oldest when full.
     *
     * @param {number|null} value - Sample, or null for a gap.
     * @returns {void}
     */
    push(value) {
        this._items.push(value);
        if (this._items.length > this._capacity)
            this._items.shift();
    }

    /**
     * @returns {Array<number|null>} All samples, oldest first (a copy).
     */
    values() {
        return [...this._items];
    }

    /**
     * @param {number} count - How many of the newest samples to return.
     * @returns {Array<number|null>} The newest samples, oldest first.
     */
    lastValues(count) {
        return count <= 0 ? [] : this._items.slice(-count);
    }

    /**
     * Forgets every sample.
     *
     * @returns {void}
     */
    clear() {
        this._items = [];
    }
}
