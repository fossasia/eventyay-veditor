"""End-to-end integration tests for the Eventyay VEditor plugin lifecycle.

Exercises the complete user journey across:
1. Organiser Handoff & Schedule Synchronization (ConnectView -> Mock VEditor with UTC normalization & valid JWT)
2. Talk Approval & Speaker Email Dispatch (VEditor Webhook -> Eager Celery -> Django Mail Outbox)
3. Media Published & Public Schedule Rendering (VEditor Webhook -> Eager Celery -> Resource -> Recording Provider)
4. Privacy Filters (do_not_record) respected end-to-end
5. Multi-Speaker Magic Links with distinct tokens
6. Webhook Security & Tampering Rejection
7. Mock VEditor /events/{id}/talks/bulk endpoint validation
"""

from __future__ import annotations

import json
import time
import urllib.parse
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from django.contrib.messages.storage.fallback import FallbackStorage
from django.contrib.sessions.middleware import SessionMiddleware
from django.core import mail
from django.core.cache import cache
from django.test import RequestFactory, override_settings
from django.urls import reverse
from django.utils.timezone import now
from django_scopes import scope, scopes_disabled
from eventyay.base.models import Event, Organizer, Resource, Room, Schedule, Submission, SubmissionType, TalkSlot, Team, User

from tests.mock_veditor import validate_jwt_structure
from veditor.recording import VEditorRecordingProvider
from veditor.views import ConnectView
from veditor.webhooks import WebhookView


def setup_request(request):
    """Attach session and messages storage to a RequestFactory request."""
    middleware = SessionMiddleware(lambda req: None)
    middleware.process_request(request)
    request.session.save()
    request._messages = FallbackStorage(request)
    return request


@pytest.fixture
def integrated_event(db):
    """Real Event model instance created in the test database with VEditor credentials."""
    with scopes_disabled():
        organizer = Organizer.objects.create(name="FOSSASIA Org", slug="fossasia-org")
        event = Event.objects.create(
            organizer=organizer,
            name="FOSSASIA Summit 2026",
            slug="summit-2026",
            date_from=now(),
            plugins="veditor",
            live=True,
            timezone="Asia/Singapore",
        )
        event.settings.set("veditor_api_key", "test-veditor-api-key-12345")
        event.settings.set("veditor_api_base_url", "http://localhost:8080")
        event.settings.set("veditor_webhook_secret", "test-webhook-secret-999")
        event.settings.set("mail_from", "notifications@eventyay.com")

        # Create organiser user with full event settings permissions via Team
        org_user = User.objects.create_user(
            email="organizer@example.org",
            password="secretpassword123",
            fullname="Organizer Name",
        )
        team = Team.objects.create(
            organizer=organizer,
            name="Admins",
            all_events=True,
            can_change_event_settings=True,
        )
        team.members.add(org_user)
        event.organizer_user = org_user

        # Create speaker user
        speaker_user = User.objects.create_user(
            email="alice@example.org",
            password="secretpassword123",
            fullname="Alice Speaker",
        )
        event.speaker_user = speaker_user

        # Ensure submission type
        sub_type = SubmissionType.objects.filter(event=event).first()
        if not sub_type:
            sub_type = SubmissionType.objects.create(event=event, name="Keynote")
        event.default_sub_type = sub_type

    return event


@pytest.fixture
def integrated_talk(integrated_event):
    """Real Submission, Room, and TalkSlot created in the test database."""
    event = integrated_event
    with scope(event=event):
        room = Room.objects.create(event=event, name="Auditorium Main")
        submission = Submission.objects.create(
            event=event,
            code="TALK101",
            title="Keynote: Open Source AI",
            submission_type=event.default_sub_type,
            do_not_record=False,
        )
        submission.speakers.add(event.speaker_user)

        schedule = getattr(event, "wip_schedule", None) or Schedule.objects.create(event=event, version="1.0")

        # Localized time in Asia/Singapore (UTC+8): 17:00:00 -> 09:00:00 UTC
        tz_singapore = ZoneInfo("Asia/Singapore")
        start_dt = datetime(2026, 9, 28, 17, 0, 0, tzinfo=tz_singapore)
        end_dt = datetime(2026, 9, 28, 17, 45, 0, tzinfo=tz_singapore)

        slot = TalkSlot.objects.create(
            submission=submission,
            room=room,
            schedule=schedule,
            is_visible=True,
            start=start_dt,
            end=end_dt,
        )

    return SimpleNamespace(
        submission=submission,
        slot=slot,
        room=room,
        schedule=schedule,
        speakers=[event.speaker_user],
    )


# ============================================================================
# Scenario A: Organiser Handoff & Talk Sync with UTC Normalization & Valid JWT
# ============================================================================


def test_integration_scenario_a_organiser_handoff(mock_veditor, integrated_event, integrated_talk):
    """Verify organizer handoff: syncs schedule to VEditor, asserts UTC normalization, and redirects with valid JWT."""
    rf = RequestFactory()

    mock_veditor.events_list = [
        {
            "id": integrated_event.id,
            "external_id": integrated_event.slug,
            "name": integrated_event.name,
        }
    ]

    request = rf.post(
        reverse(
            "plugins:veditor:connect",
            kwargs={
                "organizer": integrated_event.organizer.slug,
                "event": integrated_event.slug,
            },
        ),
        data={"action": "sync"},
    )
    request.user = integrated_event.organizer_user
    request.event = integrated_event
    request.organizer = integrated_event.organizer
    setup_request(request)

    view = ConnectView.as_view()
    response = view(
        request,
        organizer=integrated_event.organizer.slug,
        event=integrated_event.slug,
    )

    # 1. Assert VEditor received talk synchronization payload
    assert len(mock_veditor.imported_schedules) == 1
    import_payload = mock_veditor.imported_schedules[0]
    assert import_payload["event_id"] == integrated_event.id
    assert len(import_payload["talks"]) == 1

    synced_talk = import_payload["talks"][0]
    assert synced_talk["external_id"] == "TALK101"
    assert synced_talk["title"] == "Keynote: Open Source AI"
    assert synced_talk["room"] == "Auditorium Main"

    # Explicitly assert UTC normalization on talk start/end times
    # Local input: 2026-09-28 17:00:00+08:00 (Asia/Singapore) -> Normalized UTC: 2026-09-28T09:00:00+00:00
    assert "+00:00" in synced_talk["start"] or synced_talk["start"].endswith("Z")
    assert synced_talk["start"] in ("2026-09-28T09:00:00+00:00", "2026-09-28T09:00:00Z")
    assert "+00:00" in synced_talk["end"] or synced_talk["end"].endswith("Z")
    assert synced_talk["end"] in ("2026-09-28T09:45:00+00:00", "2026-09-28T09:45:00Z")

    # 2. Assert SSO Token was requested for organizer
    assert len(mock_veditor.sso_token_requests) == 1
    sso_req = mock_veditor.sso_token_requests[0]
    assert sso_req["endpoint"] == "event"
    assert sso_req["body"]["role"] == "organizer"

    # 3. Assert HTTP 302 Redirect to VEditor with valid JWT parameter
    assert response.status_code == 302
    parsed_redirect = urllib.parse.urlparse(response.url)
    assert parsed_redirect.scheme == "http"
    assert parsed_redirect.netloc == "localhost:8080"
    assert parsed_redirect.path == "/studio"

    query_params = urllib.parse.parse_qs(parsed_redirect.query)
    assert "event_id" in query_params
    assert query_params["event_id"][0] == str(integrated_event.id)
    assert "sso_token" in query_params

    # Explicitly validate JWT structure and claims
    token = query_params["sso_token"][0]
    header, payload = validate_jwt_structure(token, secret=mock_veditor.jwt_secret)
    assert header["typ"] == "JWT"
    assert header["alg"] == "HS256"
    assert payload["role"] == "organizer"
    assert str(payload["event_id"]) == str(integrated_event.id)
    assert "exp" in payload
    assert "iat" in payload


# ============================================================================
# Scenario B: Approval Webhook & Speaker Email Dispatch (Eager Celery)
# ============================================================================


@override_settings(CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)
def test_integration_scenario_b_talk_approved_email_dispatch(mock_veditor, integrated_event, integrated_talk):
    """Verify talk.approved webhook: validates HMAC, executes eager Celery inline, and delivers speaker review mail."""
    cache.clear()
    mail.outbox.clear()
    rf = RequestFactory()

    submission = integrated_talk.submission
    speaker = integrated_talk.speakers[0]

    payload = {
        "event": "talk.approved",
        "talk_id": 55,
        "event_id": integrated_event.id,
        "external_id": submission.code,
        "timestamp": time.time(),
    }

    # Step 1: Webhook ingestion triggers Celery inline via CELERY_TASK_ALWAYS_EAGER
    response = mock_veditor.emit_webhook(
        rf,
        event="talk.approved",
        payload_data=payload,
        use_request_factory=True,
    )
    assert response.status_code == 200
    data = json.loads(response.content.decode("utf-8"))
    assert data["status"] == "accepted"

    # Step 2: Verify speaker email was dispatched to Django mail outbox
    assert len(mail.outbox) == 1
    sent_mail = mail.outbox[0]
    assert speaker.email in sent_mail.to
    assert submission.title in sent_mail.subject

    # Step 3: Verify email body contains valid magic link with valid speaker JWT
    assert "http://localhost:8080/studio/talks/55?sso_token=" in sent_mail.body
    parsed_magic_url = urllib.parse.urlparse(sent_mail.body.split("http://localhost:8080/studio/talks/")[1].split()[0])
    token_str = urllib.parse.parse_qs(parsed_magic_url.query)["sso_token"][0]

    header, token_payload = validate_jwt_structure(token_str, secret=mock_veditor.jwt_secret)
    assert header["typ"] == "JWT"
    assert token_payload["role"] == "speaker"
    assert str(token_payload["talk_id"]) == "55"


# ============================================================================
# Scenario C: Published Webhook & Public Schedule Playback (Eager Celery)
# ============================================================================


@override_settings(CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)
def test_integration_scenario_c_talk_published_public_schedule(mock_veditor, integrated_event, integrated_talk):
    """Verify talk.published webhook: updates Resource in test DB via eager Celery and renders video on public schedule."""
    rf = RequestFactory()
    submission = integrated_talk.submission

    video_url = "https://cdn.example.org/videos/keynote-open-source-ai.mp4"
    payload = {
        "event": "talk.published",
        "talk_id": 55,
        "event_id": integrated_event.id,
        "external_id": submission.code,
        "video_url": video_url,
        "timestamp": time.time(),
    }

    # Step 1: Ingest webhook and execute Celery worker inline
    response = mock_veditor.emit_webhook(
        rf,
        event="talk.published",
        payload_data=payload,
        use_request_factory=True,
    )
    assert response.status_code == 200
    data = json.loads(response.content.decode("utf-8"))
    assert data["status"] == "accepted"

    # Step 2: Assert Resource was created in the real database
    with scope(event=integrated_event):
        resource = Resource.objects.filter(submission=submission, link=video_url).first()
        assert resource is not None
        assert resource.description == "Video Recording"
        assert resource.kind == "generic"

    # Step 3: Public schedule recording provider renders the updated resource
    with scope(event=integrated_event):
        submission.refresh_from_db()
        provider = VEditorRecordingProvider(integrated_event)
        recording_output = provider.get_recording(submission)
        assert "iframe" in recording_output
        assert "csp_header" in recording_output
        assert f'src="{video_url}"' in recording_output["iframe"]
        assert "<video controls" in recording_output["iframe"]
        assert recording_output["csp_header"] == "https://cdn.example.org"


# ============================================================================
# Scenario D: Privacy Opt-Out (do_not_record) Respected
# ============================================================================


@override_settings(CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)
def test_integration_scenario_d_privacy_opt_out_respected(mock_veditor, integrated_event, integrated_talk):
    """Verify speaker privacy: do_not_record skips attachment and hides player from public schedule."""
    rf = RequestFactory()
    submission = integrated_talk.submission

    with scope(event=integrated_event):
        submission.do_not_record = True
        submission.save(update_fields=["do_not_record"])

    video_url = "https://cdn.example.org/videos/private-session.mp4"
    payload = {
        "event": "talk.published",
        "talk_id": 99,
        "event_id": integrated_event.id,
        "external_id": submission.code,
        "video_url": video_url,
        "timestamp": time.time(),
    }

    response = mock_veditor.emit_webhook(
        rf,
        event="talk.published",
        payload_data=payload,
        use_request_factory=True,
    )
    assert response.status_code == 200

    # Resource should not be created in DB
    with scope(event=integrated_event):
        assert not Resource.objects.filter(submission=submission, link=video_url).exists()

        # Public schedule must remain completely blank
        submission.refresh_from_db()
        provider = VEditorRecordingProvider(integrated_event)
        assert provider.get_recording(submission) == {}


# ============================================================================
# Scenario E: Multi-Speaker Magic Links with Distinct Tokens
# ============================================================================


@override_settings(CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)
def test_integration_scenario_e_multi_speaker_distinct_magic_links(mock_veditor, integrated_event, integrated_talk):
    """Verify multi-speaker talks: each co-speaker receives individual magic link with their own SSO token."""
    cache.clear()
    mail.outbox.clear()
    rf = RequestFactory()

    submission = integrated_talk.submission

    with scopes_disabled():
        speaker2 = User.objects.create_user(
            email="bob@example.org",
            password="secretpassword123",
            fullname="Bob CoSpeaker",
        )

    with scope(event=integrated_event):
        submission.speakers.add(speaker2)

    payload = {
        "event": "talk.approved",
        "talk_id": 55,
        "event_id": integrated_event.id,
        "external_id": submission.code,
        "timestamp": time.time(),
    }

    response = mock_veditor.emit_webhook(
        rf,
        event="talk.approved",
        payload_data=payload,
        use_request_factory=True,
    )
    assert response.status_code == 200

    assert len(mail.outbox) == 2
    recipients = {m.to[0] for m in mail.outbox}
    assert recipients == {"alice@example.org", "bob@example.org"}

    # Verify both emails contain distinct valid JWTs
    tokens = []
    for msg in mail.outbox:
        magic_part = msg.body.split("http://localhost:8080/studio/talks/")[1].split()[0]
        token = urllib.parse.parse_qs(urllib.parse.urlparse(magic_part).query)["sso_token"][0]
        header, jwt_p = validate_jwt_structure(token, secret=mock_veditor.jwt_secret)
        assert header["typ"] == "JWT"
        assert jwt_p["role"] == "speaker"
        tokens.append(token)

    assert len(tokens) == 2
    assert tokens[0] != tokens[1]


# ============================================================================
# Scenario F: Webhook Security & Tampering Rejection
# ============================================================================


def test_integration_scenario_f_tampered_signature_rejected(mock_veditor, integrated_event):
    """Verify security boundary: forged or tampered HMAC signature is rejected with HTTP 401."""
    rf = RequestFactory()
    payload = {
        "event": "talk.approved",
        "talk_id": 42,
        "event_id": integrated_event.id,
        "external_id": "TALK101",
        "timestamp": time.time(),
    }
    raw_body = json.dumps(payload).encode("utf-8")

    request = rf.post(
        reverse("plugins:veditor:webhook"),
        data=raw_body,
        content_type="application/json",
        HTTP_X_VEDITOR_SIGNATURE="sha256=invalid_tampered_hash_0000000000000000000",
    )

    view = WebhookView.as_view()
    response = view(request)

    assert response.status_code == 401
    data = json.loads(response.content.decode("utf-8"))
    assert "Invalid webhook signature" in data["error"]


# ============================================================================
# Scenario G: Mock VEditor /events/{id}/talks/bulk endpoint validation
# ============================================================================


def test_mock_veditor_bulk_talks_endpoint(mock_veditor):
    """Verify MockVEditor responds to POST /events/{id}/talks/bulk and tracks synced talks."""
    import requests

    headers = {"X-API-Key": mock_veditor.api_key, "Content-Type": "application/json"}
    talk_data = [
        {"external_id": "TALK_BULK_1", "title": "Bulk Talk 1", "start": "2026-09-28T10:00:00Z"},
        {"external_id": "TALK_BULK_2", "title": "Bulk Talk 2", "start": "2026-09-28T11:00:00Z"},
    ]

    resp = requests.post(
        f"{mock_veditor.base_url}/events/42/talks/bulk",
        json={"talks": talk_data},
        headers=headers,
    )
    assert resp.status_code == 200
    res_json = resp.json()
    assert res_json["status"] == "ok"
    assert res_json["synced_count"] == 2

    # Assert talks were tracked in synced_talks
    assert len(mock_veditor.synced_talks) == 2
    assert mock_veditor.synced_talks[0]["external_id"] == "TALK_BULK_1"
    assert mock_veditor.synced_talks[1]["external_id"] == "TALK_BULK_2"
    assert len(mock_veditor.bulk_sync_requests) == 1
