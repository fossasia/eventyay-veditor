"""Privacy and fail-open behavior of plugin operational logs."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

import veditor.operational_log as operational_log
from veditor.client import VEditorClient
from veditor.exceptions import VEditorError
from veditor.operational_log import (
    OUTCOME_FAILURE,
    OUTCOME_SUCCESS,
    log_operation,
    traced_job,
)


@pytest.fixture
def captured(monkeypatch):
    records = []

    def fake_log(level, action, extra=None):
        records.append((level, action, extra or {}))

    monkeypatch.setattr(logging.getLogger("eventyay.plugins"), "log", fake_log)
    monkeypatch.setattr(operational_log, "_HOST_LOG_EVENT", None)
    monkeypatch.setattr(operational_log, "_host_bind_job_id", None)
    monkeypatch.setattr(operational_log, "_host_get_job_id", None)
    monkeypatch.setattr(operational_log, "_host_reset_job_id", None)
    return records


def test_drops_email_token_and_unknown_fields(captured):
    log_operation(
        "plugin.loaded",
        OUTCOME_SUCCESS,
        backend="veditor",
        email="person@example.com",
        token="secret-token",
        body="{raw}",
        event_id=12,
        object_id="TALK-1",
    )
    assert len(captured) == 1
    extra = captured[0][2]
    assert extra["backend"] == "veditor"
    assert extra["event_id"] == 12
    assert extra["object_id"] == "TALK-1"
    assert extra["outcome"] == "success"
    assert "email" not in extra
    assert "token" not in extra
    assert "body" not in extra
    blob = str(extra)
    assert "person@example.com" not in blob
    assert "secret-token" not in blob


def test_accepts_safe_string_event_id_and_rejects_unsafe(captured):
    log_operation("schedule.sync", OUTCOME_SUCCESS, backend="veditor", event_id="fossasia-2026")
    log_operation("schedule.sync", OUTCOME_FAILURE, backend="veditor", event_id="has space@bad")
    assert len(captured) == 2
    assert captured[0][2]["event_id"] == "fossasia-2026"
    assert "event_id" not in captured[1][2]


def test_rejects_unsafe_action_and_backend(captured):
    log_operation("has space", OUTCOME_SUCCESS, backend="veditor")
    log_operation("connection.request", OUTCOME_FAILURE, backend="pay pal", error_code="not safe")
    assert len(captured) == 1
    assert captured[0][1] == "connection.request"
    assert "backend" not in captured[0][2]
    assert "error_code" not in captured[0][2]


def test_host_emitter_failure_falls_back_to_plugin_logger(monkeypatch):
    records = []

    def boom(*args, **kwargs):
        raise RuntimeError("host emitter down")

    def fake_log(level, action, extra=None):
        records.append((level, action, extra or {}))

    monkeypatch.setattr(operational_log, "_HOST_LOG_EVENT", boom)
    monkeypatch.setattr(logging.getLogger("eventyay.plugins"), "log", fake_log)

    log_operation("plugin.loaded", OUTCOME_SUCCESS, backend="veditor")
    assert len(records) == 1
    assert records[0][1] == "plugin.loaded"
    assert records[0][2]["backend"] == "veditor"


def test_logging_failure_is_swallowed(monkeypatch):
    def boom(*args, **kwargs):
        raise RuntimeError("log sink down")

    monkeypatch.setattr(operational_log, "_HOST_LOG_EVENT", boom)
    monkeypatch.setattr(logging.getLogger("eventyay.plugins"), "log", boom)
    log_operation("plugin.loaded", OUTCOME_SUCCESS, backend="veditor")


def test_client_request_records_status_without_url_or_secrets(captured):
    response = SimpleNamespace(status_code=201, text='{"ok": true}', json=lambda: {"ok": True})
    session = MagicMock()
    session.headers = {}
    session.request.return_value = response

    client = VEditorClient(
        base_url="https://veditor.example.invalid",
        api_key="super-secret-api-key",
        session=session,
        event=SimpleNamespace(id=42),
    )
    client._request("POST", "/talks", json={"token": "raw-token"})

    assert captured[-1][1] == "connection.request"
    extra = captured[-1][2]
    assert extra["status"] == 201
    assert extra["outcome"] == "success"
    assert extra["event_id"] == 42
    assert isinstance(extra["duration_ms"], int)
    blob = str(extra)
    assert "example.invalid" not in blob
    assert "super-secret-api-key" not in blob
    assert "raw-token" not in blob


class _NetError(Exception):
    pass


class _Task:
    def __init__(self, retries, limit, job_id="job-123"):
        self.request = type("Request", (), {"retries": retries, "id": job_id})()
        self.max_retries = limit
        self.autoretry_for = (_NetError,)


def test_traced_job_records_ids_duration_and_job_id_correlation(captured):
    @traced_job("veditor.talk_published")
    def work(self, event_id=None, talk_id=None):
        log_operation("connection.request", OUTCOME_SUCCESS, backend="veditor", status=200)
        return "ok"

    assert work(_Task(retries=0, limit=3, job_id="celery-abc-1"), event_id=77, talk_id="TALK-9") == "ok"
    assert [item[1] for item in captured] == ["job.start", "connection.request", "job.finish"]
    start_extra = captured[0][2]
    inner_extra = captured[1][2]
    finish_extra = captured[2][2]
    assert start_extra["event_id"] == 77
    assert start_extra["object_id"] == "TALK-9"
    assert start_extra["job_id"] == "celery-abc-1"
    assert inner_extra["job_id"] == "celery-abc-1"
    assert finish_extra["event_id"] == 77
    assert finish_extra["object_id"] == "TALK-9"
    assert finish_extra["job_id"] == "celery-abc-1"
    assert isinstance(finish_extra["duration_ms"], int)


def test_traced_job_ignores_non_task_first_argument(captured):
    @traced_job("veditor.talk_published")
    def work(event_id, talk_id):
        raise _NetError("boom")

    with pytest.raises(_NetError):
        work("my-event", "TALK-2")

    assert [item[1] for item in captured] == ["job.start", "job.fail"]
    assert captured[0][2]["event_id"] == "my-event"
    assert captured[0][2]["object_id"] == "TALK-2"
    assert captured[1][2]["error_code"] == "_NetError"
    assert isinstance(captured[1][2]["duration_ms"], int)


def test_autoretry_is_logged_as_retry_while_retries_remain(captured):
    @traced_job("veditor.talk_approved")
    def work(self):
        raise _NetError()

    with pytest.raises(_NetError):
        work(_Task(retries=0, limit=3))

    assert [item[1] for item in captured] == ["job.start", "job.retry"]


def test_autoretry_is_logged_as_retry_when_max_retries_is_none(captured):
    @traced_job("veditor.talk_approved")
    def work(self):
        raise _NetError()

    with pytest.raises(_NetError):
        work(_Task(retries=10, limit=None))

    assert [item[1] for item in captured] == ["job.start", "job.retry"]


def test_autoretry_is_logged_as_fail_when_retries_are_spent(captured):
    @traced_job("veditor.talk_approved")
    def work(self):
        raise _NetError()

    with pytest.raises(_NetError):
        work(_Task(retries=3, limit=3))

    assert [item[1] for item in captured] == ["job.start", "job.fail"]


def test_webhook_logs_failure_on_post_signature_rejection_and_success_only_when_accepted(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.test import RequestFactory

    from veditor.webhooks import WebhookView

    rf = RequestFactory()
    secret = "whsec-test-secret"

    def signed_request(payload):
        body = json.dumps(payload).encode("utf-8")
        sig = "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
        return rf.post(
            "/api/v1/veditor/webhook/",
            data=body,
            content_type="application/json",
            HTTP_X_VEDITOR_SIGNATURE=sig,
        )

    view = WebhookView.as_view()

    # 1. Signed request that fails validation (protocol-relative video_url) must emit ONLY failure.
    bad_payload = {
        "event": "talk.published",
        "event_id": 15,
        "talk_id": 99,
        "external_id": "TALK-99",
        "video_url": "//evil.invalid/video.mp4",
        "timestamp": time.time(),
    }
    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = secret
        response = view(signed_request(bad_payload))

    assert response.status_code == 400
    assert len(captured) == 1
    assert captured[0][1] == "webhook.inbound"
    assert captured[0][2]["outcome"] == "failure"
    assert captured[0][2]["error_code"] == "invalid_video_url"
    assert captured[0][2]["event_id"] == 15
    assert captured[0][2]["object_id"] == 99

    captured.clear()

    # 2. Valid signed request emits success only after enqueue succeeds.
    good_payload = {
        "event": "talk.approved",
        "event_id": 15,
        "talk_id": 99,
        "external_id": "TALK-99",
        "timestamp": time.time(),
    }
    with (
        patch("veditor.webhooks.settings") as mock_settings,
        patch("veditor.webhooks.process_talk_approved") as mock_task,
    ):
        mock_settings.VEDITOR_WEBHOOK_SECRET = secret
        response = view(signed_request(good_payload))

    assert response.status_code == 200
    assert mock_task.delay.called
    assert len(captured) == 1
    assert captured[0][1] == "webhook.inbound"
    assert captured[0][2]["outcome"] == "success"
    assert captured[0][2]["event_id"] == 15
    assert captured[0][2]["object_id"] == 99
    assert captured[0][2]["status"] == 200


def test_app_ready_logs_plugin_loaded_after_registration(captured, monkeypatch):
    import sys

    from veditor.apps import VeditorApp

    events = []
    monkeypatch.setattr(
        "veditor.apps.log_plugin_loaded",
        lambda backend: events.append(("loaded", backend)),
    )

    fake_signals = type(sys)("veditor.signals")
    fake_tasks = type(sys)("veditor.tasks")
    monkeypatch.setitem(sys.modules, "veditor.signals", fake_signals)
    monkeypatch.setitem(sys.modules, "veditor.tasks", fake_tasks)

    app_cfg = VeditorApp.__new__(VeditorApp)
    app_cfg.ready()
    assert events == [("loaded", "veditor")]


def test_connect_view_resend_logs_review_link_dispatch(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.contrib.messages.storage.fallback import FallbackStorage
    from django.http import HttpResponseRedirect
    from django.test import RequestFactory

    from veditor.views import ConnectView

    rf = RequestFactory()
    event = SimpleNamespace(
        id=42,
        slug="conf-42",
        organizer=SimpleNamespace(slug="org-42"),
        settings=SimpleNamespace(get=lambda k, d=None: d),
    )
    user = MagicMock()
    user.is_authenticated = True
    user.pk = 7
    user.has_event_permission.return_value = True

    def make_request(data):
        req = rf.post("/common/event/org-42/conf-42/veditor/", data=data)
        req.user = user
        req.event = event
        req.organizer = event.organizer
        req.session = {}
        req._messages = FallbackStorage(req)
        return req

    view = ConnectView()

    with (
        patch("veditor.views.reverse", return_value="/common/event/org-42/conf-42/veditor/"),
        patch("veditor.views.redirect", side_effect=HttpResponseRedirect),
    ):
        resp1 = view.post(make_request({"action": "resend_speaker_link"}))
        assert resp1.status_code == 302
        assert captured[-1][1] == "review_link.dispatch"
        assert captured[-1][2]["outcome"] == "failure"
        assert captured[-1][2]["error_code"] == "missing_talk"
        assert captured[-1][2]["event_id"] == 42
        assert captured[-1][2]["user_id"] == 7

        captured.clear()
        with patch("veditor.views.process_talk_approved.delay") as mock_delay:
            resp2 = view.post(make_request({"action": "resend_speaker_link", "talk_id": "101"}))
        assert resp2.status_code == 302
        assert mock_delay.called
        assert captured[-1][1] == "review_link.dispatch"
        assert captured[-1][2]["outcome"] == "success"
        assert captured[-1][2]["event_id"] == 42
        assert captured[-1][2]["object_id"] == "101"
        assert captured[-1][2]["user_id"] == 7


def test_speaker_review_launch_view_logs_permission_denied_and_success(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.core.exceptions import PermissionDenied
    from django.test import RequestFactory

    from veditor.views import SpeakerReviewLaunchView

    rf = RequestFactory()
    event = SimpleNamespace(
        id=42,
        slug="conf-42",
        organizer=SimpleNamespace(slug="org-42"),
        settings=SimpleNamespace(get=lambda k, d=None: d),
    )
    submission = SimpleNamespace(
        code="TALK-42",
        state="confirmed",
        speakers=SimpleNamespace(all=lambda: [SimpleNamespace(email="speaker@example.com")]),
        slots=SimpleNamespace(first=lambda: None),
    )

    view = SpeakerReviewLaunchView()

    # Unauthorized user -> permission.denied
    bad_user = MagicMock()
    bad_user.is_authenticated = True
    bad_user.pk = 88
    bad_user.email = "intruder@example.com"
    bad_user.has_event_permission.return_value = False

    req1 = rf.get("/common/event/org-42/conf-42/veditor/talk/TALK-42/review/")
    req1.user = bad_user
    req1.event = event
    req1.submission = submission
    with pytest.raises(PermissionDenied):
        view.get(req1, organizer="org-42", event="conf-42", talk_code="TALK-42")
    assert captured[-1][1] == "permission.denied"
    assert captured[-1][2]["outcome"] == "failure"
    assert captured[-1][2]["event_id"] == 42
    assert captured[-1][2]["object_id"] == "TALK-42"
    assert captured[-1][2]["user_id"] == 88

    captured.clear()

    # Authorized speaker -> review_link.launch success without leaking email/token
    good_user = MagicMock()
    good_user.is_authenticated = True
    good_user.pk = 12
    good_user.email = "speaker@example.com"
    good_user.fullname = "Speaker Name"
    good_user.has_event_permission.return_value = False

    req2 = rf.get("/common/event/org-42/conf-42/veditor/talk/TALK-42/review/")
    req2.user = good_user
    req2.event = event
    req2.submission = submission

    mock_client = MagicMock()
    mock_client.base_url = "https://veditor.example.invalid"
    mock_client.get_scoped_event_id.return_value = 42
    mock_client.request_sso_jwt.return_value = ("secret-jwt-token", {"url": "/studio/talks/TALK-42?sso_token=secret-jwt-token"})

    with patch("veditor.views.VEditorClient", return_value=mock_client):
        resp = view.get(req2, organizer="org-42", event="conf-42", talk_code="TALK-42")

    assert resp.status_code == 302
    assert captured[-1][1] == "review_link.launch"
    assert captured[-1][2]["outcome"] == "success"
    assert captured[-1][2]["event_id"] == 42
    assert captured[-1][2]["object_id"] == "TALK-42"
    assert captured[-1][2]["user_id"] == 12
    blob = str(captured[-1][2])
    assert "speaker@example.com" not in blob
    assert "secret-jwt-token" not in blob
    assert "Speaker Name" not in blob


def test_request_id_correlation_in_fallback_logger(captured, monkeypatch):
    token = operational_log._request_id.set("req-abc-123")
    try:
        log_operation("connection.request", OUTCOME_SUCCESS, backend="veditor")
    finally:
        operational_log._request_id.reset(token)

    assert captured[-1][2]["request_id"] == "req-abc-123"

    monkeypatch.setattr(operational_log, "_host_get_request_id", lambda: "host-req-456")
    log_operation("connection.request", OUTCOME_SUCCESS, backend="veditor")
    assert captured[-1][2]["request_id"] == "host-req-456"


def test_traced_job_logs_returned_error_status_as_failure(captured):
    @traced_job("veditor.talk_published")
    def work(event_id=None, talk_id=None):
        return {"status": "error", "message": "raw secret details"}

    res = work(event_id=7, talk_id="TALK-7")
    assert res == {"status": "error", "message": "raw secret details"}
    assert [item[1] for item in captured] == ["job.start", "job.finish"]
    finish_extra = captured[1][2]
    assert finish_extra["outcome"] == "failure"
    assert finish_extra["error_code"] == "task_error"
    assert "raw secret details" not in str(finish_extra)


def test_client_request_treats_redirect_as_failure(captured):
    response = SimpleNamespace(status_code=302, text="Found", json=lambda: {})
    session = MagicMock()
    session.headers = {}
    session.request.return_value = response

    client = VEditorClient(
        base_url="https://veditor.example.invalid",
        api_key="super-secret-api-key",
        session=session,
        event=SimpleNamespace(id=42),
    )
    with pytest.raises(VEditorError):
        client._request("GET", "/events")

    assert captured[-1][1] == "connection.request"
    assert captured[-1][2]["outcome"] == "failure"
    assert captured[-1][2]["status"] == 302
    assert captured[-1][2]["error_code"] == "http_error"


def test_webhook_does_not_log_unvalidated_identifiers_before_hmac(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.test import RequestFactory

    from veditor.webhooks import WebhookView

    rf = RequestFactory()
    view = WebhookView.as_view()

    # 1. Pre-auth missing_timestamp with PII-like talk_id must NOT log event_id or object_id
    payload = {
        "event": "talk.approved",
        "event_id": 999,
        "talk_id": "Alice.Smith",
    }
    req = rf.post(
        "/api/v1/veditor/webhook/",
        data=json.dumps(payload).encode("utf-8"),
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE="sha256=deadbeef",
    )
    resp = view(req)
    assert resp.status_code == 400
    assert len(captured) == 1
    assert captured[0][2]["error_code"] == "missing_timestamp"
    assert "event_id" not in captured[0][2]
    assert "object_id" not in captured[0][2]
    assert "Alice.Smith" not in str(captured[0][2])

    captured.clear()

    # 2. Pre-auth signature_invalid must NOT log event_id or object_id
    payload2 = {
        "event": "talk.approved",
        "event_id": 999,
        "talk_id": "Alice.Smith",
        "timestamp": time.time(),
    }
    req2 = rf.post(
        "/api/v1/veditor/webhook/",
        data=json.dumps(payload2).encode("utf-8"),
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE="sha256=deadbeef",
    )
    with patch("veditor.webhooks.settings") as mock_settings:
        mock_settings.VEDITOR_WEBHOOK_SECRET = "whsec-real"
        resp2 = view(req2)
    assert resp2.status_code == 401
    assert len(captured) == 1
    assert captured[0][2]["error_code"] == "signature_invalid"
    assert "event_id" not in captured[0][2]
    assert "object_id" not in captured[0][2]
    assert "Alice.Smith" not in str(captured[0][2])


def test_connect_view_as_view_logs_authenticated_permission_denied_only(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.core.exceptions import PermissionDenied
    from django.test import RequestFactory

    from veditor.views import ConnectView

    rf = RequestFactory()
    view_fn = ConnectView.as_view()
    event = SimpleNamespace(id=42, slug="conf-42", organizer=SimpleNamespace(slug="org-42"))

    # Authenticated without permission -> logs permission.denied
    auth_user = MagicMock()
    auth_user.is_authenticated = True
    auth_user.pk = 77
    auth_user.has_event_permission.return_value = False
    req1 = rf.get("/common/event/org-42/conf-42/veditor/")
    req1.user = auth_user
    req1.event = event
    req1.organizer = event.organizer

    with pytest.raises(PermissionDenied):
        view_fn(req1)

    assert len(captured) == 1
    assert captured[0][1] == "permission.denied"
    assert captured[0][2]["outcome"] == "failure"
    assert captured[0][2]["error_code"] == "forbidden"
    assert captured[0][2]["event_id"] == 42
    assert captured[0][2]["user_id"] == 77

    captured.clear()

    # Anonymous user -> raises PermissionDenied without emitting permission.denied
    anon_user = SimpleNamespace(is_authenticated=False)
    req2 = rf.get("/common/event/org-42/conf-42/veditor/")
    req2.user = anon_user
    req2.event = event
    req2.organizer = event.organizer

    with pytest.raises(PermissionDenied):
        view_fn(req2)

    assert captured == []


def test_connect_view_sync_dispatch_zero_sent_with_failed_logs_failure(captured):
    django = pytest.importorskip("django")
    assert django is not None
    from django.contrib.messages.storage.fallback import FallbackStorage
    from django.http import HttpResponseRedirect
    from django.test import RequestFactory

    from veditor.views import ConnectView

    rf = RequestFactory()
    event = SimpleNamespace(
        id=42,
        slug="conf-42",
        organizer=SimpleNamespace(slug="org-42"),
        settings=SimpleNamespace(get=lambda k, d=None: d),
    )
    user = MagicMock()
    user.is_authenticated = True
    user.pk = 7

    req = rf.post(
        "/common/event/org-42/conf-42/veditor/",
        data={"action": "resend_speaker_link", "talk_id": "101"},
    )
    req.user = user
    req.event = event
    req.organizer = event.organizer
    req.session = {}
    req._messages = FallbackStorage(req)

    view = ConnectView()
    failed_result = {
        "status": "skipped",
        "sent_count": 0,
        "failed": [{"speaker": "NoEmail", "error": "missing_email"}],
    }
    mock_task = MagicMock(return_value=failed_result)
    mock_task.delay.side_effect = RuntimeError("celery down")
    with (
        patch("veditor.views.reverse", return_value="/common/event/org-42/conf-42/veditor/"),
        patch("veditor.views.redirect", side_effect=HttpResponseRedirect),
        patch("veditor.views.process_talk_approved", mock_task),
    ):
        resp = view.post(req)

    assert resp.status_code == 302
    assert captured[-1][1] == "review_link.dispatch"
    assert captured[-1][2]["outcome"] == "failure"
    assert captured[-1][2]["error_code"] == "dispatch_failed"
