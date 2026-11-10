// The display-name guard: every short name the cockpit draws (a session slug, a branch, a workspace label, a mount
// label, a config card id) passes through guardDisplayName first. A name that is not a string of 1 to
// COCKPIT_NAME_MAX_CHARS characters, that carries a control character, or that has the shape of a credential is drawn
// as COCKPIT_REDACTED_NAME. Pure: no Gio and no Shell import.
//
// SECRET_SHAPE_PATTERNS ports the SHAPE rule set of scripts/redact-secrets.sh one to one, in its order and under its
// rule names (a test compares the two name lists). The by-name rules (`…TOKEN=value`) are not ported: a name has no
// `VAR=value` context. The sed rules replace a match inside a longer line; here a match anywhere in the name redacts
// the whole name, so the unanchored cores below are the faithful port.
import {COCKPIT_NAME_MAX_CHARS, COCKPIT_REDACTED_NAME} from './constants.js';

/** Matches a control character (below 0x20, or 0x7f). */
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/u;

/**
 * The credential shapes, in the order scripts/redact-secrets.sh tests them. `[[:space:]]` is `\s`. A keyed rule
 * (aws-secret, saml-request, vpn-auth-challenge, bearer, private-key, url-password) keeps its key in the pattern: the
 * sed rule keeps the key and replaces only the value, but here the whole name goes, so key and value both match.
 * private-key matches the BEGIN header alone (the sed rule also consumes the rest of the line, which a name has no
 * need for).
 *
 * @type {ReadonlyArray<{name: string, pattern: RegExp}>}
 */
export const SECRET_SHAPE_PATTERNS = Object.freeze([
    {name: 'github-token', pattern: /gh[pousr]_[A-Za-z0-9]{30,}/},
    {name: 'github-pat', pattern: /github_pat_[A-Za-z0-9_]{20,}/},
    {name: 'anthropic-key', pattern: /sk-ant-[A-Za-z0-9_-]{20,}/},
    {name: 'slack-token', pattern: /xox[baprse]-[A-Za-z0-9-]{10,}/},
    {name: 'aws-access-key-id', pattern: /AKIA[0-9A-Z]{16}/},
    {name: 'aws-temp-key-id', pattern: /ASIA[0-9A-Z]{16}/},
    {name: 'aws-secret', pattern: /aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{30,}/},
    {name: 'gitlab-pat', pattern: /glpat-[A-Za-z0-9_-]{20,}/},
    {name: 'notion-token', pattern: /ntn_[A-Za-z0-9]{40,}/},
    {name: 'linear-key', pattern: /lin_api_[A-Za-z0-9]{30,}/},
    {name: 'saml-request', pattern: /SAMLRequest=[A-Za-z0-9%+/=_-]{20,}/},
    {name: 'vpn-auth-challenge', pattern: /CRV1:[^\s"<]+/},
    {name: 'bearer', pattern: /[Bb]earer\s+[A-Za-z0-9._~+/-]{20,}/},
    {name: 'private-key', pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/},
    {name: 'url-password', pattern: /https?:\/\/[^:@\s/]+:[^@\s/]+@/},
].map(Object.freeze));

/**
 * Guards a name that is about to be published or drawn.
 *
 * @param {*} name - The candidate display name.
 * @returns {string} The name itself when it is a string of 1 to COCKPIT_NAME_MAX_CHARS characters (code points)
 *     with no control character and no secret shape; otherwise COCKPIT_REDACTED_NAME.
 */
export function guardDisplayName(name) {
    if (typeof name !== 'string' || name === '')
        return COCKPIT_REDACTED_NAME;
    if ([...name].length > COCKPIT_NAME_MAX_CHARS || CONTROL_CHARACTER_PATTERN.test(name))
        return COCKPIT_REDACTED_NAME;
    const looksLikeSecret = SECRET_SHAPE_PATTERNS.some(({pattern}) => pattern.test(name));
    return looksLikeSecret ? COCKPIT_REDACTED_NAME : name;
}
