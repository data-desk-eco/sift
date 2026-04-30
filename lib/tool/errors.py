"""Single shared error type, surfaced by main() with exit code 1 plus a
suggestion line. Keeping it in its own module avoids an awkward
client→vault import direction (both raise it)."""


class CommandError(Exception):
    def __init__(self, message: str, suggestion: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.suggestion = suggestion
