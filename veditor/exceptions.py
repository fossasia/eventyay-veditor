"""Custom exception hierarchy for the VEditor client integration."""


class VEditorError(Exception):
    """Base exception for all VEditor client errors."""

    def __init__(self, message: str, status_code: int | None = None, response_data: dict | None = None):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.response_data = response_data

    def __str__(self) -> str:
        if self.status_code is not None:
            return f"{self.message} (HTTP {self.status_code})"
        return self.message


class VEditorConfigError(VEditorError):
    """Raised when client configuration (API key, base URL) is missing or invalid."""


class VEditorAuthError(VEditorError):
    """Raised when authentication or authorization fails (HTTP 401/403)."""


class VEditorSyncError(VEditorError):
    """Raised when talk sync payload validation or server-side sync fails (HTTP 400/422)."""


class VEditorNetworkError(VEditorError):
    """Raised when network transport fails (timeouts, connection refused, 5xx server errors)."""


class VEditorEventNotFoundError(VEditorError):
    """Raised when an expected event is not found in VEditor."""
