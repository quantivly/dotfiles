//! The pressure meter's bands, ported from `lib/pressure.js`.

use crate::constants::PRESSURE_BAND_THRESHOLDS_PERCENT;

/// Maps PSI `some avg10` to a meter band.
///
/// Parameters
/// ----------
/// avg10_percent
///     The stall percentage, or `None` when unavailable.
///
/// Returns
/// -------
/// The band index, 0 (calm) to 3, or `None` for no data. A NaN is no data; an infinity is a band
/// like any number.
pub fn pressure_band(avg10_percent: Option<f64>) -> Option<u8> {
    let avg10_percent = avg10_percent.filter(|value| !value.is_nan())?;
    // A threshold is a few tens, far below 2^53, so the conversion to f64 is exact.
    let bands_reached = PRESSURE_BAND_THRESHOLDS_PERCENT
        .iter()
        .filter(|&&threshold| avg10_percent >= threshold as f64)
        .count();
    u8::try_from(bands_reached).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// row: PSI bands at the edges
    #[test]
    fn psi_bands_at_the_edges() {
        let bands: Vec<Option<u8>> = [
            Some(9.99),
            Some(10.0),
            Some(24.99),
            Some(25.0),
            Some(49.99),
            Some(50.0),
            None,
        ]
        .into_iter()
        .map(pressure_band)
        .collect();
        assert_eq!(
            bands,
            vec![Some(0), Some(1), Some(1), Some(2), Some(2), Some(3), None]
        );
    }

    /// Where the gjs `pressureBand` is not a plain number: NaN is no data, the infinities are
    /// bands, a negative is calm. Expected values are `pressureBand` run under gjs.
    #[test]
    fn pressure_band_of_the_values_that_are_not_ordinary_numbers() {
        let inputs = [
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            0.0,
            -1.0,
            9.999_999_999_999_999,
            10.000_000_001,
            1e308,
        ];
        let bands: Vec<Option<u8>> = inputs
            .into_iter()
            .map(|value| pressure_band(Some(value)))
            .collect();
        assert_eq!(
            bands,
            vec![
                None,
                Some(3),
                Some(0),
                Some(0),
                Some(0),
                Some(0),
                Some(1),
                Some(3)
            ]
        );
    }
}
