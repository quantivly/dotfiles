//! The language list of `g_get_language_names` (`glib/gcharset.c`: `guess_category_value`,
//! `append_locale_variants`, `explode_locale`), without `locale.alias`.

/// The language `g_get_language_names` always ends with, and that ends a name search.
pub(super) const C_LOCALE: &str = "C";
const LANGUAGE_VARIABLE_ORDER: [&str; 4] = ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"];
const LIST_SEPARATOR: char = ':';
const CODESET_COMPONENT: u8 = 1;
const TERRITORY_COMPONENT: u8 = 2;
const MODIFIER_COMPONENT: u8 = 4;

/// The language list the environment gives: the first non-empty of `LANGUAGE`, `LC_ALL`,
/// `LC_MESSAGES` and `LANG` (else `C`), split at `:`, each entry as its variants, then `C`.
pub(super) fn language_names(environment: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    let languages = LANGUAGE_VARIABLE_ORDER
        .iter()
        .filter_map(|variable| environment(variable))
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| C_LOCALE.to_owned());
    let mut names: Vec<String> = languages
        .split(LIST_SEPARATOR)
        .flat_map(locale_variants)
        .collect();
    names.push(C_LOCALE.to_owned());
    names
}

/// Every variant of one locale, the most specific first: `language[_territory][.codeset][@modifier]`
/// with each subset of the optional parts that is there, the later parts dropped first.
fn locale_variants(locale: &str) -> Vec<String> {
    let characters: Vec<char> = locale.chars().collect();
    let position_from = |marker: char, start: usize| {
        characters
            .iter()
            .enumerate()
            .skip(start)
            .find(|(_, &character)| character == marker)
            .map(|(position, _)| position)
    };
    let underscore = position_from('_', 0);
    let dot = position_from('.', underscore.unwrap_or(0));
    let at_sign = position_from('@', dot.or(underscore).unwrap_or(0));
    let text = |from: usize, to: usize| -> String {
        characters
            .get(from..to)
            .map(|part| part.iter().collect())
            .unwrap_or_default()
    };
    let modifier_start = at_sign.unwrap_or(characters.len());
    let codeset_start = dot
        .filter(|&position| position < modifier_start)
        .unwrap_or(modifier_start);
    let territory_start = underscore
        .filter(|&position| position < codeset_start)
        .unwrap_or(codeset_start);
    let language = text(0, territory_start);
    let territory = text(territory_start, codeset_start);
    let codeset = text(codeset_start, modifier_start);
    let modifier = text(modifier_start, characters.len());
    let mut present = 0;
    if underscore.is_some_and(|position| position < codeset_start) {
        present |= TERRITORY_COMPONENT;
    }
    if dot.is_some_and(|position| position < modifier_start) {
        present |= CODESET_COMPONENT;
    }
    if at_sign.is_some() {
        present |= MODIFIER_COMPONENT;
    }
    (0..=present)
        .map(|steps_taken| present - steps_taken)
        .filter(|subset| subset & !present == 0)
        .map(|subset| {
            let mut variant = language.clone();
            if subset & TERRITORY_COMPONENT != 0 {
                variant.push_str(&territory);
            }
            if subset & CODESET_COMPONENT != 0 {
                variant.push_str(&codeset);
            }
            if subset & MODIFIER_COMPONENT != 0 {
                variant.push_str(&modifier);
            }
            variant
        })
        .collect()
}
