"""The only place rabota spawns processes. Tests inject FakeRunner."""
import subprocess
from dataclasses import dataclass, field
from typing import Mapping, Protocol


@dataclass
class Result:
    """Outcome of one process run: exit code plus captured stdout and stderr."""
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0


class Runner(Protocol):
    def run(self, argv: list[str], *, env: dict | None = None, input: str | None = None,
            timeout: float = 60, cwd: str | None = None) -> Result: ...


class SubprocessRunner:
    """Real runner. The child gets exactly ``env`` (or the per-call override), never the parent's."""

    def __init__(self, env: Mapping[str, str]):
        self.env = dict(env)

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None) -> Result:
        """Run ``argv`` and capture its output; timeouts map to 124 and a missing binary to 127."""
        try:
            p = subprocess.run(argv, env=dict(env) if env is not None else self.env, input=input,
                               capture_output=True, text=True, timeout=timeout, cwd=cwd)
        except subprocess.TimeoutExpired as e:
            return Result(124, e.stdout or "", f"timeout after {timeout}s")
        except FileNotFoundError as e:
            return Result(127, "", f"not found: {e.filename}")
        return Result(p.returncode, p.stdout, p.stderr)


@dataclass
class FakeRunner:
    """Test double: answers by argv *prefix*, records every call, fails loudly on an unmatched one."""
    responses: list[tuple[list[str], Result]]
    calls: list[list[str]] = field(default_factory=list)

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None) -> Result:
        self.calls.append(list(argv))
        for prefix, result in self.responses:
            if list(argv[:len(prefix)]) == list(prefix):
                return result
        raise AssertionError(f"FakeRunner: no response for {argv!r}")
