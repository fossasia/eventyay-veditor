"""Unit and integration tests for the VEditor inbound webhook receiver."""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from django.test import RequestFactory
from django.urls import reverse

from veditor.tasks import process_talk_approved
from veditor.webhooks import WebhookView, parse_timestamp, verify_hmac_signature


@pytest.fixture
def rf():
    return RequestFactory()


@pytest.fixture
def webhook_secret():
    return "test-webhook-secret-key-12345"


def generate_signature(secret: str, body: bytes, prefix: str = "sha256=") -> str:
    sig = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return f"{prefix}{sig}" if prefix else sig


# ============================================================================
# Signature Verification Unit Tests
# ============================================================================


def test_parse_timestamp():
    assert parse_timestamp(1700000000) == 1700000000.0
    assert parse_timestamp(1700000000.5) == 1700000000.5
    assert parse_timestamp("1700000000") == 1700000000.0
    assert parse_timestamp("2026-09-16T10:00:00Z") is not None
    assert parse_timestamp("invalid") is None
    assert parse_timestamp(None) is None


def test_verify_hmac_signature_sha256_format(webhook_secret):
    body = b'{"talk_id": 42, "event_id": 10}'
    sig = generate_signature(webhook_secret, body, prefix="sha256=")
    assert verify_hmac_signature(body, sig, webhook_secret) is True


def test_verify_hmac_signature_raw_hex_format(webhook_secret):
    body = b'{"talk_id": 42, "event_id": 10}'
    sig = generate_signature(webhook_secret, body, prefix="")
    assert verify_hmac_signature(body, sig, webhook_secret) is True


def test_verify_hmac_signature_v1_scheme(webhook_secret):
    body = b'{"talk_id": 42, "event_id": 10}'
    now_ts = int(time.time())
    signed_payload = f"{now_ts}.".encode() + body
    v1_sig = hmac.new(webhook_secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
    header = f"t={now_ts},v1={v1_sig}"
    assert verify_hmac_signature(body, header, webhook_secret) is True


def test_verify_hmac_signature_wrong_secret(webhook_secret):
    body = b'{"talk_id": 42}'
    sig = generate_signature(webhook_secret, body)
    assert verify_hmac_signature(body, sig, "wrong-secret") is False


def test_verify_hmac_signature_tampered_body(webhook_secret):
    body = b'{"talk_id": 42}'
    sig = generate_signature(webhook_secret, body)
    tampered = b'{"talk_id": 99}'
    assert verify_hmac_signature(tampered, sig, webhook_secret) is False


def test_verify_hmac_signature_empty_or_missing(webhook_secret):
    body = b'{"talk_id": 42}'
    assert verify_hmac_signature(body, "", webhook_secret) is False
    assert verify_hmac_signature(body, "sha256=123", "") is False


def test_verify_hmac_signature_replay_skew(webhook_secret):
    body = b'{"talk_id": 42}'
    old_ts = time.time() - 400  # > 300s tolerance
    sig = generate_signature(webhook_secret, body)
    assert verify_hmac_signature(body, sig, webhook_secret, timestamp=old_ts) is False

    future_ts = time.time() + 400
    assert verify_hmac_signature(body, sig, webhook_secret, timestamp=future_ts) is False


# ============================================================================
# WebhookView Integration Tests
# ============================================================================


def test_webhook_view_url_resolution():
    url = reverse("plugins:veditor:webhook")
    assert url == "/api/v1/veditor/webhook/"


def test_webhook_view_post_success(rf, webhook_secret):
    payload = {
        "event": "talk.approved",
        "talk_id": 101,
        "event_id": 42,
        "external_id": "TALK-ABC",
        "timestamp": datetime.now(UTC).isoformat(),
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings, patch("veditor.webhooks.process_talk_approved") as mock_task:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret

        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        data = json.loads(response.content.decode("utf-8"))
        assert data["status"] == "accepted"
        mock_task.delay.assert_called_once_with(
            event_id=42,
            talk_id=101,
            external_id="TALK-ABC",
            raw_payload=payload,
        )


def test_webhook_view_missing_signature_header(rf, webhook_secret):
    payload = {"talk_id": 101, "event_id": 42, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 401
        data = json.loads(response.content.decode("utf-8"))
        assert "Missing X-VEditor-Signature" in data["error"]


def test_webhook_view_missing_timestamp_for_replay(rf, webhook_secret):
    payload = {"talk_id": 101, "event_id": 42}
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "Missing required timestamp for replay protection" in data["error"]


def test_webhook_view_invalid_signature(rf, webhook_secret):
    payload = {"talk_id": 101, "event_id": 42, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE="sha256=invalidhexsignature123456",
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 401
        data = json.loads(response.content.decode("utf-8"))
        assert "Invalid webhook signature" in data["error"]


def test_webhook_view_expired_timestamp_in_payload(rf, webhook_secret):
    payload = {
        "talk_id": 101,
        "event_id": 42,
        "timestamp": time.time() - 500,  # 500s ago
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "timestamp expired" in data["error"]


def test_webhook_view_malformed_json(rf, webhook_secret):
    body = b"not-a-valid-json-string{"
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "Invalid JSON" in data["error"]


def test_webhook_view_non_object_json(rf, webhook_secret):
    body = b'["not", "a", "dict"]'
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "must be a JSON object" in data["error"]


def test_webhook_view_missing_talk_id(rf, webhook_secret):
    payload = {"event": "talk.approved", "event_id": 42, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "Missing required fields" in data["error"]


def test_webhook_view_missing_event_id(rf, webhook_secret):
    payload = {"event": "talk.approved", "talk_id": 101, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "Missing required fields" in data["error"]


def test_webhook_view_unsupported_event_type(rf, webhook_secret):
    payload = {
        "event": "talk.deleted",
        "talk_id": 101,
        "event_id": 42,
        "timestamp": time.time(),
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "Unsupported webhook event type" in data["error"]


def test_webhook_view_secret_not_configured(rf):
    payload = {"talk_id": 101, "event_id": 42, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE="sha256=123",
    )

    with patch("veditor.webhooks.settings") as mock_settings, patch.dict("os.environ", {}, clear=True):
        mock_settings.VEDITOR_WEBHOOK_SECRET = None
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 500
        data = json.loads(response.content.decode("utf-8"))
        assert "not configured" in data["error"]


def test_webhook_view_per_event_secret_precedence(rf):
    event_secret = "per-event-secret-999"
    global_secret = "global-secret-111"
    payload = {"talk_id": 101, "event_id": 88, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")
    # Signed with event_secret, which should take precedence over global_secret
    sig = generate_signature(event_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    mock_event = SimpleNamespace(
        id=88,
        slug="conf-88",
        settings=SimpleNamespace(get=lambda k, d=None: event_secret if k == "veditor_webhook_secret" else d),
    )

    with (
        patch("veditor.webhooks.settings") as mock_settings,
        patch.dict("os.environ", {}, clear=True),
        patch("eventyay.base.models.Event.objects") as mock_event_mgr,
        patch("veditor.webhooks.process_talk_approved") as mock_task,
    ):
        mock_settings.VEDITOR_WEBHOOK_SECRET = global_secret
        mock_event_mgr.filter.return_value.first.return_value = mock_event

        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        assert mock_task.delay.called


def test_webhook_view_celery_dispatch_failure_returns_500(rf, webhook_secret):
    payload = {
        "event": "talk.approved",
        "talk_id": 101,
        "event_id": 42,
        "timestamp": time.time(),
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings, patch("veditor.webhooks.process_talk_approved") as mock_task:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        mock_task.delay.side_effect = Exception("Celery Redis broker offline")

        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 500
        data = json.loads(response.content.decode("utf-8"))
        assert "Failed to enqueue task" in data["error"]


def test_webhook_view_payload_without_event_key_succeeds(rf, webhook_secret):
    payload = {
        "talk_id": 101,
        "event_id": 42,
        "timestamp": time.time(),
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings, patch("veditor.webhooks.process_talk_approved") as mock_task:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret

        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        data = json.loads(response.content.decode("utf-8"))
        assert data["status"] == "accepted"
        mock_task.delay.assert_called_once_with(
            event_id=42,
            talk_id=101,
            external_id=None,
            raw_payload=payload,
        )


def test_webhook_view_method_not_allowed(rf):
    view = WebhookView.as_view()
    req_get = rf.get(reverse("plugins:veditor:webhook"))
    res_get = view(req_get)
    assert res_get.status_code == 405

    req_delete = rf.delete(reverse("plugins:veditor:webhook"))
    res_delete = view(req_delete)
    assert res_delete.status_code == 405


def test_tasks_process_talk_approved():
    with (
        patch("veditor.tasks.Event.objects.filter") as mock_event_filter,
        patch("veditor.tasks.Submission.objects.filter") as mock_sub_filter,
        patch("veditor.tasks.TalkSlot.objects.filter") as mock_slot_filter,
    ):
        mock_event_filter.return_value.first.return_value = SimpleNamespace(id=1, slug="event-1")
        mock_sub_filter.return_value.first.return_value = None
        mock_slot_filter.return_value.select_related.return_value.first.return_value = None
        result = process_talk_approved(event_id=1, talk_id=99, external_id="EXT-1")
    assert result["status"] == "error"
    assert result["error"] == "Submission not found"
    assert result["external_id"] == "EXT-1"
