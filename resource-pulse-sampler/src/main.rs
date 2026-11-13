//! The sampler program. Until the later tasks wire the sampler, it does one
//! thing: `--print-constants` prints every constant for the gjs comparison
//! row (`gnome-shell/tests/sampler-constants.js`).

use std::process::ExitCode;

use resource_pulse_sampler::constants::constant_lines;

/// The one flag this program understands so far.
const PRINT_CONSTANTS_FLAG: &str = "--print-constants";
/// What the program says to stderr when it is called with anything else.
const USAGE_LINE: &str = "usage: resource-pulse-sampler --print-constants";
/// Exit status for a call the program does not understand.
const USAGE_EXIT_CODE: u8 = 2;

/// Prints the constants for `--print-constants`; anything else is a usage error.
fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.len() == 1 && arguments.first().map(String::as_str) == Some(PRINT_CONSTANTS_FLAG) {
        for line in constant_lines() {
            println!("{line}");
        }
        return ExitCode::SUCCESS;
    }
    eprintln!("{USAGE_LINE}");
    ExitCode::from(USAGE_EXIT_CODE)
}
