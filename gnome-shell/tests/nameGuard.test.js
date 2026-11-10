// lib/nameGuard.js: the display-name guard, and its agreement with the shape rules of scripts/redact-secrets.sh.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as nameGuard from '../extensions/resource-pulse@dotfiles/lib/nameGuard.js';

const REPO_ROOT_URI = GLib.uri_resolve_relative(import.meta.url, '../../', GLib.UriFlags.NONE);
const [REPO_ROOT] = GLib.filename_from_uri(REPO_ROOT_URI);
const REDACTOR_PATH = GLib.build_filenamev([REPO_ROOT, 'scripts', 'redact-secrets.sh']);
const SHAPE_RULES_START = 'SHAPE_RULES=(';
const SHAPE_RULES_END = ')';
const RULE_LINE_PATTERN = /^\s*-e '/;
const RULE_NAME_PATTERN = /<REDACTED:([a-z0-9-]+)>/;
const REDACTED = '—';

/**
 * The shape rule names in scripts/redact-secrets.sh: the `-e '` lines inside its SHAPE_RULES array, which a header
 * comment or the by-name rules cannot be mistaken for.
 *
 * @returns {string[]} The sorted rule names.
 */
function redactorShapeRuleNames() {
    const [, contentBytes] = Gio.File.new_for_path(REDACTOR_PATH).load_contents(null);
    const lines = new TextDecoder().decode(contentBytes).split('\n');
    const startIndex = lines.findIndex(line => line === SHAPE_RULES_START);
    const endIndex = lines.indexOf(SHAPE_RULES_END, startIndex);
    return lines.slice(startIndex + 1, endIndex)
        .filter(line => RULE_LINE_PATTERN.test(line))
        .map(line => RULE_NAME_PATTERN.exec(line)[1])
        .sort();
}

// One synthetic string per shape, built at runtime from made-up characters so no token-shaped literal is committed.
const SHAPE_SAMPLES = {
    'github-token': 'ghp_' + 'A1'.repeat(18),
    'github-pat': 'github_pat_' + 'B2'.repeat(15),
    'anthropic-key': 'sk-ant-' + 'c3'.repeat(15),
    'slack-token': 'xoxb-' + '1234'.repeat(3),
    'aws-access-key-id': 'AKIA' + 'Q7'.repeat(8),
    'aws-temp-key-id': 'ASIA' + 'Z9'.repeat(8),
    'aws-secret': 'aws_secret_access_key = ' + 'k/+'.repeat(11),
    'gitlab-pat': 'glpat-' + 'd4'.repeat(12),
    'notion-token': 'ntn_' + 'E5'.repeat(22),
    'linear-key': 'lin_api_' + 'f6'.repeat(17),
    'saml-request': 'SAMLRequest=' + 'ab%2B'.repeat(6),
    'vpn-auth-challenge': 'CRV1:' + 'R:instance-' + 'x'.repeat(8),
    'bearer': 'Bearer ' + 'tok.en-'.repeat(4),
    'private-key': '-----BEGIN RSA ' + 'PRIVATE KEY-----',
    'url-password': 'https://' + 'user' + ':' + 'hunter2' + '@' + 'example.com',
};

test('nameGuard: an ordinary slug, a branch and a label pass through', () => {
    for (const name of ['host-sync', 'zvi/cockpit-stage-1', 'DO-894 host sync', 'teammate 2.1.259'])
        assertEqual(nameGuard.guardDisplayName(name), name);
});
test('nameGuard: a name over 64 characters is redacted', () => {
    assertEqual(nameGuard.guardDisplayName('a'.repeat(65)), REDACTED);
    assertEqual(nameGuard.guardDisplayName('a'.repeat(64)), 'a'.repeat(64));
});
test('nameGuard: length is counted in characters, not UTF-16 units', () => {
    assertEqual(nameGuard.guardDisplayName('😀'.repeat(64)), '😀'.repeat(64));
    assertEqual(nameGuard.guardDisplayName('😀'.repeat(65)), REDACTED);
});
test('nameGuard: a non-string, an empty string and a control character are redacted', () => {
    assertEqual(nameGuard.guardDisplayName(null), REDACTED);
    assertEqual(nameGuard.guardDisplayName(''), REDACTED);
    assertEqual(nameGuard.guardDisplayName('a\u001bb'), REDACTED);
    assertEqual(nameGuard.guardDisplayName('a\u007fb'), REDACTED);
});
test('nameGuard: every shape rule in scripts/redact-secrets.sh has a pattern here with the same name', () => {
    const ownNames = nameGuard.SECRET_SHAPE_PATTERNS.map(({name}) => name).sort();
    assertEqual(ownNames, redactorShapeRuleNames());
});
test('nameGuard: every shape has a sample here', () => {
    assertEqual(Object.keys(SHAPE_SAMPLES).sort(), redactorShapeRuleNames());
});
for (const [shapeName, sample] of Object.entries(SHAPE_SAMPLES)) {
    test(`nameGuard: a ${shapeName}-shaped name is redacted`, () => {
        assertEqual(nameGuard.guardDisplayName(sample), REDACTED);
        const pattern = nameGuard.SECRET_SHAPE_PATTERNS.find(({name}) => name === shapeName).pattern;
        assertEqual(pattern.test(sample), true);
    });
}
