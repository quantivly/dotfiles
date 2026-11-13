//! JavaScript's string semantics where `lib/apps.js` depends on them. A JavaScript string is a
//! sequence of UTF-16 code units; a Rust `str` is UTF-8 and orders by code point. The two orders
//! differ for text outside the Basic Multilingual Plane, so every comparison the gjs original
//! makes with `<`, `>` or the default `sort()` goes through [`js_string_order`].

use std::cmp::Ordering;

/// Orders as JavaScript's default sort and its `<` do: by UTF-16 code unit.
pub fn js_string_order(left: &str, right: &str) -> Ordering {
    left.encode_utf16().cmp(right.encode_utf16())
}

/// `text.charAt(0).toUpperCase() + text.slice(1)`.
///
/// `charAt(0)` is the first UTF-16 code unit. Upper-casing a unit that is half of a surrogate pair
/// gives that unit back, so a first character outside the Basic Multilingual Plane is left as it
/// is, even when it has an upper case (U+10428 has U+10400); upper-casing a BMP character gives
/// what `toUpperCase` gives, which can be several characters (`ß` is `SS`).
pub fn capitalise_first_code_unit(text: &str) -> String {
    let mut characters = text.chars();
    let Some(first_character) = characters.next() else {
        return String::new();
    };
    let rest_of_text = characters.as_str();
    if first_character.len_utf16() > 1 {
        return text.to_string();
    }
    let upper_cased_first_character: String = first_character.to_uppercase().collect();
    format!("{upper_cased_first_character}{rest_of_text}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A character outside the Basic Multilingual Plane: UTF-16 D83D DE00.
    const GRINNING_FACE: &str = "\u{1F600}";
    /// A Private Use Area character inside it: UTF-16 E000.
    const PRIVATE_USE_E000: &str = "\u{E000}";
    /// Deseret small letter long I, U+10428: it has an upper case (U+10400) outside the BMP.
    const DESERET_SMALL_LONG_I: &str = "\u{10428}";

    /// Sorts `texts` with [`js_string_order`].
    fn sorted_by_js_order(texts: &[&str]) -> Vec<String> {
        let mut sorted: Vec<String> = texts.iter().map(|text| text.to_string()).collect();
        sorted.sort_by(|left, right| js_string_order(left, right));
        sorted
    }

    /// The brief's new row, "js strings: order is by UTF-16 code unit" (not a gjs row, so unmarked).
    #[test]
    fn order_is_by_utf16_code_unit() {
        // The emoji is the surrogate pair D83D DE00, below E000; Rust's own `str` order (by
        // code point) says the opposite.
        assert_eq!(
            js_string_order(GRINNING_FACE, PRIVATE_USE_E000),
            Ordering::Less
        );
        assert_eq!(GRINNING_FACE.cmp(PRIVATE_USE_E000), Ordering::Greater);
        assert_eq!(js_string_order("B", "_c"), Ordering::Less);
        assert_eq!(js_string_order("_c", "a"), Ordering::Less);
    }

    /// Sorting a mixed list gives what `[...].sort()` gives under gjs. Expected order: the
    /// `sort()` of the same list run under gjs (a throwaway script importing nothing from the
    /// crate), with U+FFFF, U+FFFD, U+E000, the emoji and U+10000 placed by their code units.
    #[test]
    fn sorting_a_mixed_list_matches_the_javascript_default_sort() {
        let texts = [
            "b",
            "B",
            "_c",
            "a",
            GRINNING_FACE,
            PRIVATE_USE_E000,
            "\u{FFFF}",
            "",
            "a\u{1F600}",
            "a\u{FFFF}",
            "\u{e9}",
            "e",
            "ab",
            "a",
            "\u{D7FF}",
            "\u{10000}",
            "\u{FFFD}",
        ];
        let expected = [
            "",
            "B",
            "_c",
            "a",
            "a",
            "ab",
            "a\u{1F600}",
            "a\u{FFFF}",
            "b",
            "e",
            "\u{e9}",
            "\u{D7FF}",
            "\u{10000}",
            GRINNING_FACE,
            PRIVATE_USE_E000,
            "\u{FFFD}",
            "\u{FFFF}",
        ];
        assert_eq!(sorted_by_js_order(&texts), expected);
    }

    /// Equal texts are equal, and a prefix is smaller than its extension, as in JavaScript.
    #[test]
    fn equal_texts_are_equal_and_a_prefix_is_smaller() {
        assert_eq!(js_string_order("same", "same"), Ordering::Equal);
        assert_eq!(js_string_order("ab", "abc"), Ordering::Less);
        assert_eq!(js_string_order("abc", "ab"), Ordering::Greater);
    }

    /// `charAt(0)` is one UTF-16 unit: upper-casing it changes a BMP first character and leaves
    /// a surrogate half alone, so a first character outside the BMP is never upper-cased.
    /// Expected values: `describeCgroup(...).fallbackName` run under gjs.
    #[test]
    fn capitalising_the_first_unit_leaves_a_character_outside_the_bmp_alone() {
        assert_eq!(capitalise_first_code_unit("chromium"), "Chromium");
        assert_eq!(
            capitalise_first_code_unit(&format!("{DESERET_SMALL_LONG_I}x")),
            format!("{DESERET_SMALL_LONG_I}x")
        );
        assert_eq!(capitalise_first_code_unit("\u{df}tool"), "SStool");
        assert_eq!(capitalise_first_code_unit("\u{fb01}sh"), "FIsh");
        assert_eq!(capitalise_first_code_unit("\u{149}x"), "\u{2bc}Nx");
        assert_eq!(capitalise_first_code_unit(""), "");
    }
}
