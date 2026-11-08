import {PRESSURE_BAND_THRESHOLDS_PERCENT} from './constants.js';

/**
 * Maps PSI some avg10 to a meter band.
 *
 * @param {number|null} avg10Percent - Stall percentage, or null when unavailable.
 * @returns {0|1|2|3|null} Band index (0 is calm), or null for no data.
 */
export function pressureBand(avg10Percent) {
    if (avg10Percent === null || avg10Percent === undefined || Number.isNaN(avg10Percent))
        return null;
    return PRESSURE_BAND_THRESHOLDS_PERCENT.filter(threshold => avg10Percent >= threshold).length;
}
