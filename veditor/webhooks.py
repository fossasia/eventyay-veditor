"""Inbound webhook receiver for VEditor lifecycle events."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import time
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlparse

from django.conf import settings
from django.db import DatabaseError
from django.http import HttpRequest, HttpResponse, JsonResponse
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt

from .tasks import process_talk_approved, process_talk_published

logger = logging.getLogger(__name__)

TIMESTAMP_TOLERANCE_SECONDS = 300  # 5 minutes replay tolerance


def parse_timestamp(value: Any) -> float | None:
    """Extract a UNIX epoch timestamp from an integer, float, or ISO-8601 string."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            pass
        try:
            dt = datetime.fromisoformat(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=UTC)
            return dt.timestamp()
        except (ValueError, TypeError):
            return None
    return None


def verify_hmac_signature(
    raw_body: bytes,
    signature_header: str,
    secret: str,
    timestamp: float | None = None,
) -> bool:
    """Verify HMAC-SHA256 signature against the raw request body.

    Supports:
    - sha256=<hex> (VEditor dispatcher format)
    - t=<timestamp>,v1=<hex> (Stripe/standard webhook format)
    - <hex> (raw hex signature)
    """
    if not signature_header or not secret:
        return False

    received_sig = signature_header.strip()
    header_ts = None

    # Handle t=<timestamp>,v1=<sig> or v1=<sig>
    parts: dict[str, str] = {}
    if "," in received_sig or "=" in received_sig:
        for part in received_sig.split(","):
            if "=" in part:
                k, v = part.split("=", 1)
                parts[k.strip()] = v.strip()
        if "t" in parts:
            header_ts = parse_timestamp(parts["t"])
        if "v1" in parts:
            received_sig = parts["v1"]
        elif "sha256" in parts:
            received_sig = parts["sha256"]

    # If header had a timestamp and caller didn't supply one, use header timestamp
    effective_ts = timestamp if timestamp is not None else header_ts
    if effective_ts is not None:
        current_time = time.time()
        if abs(current_time - effective_ts) > TIMESTAMP_TOLERANCE_SECONDS:
            logger.warning(
                "Webhook rejected due to timestamp skew: received=%s, current=%s, diff=%s",
                effective_ts,
                current_time,
                abs(current_time - effective_ts),
            )
            return False

    secret_bytes = secret.encode("utf-8")

    # If t=<timestamp>,v1=<sig> scheme is used with payload prefix <timestamp>.<raw_body>
    if header_ts is not None and parts.get("v1"):
        ts_str = str(parts.get("t", "")).strip()
        signed_payload = f"{ts_str}.".encode() + raw_body
        expected_sig_ts = hmac.new(secret_bytes, signed_payload, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected_sig_ts.lower(), received_sig.lower())

    # Standard body signature: sha256(raw_body)
    expected_sig = hmac.new(secret_bytes, raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected_sig.lower(), received_sig.lower())


@method_decorator(csrf_exempt, name="dispatch")
class WebhookView(View):
    """Public endpoint to receive, authenticate, and dispatch lifecycle signals from VEditor."""

    http_method_names = ["post"]

    def post(self, request: HttpRequest, *args: Any, **kwargs: Any) -> HttpResponse:
        signature_header = request.headers.get("X-VEditor-Signature") or request.META.get("HTTP_X_VEDITOR_SIGNATURE")
        if not signature_header:
            return JsonResponse({"error": "Missing X-VEditor-Signature header"}, status=401)

        raw_body = request.body
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return JsonResponse({"error": "Invalid JSON payload"}, status=400)

        if not isinstance(payload, dict):
            return JsonResponse({"error": "Payload must be a JSON object"}, status=400)

        # Extract timestamp: prioritize signature header timestamp (bound cryptographically in v1 scheme)
        # and fall back to payload body timestamp for raw body schemes
        header_ts = None
        if signature_header and ("t=" in signature_header or "," in signature_header):
            parts = {k.strip(): v.strip() for part in signature_header.split(",") if "=" in part for k, v in [part.split("=", 1)]}
            if "t" in parts:
                header_ts = parse_timestamp(parts["t"])

        effective_ts = header_ts if header_ts is not None else parse_timestamp(payload.get("timestamp"))

        # Replay attack mitigation: Require a valid signed timestamp within tolerance
        if effective_ts is None:
            return JsonResponse({"error": "Missing required timestamp for replay protection"}, status=400)

        current_time = time.time()
        if abs(current_time - effective_ts) > TIMESTAMP_TOLERANCE_SECONDS:
            return JsonResponse(
                {"error": "Webhook timestamp expired or clock skew exceeds tolerance"},
                status=400,
            )

        # Resolve webhook shared secret: event-scoped secret takes precedence
        secret = None
        event_id = payload.get("event_id")
        if event_id is not None and event_id != "":
            try:
                from eventyay.base.models import Event

                event_obj = None
                if str(event_id).isdigit():
                    event_obj = Event.objects.filter(id=int(event_id)).first()
                if not event_obj:
                    event_obj = Event.objects.filter(slug=str(event_id)).first()

                if event_obj and hasattr(event_obj, "settings"):
                    secret = event_obj.settings.get("veditor_webhook_secret")
            except DatabaseError as exc:
                logger.error("Database error looking up event-level webhook secret for event %s: %s", event_id, exc)
                return JsonResponse({"error": "Database error looking up event secret"}, status=500)
            except Exception as exc:  # noqa: BLE001
                logger.debug("Failed looking up event-level webhook secret for event %s: %s", event_id, exc)

        if not secret:
            secret = getattr(settings, "VEDITOR_WEBHOOK_SECRET", None) or os.environ.get("VEDITOR_WEBHOOK_SECRET")

        if not secret:
            logger.error("VEditor webhook secret not configured")
            return JsonResponse({"error": "Webhook secret not configured on server"}, status=500)

        # Authenticate signature
        if not verify_hmac_signature(raw_body, signature_header, secret, timestamp=effective_ts):
            return JsonResponse({"error": "Invalid webhook signature"}, status=401)

        # Extract and validate event signal details
        event_type = payload.get("event") or "talk.approved"
        if event_type == "ping":
            return JsonResponse({"status": "pong", "message": "Webhook verified"}, status=200)

        if event_type not in ("talk.approved", "talk.published"):
            return JsonResponse({"error": f"Unsupported webhook event type: {event_type}"}, status=400)

        talk_id = payload.get("talk_id")
        external_id = payload.get("external_id")

        if talk_id is None or talk_id == "" or event_id is None or event_id == "":
            return JsonResponse({"error": "Missing required fields: event_id and talk_id"}, status=400)

        video_url = None
        if event_type == "talk.published":
            raw_url = payload.get("video_url")
            if not raw_url or not isinstance(raw_url, str) or not raw_url.strip():
                return JsonResponse({"error": "Missing or invalid video_url for talk.published event"}, status=400)
            video_url = raw_url.strip()
            parsed_video = urlparse(video_url)
            if parsed_video.scheme not in ("http", "https") or not parsed_video.netloc:
                return JsonResponse({"error": "video_url must be a valid HTTP or HTTPS URL with host"}, status=400)

            if external_id is None or not str(external_id).strip():
                return JsonResponse({"error": "Missing or invalid external_id for talk.published event"}, status=400)
            external_id = str(external_id).strip()

        # Asynchronously dispatch supported events
        try:
            if event_type == "talk.published":
                process_talk_published.delay(
                    event_id=event_id,
                    talk_id=talk_id,
                    video_url=video_url,
                    external_id=external_id,
                    raw_payload=payload,
                )
            else:
                process_talk_approved.delay(
                    event_id=event_id,
                    talk_id=talk_id,
                    external_id=external_id,
                    raw_payload=payload,
                )
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed to enqueue %s task: %s", event_type, exc)
            return JsonResponse({"error": "Failed to enqueue task"}, status=500)

        return JsonResponse({"status": "accepted"}, status=200)
