"""Environment handling that cannot leak a token.

Two rules from the v1 incident ledger: never expand a token variable into
anything printed, and run gh with its token variables removed so the keyring
identity wins.
"""
from typing import Iterable, Mapping

from rabota import errors

UNSET_FOR_GH = ("GH_" + "TOKEN", "GITHUB_" + "TOKEN")   # split so no literal token name appears in a shell
PROTECTED_NAMES = UNSET_FOR_GH + ("LINEAR_API_KEY", "SLACK_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")


def scrub_env(base: Mapping[str, str], *, unset: Iterable[str] = UNSET_FOR_GH,
              set: Mapping[str, str] | None = None) -> dict[str, str]:
    """Copy ``base`` without the names in ``unset``, then overlay ``set``."""
    drop = frozenset(unset)
    env = {k: v for k, v in base.items() if k not in drop}
    if set:
        env.update(set)
    return env


def protected_values(env: Mapping[str, str], names: Iterable[str] = PROTECTED_NAMES) -> set[str]:
    """Values of the protected variables present in ``env``; values under 8 chars are ignored."""
    return {env[n] for n in names if env.get(n) and len(env[n]) >= 8}


def assert_clean(text: str, env: Mapping[str, str], names: Iterable[str] = PROTECTED_NAMES) -> str:
    """Return ``text`` unchanged, or raise ``SecretLeak`` if it contains a protected value."""
    for value in protected_values(env, names):
        if value in text:
            raise errors.SecretLeak("output would contain the value of a protected variable")
    return text
