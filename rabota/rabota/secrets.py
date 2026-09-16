"""Environment handling that cannot leak a token.

Two rules from the v1 incident ledger: never expand a token variable into
anything printed, and drop the ambient gh token names; ``GhClient`` then sets a
minted one, so the identity is the tenant's, not the shell's (F14).

The first rule is enforced in ONE place: ``emit`` passes every string that
leaves the process through ``assert_clean`` against the real environment. A
command module therefore cannot bypass it by formatting its own output, as
long as it writes through ``emit`` — which is the only sanctioned way out.
"""
from typing import Iterable, Mapping

from rabota import errors

UNSET_FOR_GH = ("GH_" + "TOKEN", "GITHUB_" + "TOKEN")   # split so no literal token name appears in a shell
PROTECTED_NAMES = UNSET_FOR_GH + ("LINEAR_API_KEY", "SLACK_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
REGISTERED_VALUES: set[str] = set()   # values minted at runtime (gh tokens); never in os.environ, so registered here


def register_value(value: str) -> None:
    """Protect a runtime-minted secret so ``assert_clean`` catches it like an environment value."""
    if value and len(value) >= 8:
        REGISTERED_VALUES.add(value)


def scrub_env(base: Mapping[str, str], *, unset: Iterable[str] = UNSET_FOR_GH,
              set: Mapping[str, str] | None = None) -> dict[str, str]:
    """Copy ``base`` without the names in ``unset``, then overlay ``set``.

    Only the gh names are dropped by default, deliberately: a child may need
    ``LINEAR_API_KEY``. What a child prints is caught by ``assert_clean`` instead.
    Dropping the gh names is the first half of the identity rule; ``GhClient`` then
    overlays a token it minted for the tenant's login (the documented exception to
    "never pass a token"), and registers that value so it stays protected in output.
    """
    drop = frozenset(unset)
    env = {k: v for k, v in base.items() if k not in drop}
    if set:
        env.update(set)
    return env


def protected_items(env: Mapping[str, str], names: Iterable[str] = PROTECTED_NAMES) -> list[tuple[str, str]]:
    """``(name, value)`` for each protected variable present in ``env``; values under 8 chars are ignored."""
    return [(n, env[n]) for n in names if env.get(n) and len(env[n]) >= 8]


def protected_values(env: Mapping[str, str], names: Iterable[str] = PROTECTED_NAMES) -> set[str]:
    """Values of the protected variables present in ``env``; values under 8 chars are ignored."""
    return {v for _, v in protected_items(env, names)}


def assert_clean(text: str, env: Mapping[str, str], names: Iterable[str] = PROTECTED_NAMES) -> str:
    """Return ``text`` unchanged, or raise ``SecretLeak`` naming the VARIABLE (never its value)."""
    for name, value in protected_items(env, names):
        if value in text:
            raise errors.SecretLeak(f"output would contain the value of {name}; nothing was printed")
    for value in REGISTERED_VALUES:
        if value in text:
            raise errors.SecretLeak("output would contain a minted token; nothing was printed")
    return text
