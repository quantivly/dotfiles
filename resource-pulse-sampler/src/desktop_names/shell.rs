//! The part of `g_shell_parse_argv` (`glib/gshell.c`: `tokenize_command_line`,
//! `g_shell_unquote`, `unquote_string_inplace`) that decides whether an `Exec` line is
//! accepted, and what its first word is. The whole line is tokenized and every word
//! unquoted, as GLib does, because one bad quote anywhere refuses the line.

/// What the tokenizer is inside of: GLib's `current_quote`.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Inside {
    Nothing,
    SingleQuote,
    DoubleQuote,
    Backslash,
    Comment,
}

/// The first word of `command_line` as the shell would give it, with its quotes and escapes
/// removed; `None` when `g_shell_parse_argv` would refuse the line (an unfinished quote or
/// escape, or no word at all).
pub(super) fn first_word(command_line: &str) -> Option<String> {
    let tokens = tokenize(command_line.as_bytes())?;
    let mut words = Vec::with_capacity(tokens.len());
    for token in &tokens {
        words.push(unquote(token)?);
    }
    let first = words.into_iter().next()?;
    String::from_utf8(first).ok()
}

/// `tokenize_command_line`: splits at unquoted blanks and newlines, keeping each word's quotes
/// and escapes in it; `None` for an unfinished quote or escape, or no word.
fn tokenize(line: &[u8]) -> Option<Vec<Vec<u8>>> {
    let mut inside = Inside::Nothing;
    let mut preceded_by_odd_backslashes = false;
    let mut current_token: Option<Vec<u8>> = None;
    let mut tokens: Vec<Vec<u8>> = Vec::new();
    let mut position = 0;
    while let Some(&character) = line.get(position) {
        match inside {
            Inside::Backslash => {
                if character != b'\n' {
                    let token = current_token.get_or_insert_with(Vec::new);
                    token.push(b'\\');
                    token.push(character);
                }
                inside = Inside::Nothing;
            }
            Inside::Comment => {
                // Everything up to the next newline is dropped; the newline is handled by the
                // next turn of the loop, as a plain character.
                while line.get(position).is_some_and(|&skipped| skipped != b'\n') {
                    position += 1;
                }
                inside = Inside::Nothing;
                if position >= line.len() {
                    break;
                }
            }
            Inside::SingleQuote | Inside::DoubleQuote => {
                let closing_quote = if inside == Inside::SingleQuote {
                    b'\''
                } else {
                    b'"'
                };
                let is_escaped_double_quote =
                    inside == Inside::DoubleQuote && preceded_by_odd_backslashes;
                if character == closing_quote && !is_escaped_double_quote {
                    inside = Inside::Nothing;
                }
                current_token.get_or_insert_with(Vec::new).push(character);
            }
            Inside::Nothing => {
                inside = step_outside_quotes(line, position, &mut current_token, &mut tokens);
            }
        }
        let current = line.get(position).copied();
        preceded_by_odd_backslashes = current == Some(b'\\') && !preceded_by_odd_backslashes;
        position += 1;
    }
    if let Some(token) = current_token.take() {
        tokens.push(token);
    }
    if inside != Inside::Nothing || tokens.is_empty() {
        return None;
    }
    Some(tokens)
}

/// The `current_quote == 0` branch of `tokenize_command_line`: one character outside any
/// quote; returns what the tokenizer is inside of afterwards.
fn step_outside_quotes(
    line: &[u8],
    position: usize,
    current_token: &mut Option<Vec<u8>>,
    tokens: &mut Vec<Vec<u8>>,
) -> Inside {
    let Some(&character) = line.get(position) else {
        return Inside::Nothing;
    };
    let mut delimit = |current_token: &mut Option<Vec<u8>>| {
        if let Some(token) = current_token.take() {
            tokens.push(token);
        }
    };
    match character {
        b'\n' => delimit(current_token),
        b' ' | b'\t' => {
            if current_token
                .as_ref()
                .is_some_and(|token| !token.is_empty())
            {
                delimit(current_token);
            }
        }
        b'\'' | b'"' => {
            current_token.get_or_insert_with(Vec::new).push(character);
            return if character == b'\'' {
                Inside::SingleQuote
            } else {
                Inside::DoubleQuote
            };
        }
        b'\\' => return Inside::Backslash,
        b'#' => {
            let starts_a_word = position
                .checked_sub(1)
                .and_then(|previous| line.get(previous))
                .is_none_or(|&previous| matches!(previous, b' ' | b'\n'));
            if starts_a_word {
                return Inside::Comment;
            }
            current_token.get_or_insert_with(Vec::new).push(character);
        }
        _ => current_token.get_or_insert_with(Vec::new).push(character),
    }
    Inside::Nothing
}

/// `g_shell_unquote`: removes the quotes and escapes of one word; `None` for an unmatched quote.
fn unquote(word: &[u8]) -> Option<Vec<u8>> {
    let mut unquoted = Vec::with_capacity(word.len());
    let mut position = 0;
    while let Some(&character) = word.get(position) {
        match character {
            b'"' | b'\'' => position = unquote_quoted_part(word, position, &mut unquoted)?,
            b'\\' => {
                position += 1;
                if let Some(&escaped) = word.get(position) {
                    // A backslash before a newline outside quotes removes both.
                    if escaped != b'\n' {
                        unquoted.push(escaped);
                    }
                    position += 1;
                }
            }
            _ => {
                unquoted.push(character);
                position += 1;
            }
        }
    }
    Some(unquoted)
}

/// `unquote_string_inplace`: appends the quoted part of `word` that starts at the quote mark
/// at `start` and returns the position after its closing quote; `None` when it has none.
fn unquote_quoted_part(word: &[u8], start: usize, unquoted: &mut Vec<u8>) -> Option<usize> {
    let quote_character = *word.get(start)?;
    let mut position = start + 1;
    while let Some(&character) = word.get(position) {
        if character == quote_character {
            return Some(position + 1);
        }
        position += 1;
        if quote_character == b'"' && character == b'\\' {
            // Inside double quotes a backslash escapes only these five characters; before any
            // other it is itself kept, and the next character is read on its own.
            match word.get(position) {
                Some(&escaped @ (b'"' | b'\\' | b'`' | b'$' | b'\n')) => {
                    unquoted.push(escaped);
                    position += 1;
                }
                _ => unquoted.push(b'\\'),
            }
        } else {
            unquoted.push(character);
        }
    }
    None
}
