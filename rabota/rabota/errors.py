"""Exception hierarchy mapped to exit codes (spec §C1: 0 ok, 2 usage, 3 refused, 4 partial, 5 error)."""


class RabotaError(Exception):
    """Base error: exit 5, JSON name ``error``."""
    code = 5
    name = "error"


class Usage(RabotaError):
    """Bad arguments or an unknown name: exit 2."""
    code = 2
    name = "usage"


class Refused(RabotaError):
    """A named precondition failed: exit 3."""
    code = 3
    name = "refused"


class Partial(RabotaError):
    """Some items failed: exit 4, with the failed items listed."""
    code = 4
    name = "partial"

    def __init__(self, message, failed=None):
        super().__init__(message)
        self.failed = list(failed or [])


class SecretLeak(RabotaError):
    """Output would have contained a protected environment value: exit 5."""
    name = "secret_leak"
