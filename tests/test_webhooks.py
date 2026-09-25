"""Unit and integration tests for the VEditor inbound webhook receiver."""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from django.test import RequestFactory
from django.urls import reverse

from veditor.tasks import process_talk_approved, process_talk_published
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


def test_verify_hmac_signature_v1_scheme_with_whitespace(webhook_secret):
    body = b'{"talk_id": 42, "event_id": 10}'
    now_ts = int(time.time())
    signed_payload = f"{now_ts}.".encode() + body
    v1_sig = hmac.new(webhook_secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
    header = f"t={now_ts}, v1={v1_sig}"
    assert verify_hmac_signature(body, header, webhook_secret) is True

    header_spaces = f" t = {now_ts} , v1 = {v1_sig} "
    assert verify_hmac_signature(body, header_spaces, webhook_secret) is True


def test_verify_hmac_signature_v1_scheme_invalid_sig_no_fallthrough(webhook_secret):
    body = b'{"talk_id": 42, "event_id": 10}'
    now_ts = int(time.time())
    # An invalid v1 signature should be rejected and NOT fall through to raw body HMAC
    header = f"t={now_ts},v1=invalid_hex_signature"
    assert verify_hmac_signature(body, header, webhook_secret) is False


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


def test_webhook_view_event_scoped_secret_with_numeric_slug(rf):
    event_secret = "event-secret-numeric-slug-999"
    global_secret = "global-secret-111"
    # Event slug is '2026' (digits only), while DB id is 42
    payload = {"talk_id": 101, "event_id": "2026", "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(event_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    mock_event = SimpleNamespace(
        id=42,
        slug="2026",
        settings=SimpleNamespace(get=lambda k, d=None: event_secret if k == "veditor_webhook_secret" else d),
    )

    def mock_filter(*args, **kwargs):
        # When filtered by id=2026, return empty queryset
        # When filtered by slug='2026', return mock_event
        if "id" in kwargs:
            return SimpleNamespace(first=lambda: None)
        if "slug" in kwargs and kwargs["slug"] == "2026":
            return SimpleNamespace(first=lambda: mock_event)
        return SimpleNamespace(first=lambda: None)

    with (
        patch("veditor.webhooks.settings") as mock_settings,
        patch.dict("os.environ", {}, clear=True),
        patch("eventyay.base.models.Event.objects") as mock_event_mgr,
        patch("veditor.webhooks.process_talk_approved") as mock_task,
    ):
        mock_settings.VEDITOR_WEBHOOK_SECRET = global_secret
        mock_event_mgr.filter.side_effect = mock_filter

        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        assert mock_task.delay.called


def test_webhook_view_event_lookup_db_error_returns_500(rf, webhook_secret):
    payload = {"talk_id": 101, "event_id": 42, "timestamp": time.time()}
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    from django.db import DatabaseError

    with (
        patch("eventyay.base.models.Event.objects") as mock_event_mgr,
        patch("veditor.webhooks.process_talk_approved") as mock_task,
    ):
        mock_event_mgr.filter.side_effect = DatabaseError("Database connection timeout")

        view = WebhookView.as_view()
        response = view(request)

        # Must return 500 so upstream client retries, rather than falling back and returning 401
        assert response.status_code == 500
        data = json.loads(response.content.decode("utf-8"))
        assert "Database error looking up event secret" in data["error"]
        assert not mock_task.delay.called


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


def test_webhook_view_prioritizes_header_timestamp_for_replay_skew(rf, webhook_secret):
    now_ts = int(time.time())
    expired_ts = now_ts - 500  # 500s ago
    payload = {
        "talk_id": 101,
        "event_id": 42,
        "timestamp": datetime.now(UTC).isoformat(),  # fresh timestamp in body
    }
    body = json.dumps(payload).encode("utf-8")
    signed_payload = f"{expired_ts}.".encode() + body
    v1_sig = hmac.new(webhook_secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
    header = f"t={expired_ts}, v1={v1_sig}"

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=header,
    )

    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        # Must reject because header timestamp is expired, despite body timestamp being fresh
        assert response.status_code == 400
        data = json.loads(response.content.decode("utf-8"))
        assert "timestamp expired" in data["error"]


def test_webhook_view_accepts_integer_zero_talk_and_event_id(rf, webhook_secret):
    payload = {
        "talk_id": 0,
        "event_id": 0,
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
        assert mock_task.delay.called
        mock_task.delay.assert_called_once_with(
            event_id=0,
            talk_id=0,
            external_id=None,
            raw_payload=payload,
        )


def test_webhook_view_non_trailing_slash_url(rf, webhook_secret):
    payload = {
        "talk_id": 101,
        "event_id": 42,
        "timestamp": time.time(),
    }
    body = json.dumps(payload).encode("utf-8")
    sig = generate_signature(webhook_secret, body)

    # Directly hit non-trailing slash path
    request = rf.post(
        "/api/v1/veditor/webhook",
        data=body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE=sig,
    )

    with patch("veditor.webhooks.settings") as mock_settings, patch("veditor.webhooks.process_talk_approved") as mock_task:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        assert mock_task.delay.called


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
    assert result["event_id"] == 1
    assert result["talk_id"] == 99
    assert result["external_id"] == "EXT-1"


def test_webhook_view_talk_published_success(rf, webhook_secret):
    payload = {
        "event": "talk.published",
        "talk_id": 42,
        "event_id": 10,
        "external_id": "ABCDE",
        "video_url": "https://cdn.eventyay.com/talks/ABCDE.mp4",
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

    with patch("veditor.webhooks.settings") as mock_settings, patch("veditor.webhooks.process_talk_published") as mock_task:
        mock_settings.VEDITOR_WEBHOOK_SECRET = webhook_secret
        view = WebhookView.as_view()
        response = view(request)

        assert response.status_code == 200
        assert mock_task.delay.called
        mock_task.delay.assert_called_once_with(
            event_id=10,
            talk_id=42,
            video_url="https://cdn.eventyay.com/talks/ABCDE.mp4",
            external_id="ABCDE",
            raw_payload=payload,
        )


def test_webhook_view_talk_published_missing_video_url(rf, webhook_secret):
    payload = {
        "event": "talk.published",
        "talk_id": 42,
        "event_id": 10,
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
        assert "video_url" in data["error"]


def test_webhook_view_talk_published_empty_video_url(rf, webhook_secret):
    payload = {
        "event": "talk.published",
        "talk_id": 42,
        "event_id": 10,
        "video_url": "   ",
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
        assert "video_url" in data["error"]


def test_tasks_process_talk_published_empty_video_url():
    result = process_talk_published(event_id=1, talk_id=42, video_url="")
    assert result["status"] == "error"
    assert "video_url" in result["message"]


def test_tasks_process_talk_published_invalid_video_url():
    result = process_talk_published(event_id=1, talk_id=42, video_url="javascript:alert(1)")
    assert result["status"] == "error"
    assert "video_url" in result["message"]


def test_tasks_process_talk_published_event_not_found():
    with patch("eventyay.base.models.Event.objects.filter") as mock_event_filter:
        mock_event_filter.return_value.first.return_value = None

        result = process_talk_published(
            event_id="demo",
            talk_id=99,
            external_id="NONEXISTENT",
            video_url="https://example.com/video.mp4",
        )
        assert result["status"] == "not_found"
        assert "Event demo not found" in result["message"]


def test_tasks_process_talk_published_submission_not_found():
    mock_event = MagicMock()
    mock_event.id = 1
    mock_event.submissions.filter.return_value.first.return_value = None

    with (
        patch("eventyay.base.models.Event.objects.filter") as mock_event_filter,
        patch("eventyay.base.models.TalkSlot.objects.filter") as mock_slot_filter,
    ):
        mock_event_filter.return_value.first.return_value = mock_event
        mock_slot_filter.return_value.first.return_value = None
        mock_slot_filter.return_value.select_related.return_value.first.return_value = None

        result = process_talk_published(
            event_id=1,
            talk_id=99,
            external_id="NONEXISTENT",
            video_url="https://example.com/video.mp4",
        )
        assert result["status"] == "not_found"
        assert "Submission not found" in result["message"]


def test_tasks_process_talk_published_submission_do_not_record():
    mock_event = MagicMock()
    mock_event.id = 1

    mock_sub = MagicMock()
    mock_sub.code = "ABC12"
    mock_sub.event_id = 1
    mock_sub.do_not_record = True
    mock_event.submissions.filter.return_value.first.return_value = mock_sub

    with patch("eventyay.base.models.Event.objects.filter") as mock_event_filter:
        mock_event_filter.return_value.first.return_value = mock_event

        result = process_talk_published(
            event_id=1,
            talk_id=99,
            external_id="ABC12",
            video_url="https://example.com/video.mp4",
        )
        assert result["status"] == "skipped"
        assert result["reason"] == "do_not_record"


def test_tasks_process_talk_published_cross_event_rejection():
    mock_event = MagicMock()
    mock_event.id = 1

    mock_sub = MagicMock()
    mock_sub.code = "FOREIGN1"
    mock_sub.event_id = 999  # Different event!
    mock_event.submissions.filter.return_value.first.return_value = mock_sub

    with patch("eventyay.base.models.Event.objects.filter") as mock_event_filter:
        mock_event_filter.return_value.first.return_value = mock_event

        result = process_talk_published(
            event_id=1,
            talk_id=42,
            external_id="FOREIGN1",
            video_url="https://example.com/video.mp4",
        )
        assert result["status"] == "error"
        assert "different event" in result["message"]


def test_tasks_process_talk_published_success_via_external_id():
    mock_event = MagicMock()
    mock_event.id = 1

    mock_sub = MagicMock()
    mock_sub.code = "CONF1"
    mock_sub.event_id = 1
    mock_sub.do_not_record = False
    mock_event.submissions.filter.return_value.first.return_value = mock_sub

    mock_resource = MagicMock()
    mock_resource.id = 555

    with (
        patch("eventyay.base.models.Event.objects.filter") as mock_event_filter,
        patch("eventyay.base.models.Resource.objects.filter") as mock_res_filter,
    ):
        mock_event_filter.return_value.first.return_value = mock_event
        # Existing resource found: update it
        mock_res_filter.return_value.order_by.return_value.first.return_value = mock_resource

        result = process_talk_published(
            event_id=1,
            talk_id=99,
            external_id="CONF1",
            video_url="https://cdn.example.com/video.mp4",
        )
        assert result["status"] == "success"
        assert result["submission_code"] == "CONF1"
        assert result["resource_id"] == 555
        assert result["created"] is False
        assert mock_resource.link == "https://cdn.example.com/video.mp4"
        mock_resource.save.assert_called_once_with(update_fields=["link", "kind"])


def test_tasks_process_talk_published_creates_resource_when_none_exists():
    mock_event = MagicMock()
    mock_event.id = 1

    mock_sub = MagicMock()
    mock_sub.code = "CONF2"
    mock_sub.event_id = 1
    mock_sub.do_not_record = False
    mock_event.submissions.filter.return_value.first.return_value = mock_sub

    mock_new_resource = MagicMock()
    mock_new_resource.id = 777

    with (
        patch("eventyay.base.models.Event.objects.filter") as mock_event_filter,
        patch("eventyay.base.models.Resource.objects.filter") as mock_res_filter,
        patch("eventyay.base.models.Resource.objects.create", return_value=mock_new_resource) as mock_res_create,
    ):
        mock_event_filter.return_value.first.return_value = mock_event
        mock_res_filter.return_value.order_by.return_value.first.return_value = None

        result = process_talk_published(
            event_id=1,
            talk_id=99,
            external_id="CONF2",
            video_url="https://cdn.example.com/video2.mp4",
        )
        assert result["status"] == "success"
        assert result["resource_id"] == 777
        assert result["created"] is True
        mock_res_create.assert_called_once_with(
            submission=mock_sub,
            description="Video Recording",
            link="https://cdn.example.com/video2.mp4",
            kind="generic",
        )


def test_webhook_view_ping_success(rf, webhook_secret):
    payload = {
        "event": "ping",
        "event_id": 10,
        "timestamp": time.time(),
        "message": "test ping",
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

        assert response.status_code == 200
        data = json.loads(response.content.decode("utf-8"))
        assert data["status"] == "pong"


def test_webhook_view_talk_published_missing_external_id(rf, webhook_secret):
    payload = {
        "event": "talk.published",
        "talk_id": 42,
        "event_id": 10,
        "video_url": "https://cdn.eventyay.com/talks/ABCDE.mp4",
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
        assert "external_id" in data["error"]


def test_webhook_view_talk_published_invalid_video_url_scheme(rf, webhook_secret):
    payload = {
        "event": "talk.published",
        "talk_id": 42,
        "event_id": 10,
        "external_id": "ABCDE",
        "video_url": "javascript:alert(1)",
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
        assert "video_url must be a valid HTTP or HTTPS URL" in data["error"]
