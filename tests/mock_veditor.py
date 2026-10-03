"""Mock VEditor service test harness using responses."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import time
from typing import Any

import responses
from django.urls import reverse


def make_jwt(
    payload: dict[str, Any] | None = None,
    secret: str = "test-jwt-secret-key-1234567890-32bytes",
    algorithm: str = "HS256",
) -> str:
    """Generate a syntactically valid signed JWT (<header>.<payload>.<signature>)."""
    now_ts = int(time.time())
    default_payload = {
        "sub": "user_default",
        "role": "organizer",
        "iat": now_ts,
        "exp": now_ts + 3600,
    }
    merged_payload = {**default_payload, **(payload or {})}
    try:
        import jwt

        return jwt.encode(merged_payload, secret, algorithm=algorithm)
    except Exception:
        header = {"alg": algorithm, "typ": "JWT"}

        def _b64url(data: bytes) -> str:
            return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

        header_b64 = _b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
        payload_b64 = _b64url(json.dumps(merged_payload, separators=(",", ":")).encode("utf-8"))
        signing_input = f"{header_b64}.{payload_b64}".encode()
        sig = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
        sig_b64 = _b64url(sig)
        return f"{header_b64}.{payload_b64}.{sig_b64}"


def validate_jwt_structure(token: str, secret: str | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    """Validate that token is syntactically a valid JWT (header.payload.signature).

    Verifies:
    1. Exactly three non-empty dot-separated base64url parts.
    2. Header contains valid JSON with 'typ': 'JWT' and an 'alg' attribute.
    3. Payload contains valid JSON.
    4. Optional cryptographic signature verification if secret is provided.

    Returns:
        tuple[dict, dict]: (header_dict, payload_dict)
    """
    assert isinstance(token, str), f"Expected token string, got {type(token)}"
    parts = token.split(".")
    assert len(parts) == 3, f"Token must contain exactly 3 dot-separated parts, got {len(parts)} in {token!r}"
    header_b64, payload_b64, signature_b64 = parts
    assert header_b64, "JWT header segment must not be empty"
    assert payload_b64, "JWT payload segment must not be empty"
    assert signature_b64, "JWT signature segment must not be empty"

    def _decode_segment(seg: str) -> dict[str, Any]:
        padded = seg + "=" * (-len(seg) % 4)
        data = base64.urlsafe_b64decode(padded.encode("ascii"))
        return json.loads(data.decode("utf-8"))

    header = _decode_segment(header_b64)
    payload = _decode_segment(payload_b64)

    assert header.get("typ") == "JWT", f"JWT header missing or invalid 'typ': {header}"
    assert "alg" in header, f"JWT header missing 'alg': {header}"

    if secret is not None:
        try:
            import jwt

            jwt.decode(token, secret, algorithms=[header["alg"]], options={"verify_exp": False})
        except ImportError:
            if header.get("alg") != "HS256":
                raise AssertionError(f"Unsupported algorithm for fallback verification: {header.get('alg')}") from None
            signing_input = f"{header_b64}.{payload_b64}".encode()
            expected_sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
            sig_padded = signature_b64 + "=" * (-len(signature_b64) % 4)
            actual_sig = base64.urlsafe_b64decode(sig_padded.encode("ascii"))
            if not hmac.compare_digest(actual_sig, expected_sig):
                raise AssertionError("JWT signature verification failed") from None
        except Exception as exc:
            raise AssertionError(f"JWT signature verification failed: {exc}") from exc

    return header, payload


class MockVEditor:
    """Simulates the VEditor REST API for end-to-end integration tests.

    Intercepts outbound HTTP requests from VEditorClient via the `responses` library,
    validates headers/auth, tracks received talks and SSO requests, and provides helpers
    to emit signed incoming webhooks against Eventyay.
    """

    def __init__(
        self,
        base_url: str = "http://localhost:8080",
        api_key: str = "test-veditor-api-key-12345",
        webhook_secret: str = "test-webhook-secret-999",
        jwt_secret: str = "test-jwt-secret-key-1234567890-32bytes",
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.webhook_secret = webhook_secret
        self.jwt_secret = jwt_secret

        # Recorded requests
        self.imported_schedules: list[dict[str, Any]] = []
        self.bulk_sync_requests: list[dict[str, Any]] = []
        self.synced_talks: list[dict[str, Any]] = []
        self.sso_token_requests: list[dict[str, Any]] = []
        self.events_queries: list[dict[str, Any]] = []
        self.emitted_webhooks: list[dict[str, Any]] = []

        # Configurable responses
        self.events_list: list[dict[str, Any]] = [
            {
                "id": 1,
                "name": "Test Event",
                "external_id": "test-event",
            }
        ]
        self.next_token: str | None = None
        self._rsps: responses.RequestsMock | None = None

    def __enter__(self) -> MockVEditor:
        self.start()
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.stop()

    def start(self) -> None:
        """Start intercepting HTTP calls to base_url."""
        if self._rsps is None:
            self._rsps = responses.RequestsMock(assert_all_requests_are_fired=False)
        self._rsps.start()
        self._register_default_routes()

    def stop(self) -> None:
        """Stop intercepting HTTP calls and reset registered routes."""
        if self._rsps is not None:
            try:
                self._rsps.stop()
                self._rsps.reset()
            except Exception:
                pass
            self._rsps = None

    def clear(self) -> None:
        """Clear all recorded request payloads and queries."""
        self.imported_schedules.clear()
        self.bulk_sync_requests.clear()
        self.synced_talks.clear()
        self.sso_token_requests.clear()
        self.events_queries.clear()
        self.emitted_webhooks.clear()

    def _check_auth(self, request: Any) -> bool:
        auth_header = request.headers.get("X-API-Key") or request.headers.get("Authorization")
        if not auth_header:
            return False
        if auth_header == self.api_key or auth_header == f"Bearer {self.api_key}":
            return True
        return False

    def _register_default_routes(self) -> None:
        assert self._rsps is not None

        # GET /events
        def events_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            self.events_queries.append({"url": request.url, "headers": dict(request.headers)})
            return (200, {"Content-Type": "application/json"}, json.dumps(self.events_list))

        self._rsps.add_callback(
            responses.GET,
            f"{self.base_url}/events",
            callback=events_callback,
            content_type="application/json",
        )

        # POST /talks/schedule/import
        def schedule_import_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            body_bytes = request.body if isinstance(request.body, bytes) else (request.body or "").encode("utf-8")
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            self.imported_schedules.append(data)
            talks = data.get("talks", [])
            self.synced_talks.extend(talks)
            return (
                200,
                {"Content-Type": "application/json"},
                json.dumps({"status": "ok", "imported_count": len(talks)}),
            )

        self._rsps.add_callback(
            responses.POST,
            f"{self.base_url}/talks/schedule/import",
            callback=schedule_import_callback,
            content_type="application/json",
        )

        # POST /events/{event_id}/talks/bulk
        bulk_talks_pattern = re.compile(rf"^{re.escape(self.base_url)}/events/(?P<event_id>[^/]+)/talks/bulk$")

        def bulk_talks_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            body_bytes = request.body if isinstance(request.body, bytes) else (request.body or "").encode("utf-8")
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            match = bulk_talks_pattern.match(request.url.split("?")[0])
            event_id = match.group("event_id") if match else "1"
            talks = data if isinstance(data, list) else data.get("talks", [])
            self.synced_talks.extend(talks)
            self.bulk_sync_requests.append({"event_id": event_id, "data": data, "talks": talks})
            return (
                200,
                {"Content-Type": "application/json"},
                json.dumps({"status": "ok", "synced_count": len(talks), "talks": talks}),
            )

        self._rsps.add_callback(
            responses.POST,
            bulk_talks_pattern,
            callback=bulk_talks_callback,
            content_type="application/json",
        )

        # POST /talks
        def single_talk_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            body_bytes = request.body if isinstance(request.body, bytes) else (request.body or "").encode("utf-8")
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            self.synced_talks.append(data)
            return (
                200,
                {"Content-Type": "application/json"},
                json.dumps({"status": "ok", "id": 101}),
            )

        self._rsps.add_callback(
            responses.POST,
            f"{self.base_url}/talks",
            callback=single_talk_callback,
            content_type="application/json",
        )

        # POST /events/{event_id}/sso-token
        sso_event_pattern = re.compile(rf"^{re.escape(self.base_url)}/events/(?P<event_id>[^/]+)/sso-token$")

        def sso_event_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            body_bytes = request.body if isinstance(request.body, bytes) else (request.body or "").encode("utf-8")
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            match = sso_event_pattern.match(request.url.split("?")[0])
            event_id = match.group("event_id") if match else "1"
            self.sso_token_requests.append({"endpoint": "event", "url": request.url, "body": data, "event_id": event_id})
            sub = data.get("email") or data.get("user_id") or f"user_event_{event_id}"
            token = self.next_token or make_jwt(
                {
                    "sub": sub,
                    "event_id": event_id,
                    "role": data.get("role", "organizer"),
                    "email": data.get("email"),
                },
                secret=self.jwt_secret,
            )
            return (
                200,
                {"Content-Type": "application/json"},
                json.dumps({"token": token, "status": "ok"}),
            )

        self._rsps.add_callback(
            responses.POST,
            sso_event_pattern,
            callback=sso_event_callback,
            content_type="application/json",
        )

        # POST /talks/{talk_id}/sso-token
        sso_talk_pattern = re.compile(rf"^{re.escape(self.base_url)}/talks/(?P<talk_id>[^/]+)/sso-token$")

        def sso_talk_callback(request: Any) -> tuple[int, dict[str, str], str]:
            if not self._check_auth(request):
                return (401, {}, json.dumps({"detail": "Invalid or missing API key"}))
            body_bytes = request.body if isinstance(request.body, bytes) else (request.body or "").encode("utf-8")
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            match = sso_talk_pattern.match(request.url.split("?")[0])
            talk_id = match.group("talk_id") if match else "1"
            self.sso_token_requests.append({"endpoint": "talk", "url": request.url, "body": data, "talk_id": talk_id})
            sub = data.get("email") or data.get("user_id") or f"user_talk_{talk_id}"
            token = self.next_token or make_jwt(
                {
                    "sub": sub,
                    "talk_id": talk_id,
                    "role": data.get("role", "speaker"),
                    "email": data.get("email"),
                },
                secret=self.jwt_secret,
            )
            return (
                200,
                {"Content-Type": "application/json"},
                json.dumps({"token": token, "status": "ok"}),
            )

        self._rsps.add_callback(
            responses.POST,
            sso_talk_pattern,
            callback=sso_talk_callback,
            content_type="application/json",
        )

    def generate_signature(self, body_bytes: bytes, secret: str | None = None, prefix: str = "sha256=") -> str:
        """Compute an HMAC-SHA256 signature for a webhook payload."""
        sec = secret or self.webhook_secret
        sig = hmac.new(sec.encode("utf-8"), body_bytes, hashlib.sha256).hexdigest()
        return f"{prefix}{sig}" if prefix else sig

    def emit_webhook(
        self,
        target_view_or_rf: Any,
        event: str,
        payload_data: dict[str, Any],
        secret: str | None = None,
        use_request_factory: bool = False,
        path: str | None = None,
    ) -> Any:
        """Dispatch a signed webhook to the plugin's WebhookView."""
        url = path or reverse("plugins:veditor:webhook")
        payload = dict(payload_data)
        payload["event"] = event
        if "timestamp" not in payload:
            payload["timestamp"] = time.time()

        raw_body = json.dumps(payload).encode("utf-8")
        sig = self.generate_signature(raw_body, secret=secret)
        self.emitted_webhooks.append({"event": event, "payload": payload, "signature": sig})

        if use_request_factory:
            from veditor.webhooks import WebhookView

            request = target_view_or_rf.post(
                url,
                data=raw_body,
                content_type="application/json",
                HTTP_X_VEDITOR_SIGNATURE=sig,
            )
            view = WebhookView.as_view()
            return view(request)

        return target_view_or_rf.post(
            url,
            data=raw_body,
            content_type="application/json",
            HTTP_X_VEDITOR_SIGNATURE=sig,
        )
