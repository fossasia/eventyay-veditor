"""HTTP client for communicating with the standalone VEditor service."""

from __future__ import annotations

import logging
import os
from datetime import datetime
from typing import Any
from urllib.parse import urlparse

import requests
from django.conf import settings
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

from .exceptions import (
    VEditorAuthError,
    VEditorConfigError,
    VEditorError,
    VEditorNetworkError,
    VEditorSyncError,
)
from .mappers import serialize_talk, serialize_talks


class VEditorClient:
    """Single outbound API gateway for interacting with VEditor."""

    DEFAULT_TIMEOUT: float = 10.0

    @classmethod
    def resolve_base_url(cls, event: Any | None = None) -> str | None:
        """Resolve the configured VEditor base URL for an event or global settings."""

        def _pick_nonempty(*candidates: Any) -> str | None:
            for c in candidates:
                if c is not None and str(c).strip():
                    return str(c).strip().rstrip("/")
            return None

        if event is not None and hasattr(event, "settings"):
            res = _pick_nonempty(
                event.settings.get("veditor_api_base_url"),
                event.settings.get("veditor_base_url"),
            )
            if res:
                return res

        if getattr(settings, "configured", False):
            res = _pick_nonempty(
                getattr(settings, "VEDITOR_API_BASE_URL", None),
                getattr(settings, "VEDITOR_BASE_URL", None),
            )
            if res:
                return res

        res = _pick_nonempty(
            os.environ.get("VEDITOR_API_BASE_URL"),
            os.environ.get("VEDITOR_BASE_URL"),
        )
        if res:
            return res

        return None

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        timeout: float | None = None,
        session: requests.Session | None = None,
        event: Any | None = None,
    ):
        # 1. Resolve configuration from parameters, event settings, Django settings, or environment
        def _get_conf(name: str) -> Any:
            if event is not None and hasattr(event, "settings"):
                val = event.settings.get(name.lower())
                if val:
                    return val
            if getattr(settings, "configured", False):
                return getattr(settings, name, None)
            return None

        event_has_custom_url = bool(event is not None and hasattr(event, "settings") and event.settings.get("veditor_api_base_url"))
        event_custom_key = event.settings.get("veditor_api_key") if event is not None and hasattr(event, "settings") else None

        resolved_base_url = (
            base_url
            or _get_conf("VEDITOR_API_BASE_URL")
            or _get_conf("VEDITOR_BASE_URL")
            or os.environ.get("VEDITOR_API_BASE_URL")
            or os.environ.get("VEDITOR_BASE_URL")
        )

        self.event = event
        self.base_url = resolved_base_url.rstrip("/") if resolved_base_url else None

        # Prevent leaking global VEDITOR_API_KEY to unverified custom event URLs
        global_key = (getattr(settings, "VEDITOR_API_KEY", None) if getattr(settings, "configured", False) else None) or os.environ.get("VEDITOR_API_KEY")
        if global_key and event_has_custom_url and not event_custom_key and not api_key:
            allowed_raw = getattr(settings, "VEDITOR_ALLOWED_ORIGINS", None)
            allowed_set: set[str] = set()
            if isinstance(allowed_raw, str):
                allowed_set = {o.strip().lower() for o in allowed_raw.split(",") if o.strip()}
            elif isinstance(allowed_raw, (list, tuple, set)):
                allowed_set = {str(o).strip().lower() for o in allowed_raw if str(o).strip()}

            parsed_url = urlparse(self.base_url) if self.base_url else None
            origin = f"{parsed_url.scheme}://{parsed_url.netloc}".lower() if parsed_url and parsed_url.netloc else ""
            if not allowed_set or origin not in allowed_set:
                raise VEditorConfigError(
                    "Cannot use global VEDITOR_API_KEY with a custom unallowlisted event URL. "
                    "Configure an event-specific API key or add the origin to VEDITOR_ALLOWED_ORIGINS."
                )

        self.api_key = api_key or _get_conf("VEDITOR_API_KEY") or os.environ.get("VEDITOR_API_KEY")

        resolved_timeout = timeout if timeout is not None else _get_conf("VEDITOR_REQUEST_TIMEOUT") or os.environ.get("VEDITOR_REQUEST_TIMEOUT")
        if resolved_timeout is not None:
            try:
                self.timeout = float(resolved_timeout)
            except (ValueError, TypeError) as exc:
                raise VEditorConfigError(f"Invalid timeout '{resolved_timeout}'. Must be a positive number.") from exc
            if self.timeout <= 0:
                raise VEditorConfigError(f"Invalid timeout '{self.timeout}'. Must be strictly greater than 0.")
        else:
            self.timeout = self.DEFAULT_TIMEOUT

        # 2. Validate configuration
        self._validate_config()

        # 3. Setup persistent session with default auth headers and retry strategy
        self.session = session or requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[502, 503, 504],
            raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

        self.session.headers.update(
            {
                "X-API-Key": self.api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
        )

    def _validate_config(self) -> None:
        """Validate base_url and api_key."""
        if not self.base_url:
            raise VEditorConfigError("VEditor base URL is not configured. Set VEDITOR_API_BASE_URL.")

        parsed = urlparse(self.base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise VEditorConfigError(f"Invalid VEditor base URL '{self.base_url}'. Must start with http:// or https://.")

        hostname = (parsed.hostname or "").lower()
        is_loopback = hostname in ("localhost", "127.0.0.1", "::1")
        if parsed.scheme == "http" and not is_loopback:
            raise VEditorConfigError(
                f"Insecure HTTP URL '{self.base_url}' is only permitted for loopback addresses (localhost, 127.0.0.1). Production URLs must use HTTPS."
            )

        allowed = getattr(settings, "VEDITOR_ALLOWED_ORIGINS", None) if getattr(settings, "configured", False) else None
        if allowed:
            allowed_set: set[str] = set()
            if isinstance(allowed, str):
                allowed_set = {o.strip().lower() for o in allowed.split(",") if o.strip()}
            elif isinstance(allowed, (list, tuple, set)):
                allowed_set = {str(o).strip().lower() for o in allowed if str(o).strip()}

            origin = f"{parsed.scheme}://{parsed.netloc}".lower()
            hostname = (parsed.hostname or "").lower()
            netloc = (parsed.netloc or "").lower()
            if origin not in allowed_set and netloc not in allowed_set and hostname not in allowed_set:
                raise VEditorConfigError(f"The VEditor URL origin '{origin}' is not in VEDITOR_ALLOWED_ORIGINS.")

        self.base_url = self.base_url.rstrip("/")

        if not self.api_key or not self.api_key.strip():
            raise VEditorConfigError("VEditor API key is not configured. Set VEDITOR_API_KEY.")

    def _build_url(self, path: str) -> str:
        """Construct a clean absolute URL for an endpoint path."""
        return f"{self.base_url}/{path.lstrip('/')}"

    def _request(self, method: str, path: str, **kwargs) -> Any:
        """Execute an HTTP request against the VEditor API and handle exceptions."""
        url = self._build_url(path)
        kwargs.setdefault("timeout", self.timeout)
        kwargs.setdefault("allow_redirects", False)

        # Allow requests to generate multipart/form-data boundary headers when uploading files
        if "files" in kwargs:
            req_headers = dict(kwargs.get("headers") or {})
            req_headers["Content-Type"] = None
            kwargs["headers"] = req_headers

        try:
            response = self.session.request(method=method, url=url, **kwargs)
        except (requests.exceptions.Timeout, requests.exceptions.ConnectTimeout) as exc:
            raise VEditorNetworkError(f"VEditor request timed out: {exc}") from exc
        except (requests.exceptions.ConnectionError, requests.exceptions.ProxyError) as exc:
            raise VEditorNetworkError(f"Failed to connect to VEditor at {self.base_url}: {exc}") from exc
        except requests.exceptions.RequestException as exc:
            raise VEditorNetworkError(f"VEditor network transport error: {exc}") from exc

        return self._handle_response(response)

    def _handle_response(self, response: requests.Response) -> Any:
        """Parse response status code and body into appropriate exceptions or data."""
        try:
            data = response.json()
        except ValueError:
            data = {"raw_text": response.text}

        status = response.status_code

        if 200 <= status < 300:
            return data

        error_message = None
        if isinstance(data, dict):
            error_message = data.get("detail") or data.get("message")
        elif isinstance(data, (list, str)):
            error_message = str(data)

        if not error_message:
            error_message = response.text or f"HTTP {status}"

        if status in (401, 403):
            raise VEditorAuthError(
                f"VEditor authentication failed: {error_message}",
                status_code=status,
                response_data=data,
            )
        if status in (400, 422):
            raise VEditorSyncError(
                f"VEditor sync/validation error: {error_message}",
                status_code=status,
                response_data=data,
            )
        if 500 <= status < 600:
            raise VEditorNetworkError(
                f"VEditor server error: {error_message}",
                status_code=status,
                response_data=data,
            )

        raise VEditorError(
            f"VEditor request failed: {error_message}",
            status_code=status,
            response_data=data,
        )

    def sync_talk(self, talk_slot: Any, event_id: str | None = None) -> dict[str, Any]:
        """Synchronize a single talk with VEditor."""
        payload = serialize_talk(talk_slot, event_id=event_id)
        return self._request("POST", "/talks", json=payload)

    def sync_talks(self, event_id: int | str, talk_slots: list[Any]) -> dict[str, Any]:
        """Atomically upsert talks in bulk for an event via POST /talks/schedule/import.

        Note:
            The live VEditor schedule import endpoint matches and upserts talks based on
            `(event_id, title, start)` and returns `{"status": "ok", "imported_count": N}`.
        """
        try:
            normalized_event_id: int | str = int(event_id)
        except (ValueError, TypeError):
            normalized_event_id = event_id

        serialized = serialize_talks(talk_slots, event_id=event_id)
        payload = {"event_id": normalized_event_id, "talks": serialized}
        return self._request("POST", "/talks/schedule/import", json=payload)

    def get_scoped_event_id(self) -> int:
        """Resolve the target event ID in VEditor from the event-scoped API key.

        Queries GET /events, which automatically returns the event(s) permitted
        for the authenticated event-scoped API key. Disambiguates if multiple events
        are returned by matching the associated event's external_id/slug or name.
        """
        response_data = self._request("GET", "/events")
        if isinstance(response_data, list) and response_data:
            if len(response_data) == 1:
                first_event = response_data[0]
                if isinstance(first_event, dict) and "id" in first_event:
                    return int(first_event["id"])

            if self.event is not None:
                event_slug = getattr(self.event, "slug", None)
                event_id = getattr(self.event, "id", None)
                event_name = getattr(self.event, "name", None)

                # Pass 1: Strict match against external_id (slug or ID)
                slug_matched = []
                for ev in response_data:
                    if not isinstance(ev, dict):
                        continue
                    ext_id = ev.get("external_id")
                    if ext_id is not None and (
                        (event_slug is not None and str(ext_id) == str(event_slug)) or (event_id is not None and str(ext_id) == str(event_id))
                    ):
                        slug_matched.append(ev)

                if len(slug_matched) == 1 and "id" in slug_matched[0]:
                    return int(slug_matched[0]["id"])
                if len(slug_matched) > 1:
                    raise VEditorError(
                        f"Multiple events matched external_id for '{event_slug}' in VEditor.",
                        response_data=response_data,
                    )

                # Pass 2: Secondary fallback match by exact name if no external_id matched
                name_matched = []
                for ev in response_data:
                    if not isinstance(ev, dict):
                        continue
                    ev_name = ev.get("name")
                    if event_name and ev_name and str(ev_name) == str(event_name):
                        name_matched.append(ev)

                if len(name_matched) == 1 and "id" in name_matched[0]:
                    return int(name_matched[0]["id"])
                if len(name_matched) > 1:
                    raise VEditorError(
                        f"Multiple events matched name '{event_name}' in VEditor.",
                        response_data=response_data,
                    )

                raise VEditorError(
                    f"Multiple events returned by VEditor for API key, and cannot disambiguate for event '{event_slug}'.",
                    response_data=response_data,
                )

            raise VEditorError(
                "Multiple events returned by VEditor API key but no event context provided to disambiguate.",
                response_data=response_data,
            )

        raise VEditorError("No event associated with this API key was found in VEditor.", response_data=response_data)

    def request_sso_jwt(
        self,
        event_id: str,
        talk_id: str | None = None,
        role: str = "organizer",
        email: str | None = None,
        display_name: str | None = None,
    ) -> str:
        """Request a scoped SSO JWT token for browser handoff, reviewer QA, or speaker review."""
        normalized_role = "organizer" if role in ("organiser", "organizer") else role
        if normalized_role == "organizer":
            endpoint = f"/events/{event_id}/sso-token"
            payload = {"role": "organizer"}
        elif normalized_role == "speaker":
            if not talk_id:
                raise ValueError("talk_id is required when requesting a speaker SSO token")
            endpoint = f"/talks/{talk_id}/sso-token"
            payload = {"role": "speaker"}
        else:
            raise ValueError(f"Unsupported role '{role}'. Allowed roles are 'organizer' and 'speaker'.")

        if email:
            payload["email"] = email
        if display_name:
            payload["display_name"] = display_name

        response_data = self._request("POST", endpoint, json=payload)

        if isinstance(response_data, dict):
            token = response_data.get("token") or response_data.get("sso_token") or response_data.get("jwt")
            if not token:
                raise VEditorError("No token received in SSO response", response_data=response_data)
            return str(token)
        if isinstance(response_data, str):
            return response_data

        raise VEditorError("Unexpected response type from SSO token endpoint", response_data=response_data)

    def attach_room_recording(
        self,
        room: str,
        event_id: int | str | None = None,
        video_url: str | None = None,
        video_file: Any | None = None,
        relative_key: str | None = None,
        source_path: str | None = None,
        recording_start: str | datetime | None = None,
    ) -> dict[str, Any]:
        """Attach a continuous room recording to all scheduled sessions in that room.

        Calls POST /talks/room/attach-recording on the VEditor server.
        Matches talks in the specified room whose schedule falls within the
        recording duration.

        Args:
            room: Name of the room as configured in the schedule.
            event_id: Target event ID in VEditor. If None, auto-resolved via get_scoped_event_id().
            video_url: External video / livestream URL (YouTube, Vimeo, or HTTP stream).
            video_file: File-like object or tuple suitable for requests multipart upload.
            relative_key: Optional path to recording file relative to VEditor's ingest roots.
            source_path: Optional shared storage path to recording file accessible by VEditor.
            recording_start: Optional ISO-8601 string or datetime of when recording began.

        Returns:
            Dict containing status, attached_count, room, event_id, talk_ids.
        """
        if not room or not str(room).strip():
            raise ValueError("Room name is required to attach room recording.")

        clean_url = str(video_url).strip() if video_url else None
        clean_rel = str(relative_key).strip() if relative_key else None
        clean_src = str(source_path).strip() if source_path else None

        provided_sources = [
            name
            for name, val in [
                ("video_url", clean_url),
                ("video_file", video_file),
                ("relative_key", clean_rel),
                ("source_path", clean_src),
            ]
            if val is not None and (val != "" if isinstance(val, str) else True)
        ]

        if not provided_sources:
            raise ValueError("Either video_url, video_file, relative_key, or source_path must be provided.")
        if len(provided_sources) > 1:
            raise ValueError(f"Conflicting recording sources provided: {', '.join(provided_sources)}. Please specify only one recording source.")

        if event_id is None:
            try:
                event_id = self.get_scoped_event_id()
            except Exception as exc:
                logger.debug("Could not auto-resolve scoped event ID: %s", exc)

        rec_start_val: str | None = None
        if recording_start is not None:
            if isinstance(recording_start, datetime):
                rec_start_val = recording_start.isoformat()
            else:
                rec_start_val = str(recording_start).strip()

        # Handle multipart file upload
        if video_file is not None:
            data: dict[str, Any] = {"room": str(room).strip()}
            if event_id is not None:
                data["event_id"] = str(event_id)
            if rec_start_val:
                data["recording_start"] = rec_start_val
            files = {"file": video_file}
            return self._request("POST", "/talks/room/attach-recording", data=data, files=files)

        # Handle JSON request for URL or file paths
        payload: dict[str, Any] = {"room": str(room).strip()}

        if event_id is not None:
            try:
                payload["event_id"] = int(event_id)
            except (ValueError, TypeError):
                payload["event_id"] = event_id

        if clean_url:
            payload["video_url"] = clean_url

        if clean_rel:
            payload["relative_key"] = clean_rel

        if clean_src:
            payload["source_path"] = clean_src

        if rec_start_val:
            payload["recording_start"] = rec_start_val

        return self._request("POST", "/talks/room/attach-recording", json=payload)
