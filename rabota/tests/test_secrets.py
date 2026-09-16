import unittest
from rabota import secrets, errors

# Assembled at runtime so no literal in this file looks like a credential to the
# gitleaks pre-commit hook (same convention as scripts/test-secret-guard.sh).
LEAKED = "lin_api_" + "secret" + "123"

class SecretsTests(unittest.TestCase):
    def test_scrub_unsets_and_sets(self):
        env = {name: "value-of-eight+" for name in secrets.UNSET_FOR_GH}
        env.update({"HOME": "/h", "PATH": "/bin"})
        out = secrets.scrub_env(env, set={"GH_CONFIG_DIR": "/h/.config/gh-x"})
        for name in secrets.UNSET_FOR_GH:
            self.assertNotIn(name, out)
        self.assertEqual(out["GH_CONFIG_DIR"], "/h/.config/gh-x")
        self.assertEqual(out["HOME"], "/h")

    def test_assert_clean_raises_on_leak(self):
        env = {"LINEAR_API_KEY": LEAKED}
        with self.assertRaises(errors.SecretLeak):
            secrets.assert_clean("Authorization: " + LEAKED, env)

    def test_assert_clean_passes_and_returns_text(self):
        env = {"LINEAR_API_KEY": LEAKED}
        self.assertEqual(secrets.assert_clean("ok", env), "ok")

    def test_short_or_empty_values_are_not_protected(self):
        # an empty or 1-char value would match everything; ignore it
        self.assertEqual(secrets.protected_values({"LINEAR_API_KEY": ""}), set())
