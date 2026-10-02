"""Unit tests for the VEditor API client, mappers, and exceptions."""

import json
from datetime import UTC, datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pytest
import requests
import responses

from veditor.client import VEditorClient
from veditor.exceptions import (
    VEditorAuthError,
    VEditorConfigError,
    VEditorError,
    VEditorNetworkError,
    VEditorSyncError,
)
from veditor.mappers import serialize_talk, serialize_talks, to_utc_isoformat

# ============================================================================
# Mapper Unit Tests
# ============================================================================


def test_to_utc_isoformat_none():
    assert to_utc_isoformat(None) is None


def test_to_utc_isoformat_naive():
    dt = datetime(2026, 9, 12, 10, 30, 0)
    expected = "2026-09-12T10:30:00+00:00"
    assert to_utc_isoformat(dt) == expected


def test_to_utc_isoformat_aware_conversion():
    # UTC+5:30 -> should convert to UTC
    tz_ist = timezone(timedelta(hours=5, minutes=30))
    dt = datetime(2026, 9, 12, 15, 30, 0, tzinfo=tz_ist)
    expected = "2026-09-12T10:00:00+00:00"
    assert to_utc_isoformat(dt) == expected


def test_serialize_talk_with_orm_like_objects():
    event = SimpleNamespace(slug="fossasia-summit-2026", id=101)
    submission = SimpleNamespace(
        id=42,
        code="TALK-42",
        title="Opening Keynote",
        event=event,
    )
    room = SimpleNamespace(name="Main Hall")
    start = datetime(2026, 9, 12, 9, 0, 0, tzinfo=UTC)
    end = datetime(2026, 9, 12, 10, 0, 0, tzinfo=UTC)

    talk_slot = SimpleNamespace(
        id=1,
        submission=submission,
        room=room,
        start=start,
        end=end,
    )

    data = serialize_talk(talk_slot)
    assert data["external_id"] == "TALK-42"
    assert data["title"] == "Opening Keynote"
    assert data["room"] == "Main Hall"
    assert data["start"] == "2026-09-12T09:00:00+00:00"
    assert data["end"] == "2026-09-12T10:00:00+00:00"
    assert data["event_id"] == 101


def test_serialize_talk_with_dict_and_fallback():
    dict_talk = {
        "external_id": "SUB-99",
        "title": "Lightning Talk",
        "room": "Room B",
        "start": "2026-09-12T11:00:00+00:00",
        "end": "2026-09-12T11:15:00+00:00",
        "event_id": "test-conf",
    }
    data = serialize_talk(dict_talk)
    assert data["external_id"] == "SUB-99"
    assert data["title"] == "Lightning Talk"
    assert data["room"] == "Room B"
    assert data["event_id"] == "test-conf"


def test_serialize_talks_list():
    slots = [
        {"external_id": "1", "title": "Talk 1", "room": "A"},
        {"external_id": "2", "title": "Talk 2", "room": "B"},
    ]
    serialized = serialize_talks(slots, event_id="ev-1")
    assert len(serialized) == 2
    assert serialized[0]["event_id"] == "ev-1"
    assert serialized[1]["event_id"] == "ev-1"


def test_serialize_talk_with_string_timestamp_timezone_conversion():
    dict_talk = {
        "external_id": "SUB-100",
        "title": "Timezone Talk",
        "start": "2026-09-12T15:30:00+05:30",
        "end": "2026-09-12T16:30:00+05:30",
    }
    data = serialize_talk(dict_talk)
    assert data["start"] == "2026-09-12T10:00:00+00:00"
    assert data["end"] == "2026-09-12T11:00:00+00:00"


def test_serialize_talk_with_invalid_string_timestamp():
    dict_talk = {
        "external_id": "SUB-101",
        "title": "Broken Talk",
        "start": "not-a-valid-date",
    }
    with pytest.raises(ValueError, match="Invalid ISO-8601 timestamp"):
        serialize_talk(dict_talk)


def test_serialize_talks_deduplication():
    # Duplicate talk slot representations from multiple schedule versions
    slots = [
        {"external_id": "1", "title": "Keynote", "start": "2026-06-01T10:00:00Z"},
        {"external_id": "1", "title": "Keynote", "start": "2026-06-01T10:00:00Z"},
        {"external_id": "2", "title": "Workshop", "start": "2026-06-01T11:00:00Z"},
    ]
    serialized = serialize_talks(slots, event_id="1")
    assert len(serialized) == 2
    assert serialized[0]["title"] == "Keynote"
    assert serialized[1]["title"] == "Workshop"


def test_serialize_talks_distinct_external_ids_same_title_and_start():
    # Talks with different external_ids but identical title and start time (e.g. TBA / Lightning talk)
    slots = [
        {"external_id": "sub-1", "title": "Lightning Talk", "start": "2026-06-01T10:00:00Z"},
        {"external_id": "sub-2", "title": "Lightning Talk", "start": "2026-06-01T10:00:00Z"},
    ]
    serialized = serialize_talks(slots, event_id="1")
    assert len(serialized) == 2
    assert serialized[0]["external_id"] == "sub-1"
    assert serialized[1]["external_id"] == "sub-2"


def test_serialize_talks_preserves_multiple_occurrences_of_same_submission():
    # A single submission scheduled across multiple distinct slots (e.g. repeat session or workshop)
    slots = [
        {"external_id": "sub-100", "title": "Advanced Python", "start": "2026-06-01T10:00:00Z"},
        {"external_id": "sub-100", "title": "Advanced Python", "start": "2026-06-01T14:00:00Z"},
    ]
    serialized = serialize_talks(slots, event_id="1")
    assert len(serialized) == 2
    assert serialized[0]["start"] == "2026-06-01T10:00:00+00:00"
    assert serialized[1]["start"] == "2026-06-01T14:00:00+00:00"


def test_serialize_talks_preserves_simultaneous_sessions_without_external_id():
    # Breakout sessions occurring at the same time in different rooms without external IDs
    slots = [
        {"title": "Open Space", "room": "Room A", "start": "2026-06-01T10:00:00Z"},
        {"title": "Open Space", "room": "Room B", "start": "2026-06-01T10:00:00Z"},
    ]
    serialized = serialize_talks(slots, event_id="1")
    assert len(serialized) == 2
    assert serialized[0]["room"] == "Room A"
    assert serialized[1]["room"] == "Room B"


def test_serialize_talks_distinct_namespace_for_title_and_external_id():
    # A talk where external_id is 'Break' vs a talk where title is 'Break'
    slots = [
        {"external_id": "Break", "title": "Keynote 1", "start": "2026-06-01T10:00:00Z"},
        {"title": "Break", "start": "2026-06-01T10:00:00Z"},
    ]
    serialized = serialize_talks(slots, event_id="1")
    assert len(serialized) == 2


# ============================================================================
# Client Configuration Unit Tests
# ============================================================================


def test_client_init_explicit():
    client = VEditorClient(
        base_url="https://editor.example.com",
        api_key="secret-key-123",
        timeout=15.0,
    )
    assert client.base_url == "https://editor.example.com"
    assert client.api_key == "secret-key-123"
    assert client.timeout == 15.0
    assert client.session.headers["X-API-Key"] == "secret-key-123"


def test_client_init_strips_trailing_slash():
    client = VEditorClient(
        base_url="https://editor.example.com///",
        api_key="key",
    )
    assert client.base_url == "https://editor.example.com"


def test_client_init_missing_base_url():
    with patch.dict("os.environ", {}, clear=True):
        with pytest.raises(VEditorConfigError, match="VEditor base URL is not configured"):
            VEditorClient(base_url=None, api_key="some-key")


def test_client_init_missing_base_url_with_event_no_fallback():
    event = SimpleNamespace(slug="summit-2026", name="FOSSASIA Summit 2026")
    with patch.dict("os.environ", {}, clear=True):
        with pytest.raises(VEditorConfigError, match="VEditor base URL is not configured"):
            VEditorClient(base_url=None, api_key="some-key", event=event)


def test_client_init_invalid_base_url():
    with pytest.raises(VEditorConfigError, match="Invalid VEditor base URL"):
        VEditorClient(base_url="not-a-valid-url", api_key="some-key")


def test_client_init_insecure_http_rejected():
    with pytest.raises(VEditorConfigError, match="Insecure HTTP URL .* is only permitted for loopback addresses"):
        VEditorClient(base_url="http://remote.veditor.example.com", api_key="some-key")


def test_client_init_loopback_http_allowed():
    client = VEditorClient(base_url="http://127.0.0.1:8000", api_key="some-key")
    assert client.base_url == "http://127.0.0.1:8000"


def test_client_init_allowed_origins(settings):
    settings.VEDITOR_ALLOWED_ORIGINS = ["https://trusted.veditor.com"]
    with pytest.raises(VEditorConfigError, match="not in VEDITOR_ALLOWED_ORIGINS"):
        VEditorClient(base_url="https://untrusted.veditor.com", api_key="some-key")
    client = VEditorClient(base_url="https://trusted.veditor.com", api_key="some-key")
    assert client.base_url == "https://trusted.veditor.com"


def test_client_init_allowed_origins_string_and_casing(settings):
    settings.VEDITOR_ALLOWED_ORIGINS = "https://trusted.veditor.com, https://another.veditor.com"
    # Substring origin must NOT match and raise error
    with pytest.raises(VEditorConfigError, match="not in VEDITOR_ALLOWED_ORIGINS"):
        VEditorClient(base_url="https://trusted.veditor", api_key="some-key")

    # Mixed casing in base_url should match properly
    client = VEditorClient(base_url="HTTPS://TRUSTED.VEDITOR.COM", api_key="some-key")
    assert client.base_url == "HTTPS://TRUSTED.VEDITOR.COM"


def test_client_init_missing_api_key():
    with patch.dict("os.environ", {}, clear=True):
        with pytest.raises(VEditorConfigError, match="VEditor API key is not configured"):
            VEditorClient(base_url="https://editor.example.com", api_key=None)


def test_client_init_from_env():
    env = {
        "VEDITOR_API_BASE_URL": "http://localhost:8000",
        "VEDITOR_API_KEY": "env-key",
        "VEDITOR_REQUEST_TIMEOUT": "25.0",
    }
    with patch.dict("os.environ", env, clear=True):
        client = VEditorClient()
        assert client.base_url == "http://localhost:8000"
        assert client.api_key == "env-key"
        assert client.timeout == 25.0


@pytest.mark.parametrize("invalid_timeout", [0, -5.0, "not-a-number"])
def test_client_init_invalid_timeout(invalid_timeout):
    with pytest.raises(VEditorConfigError, match="Invalid timeout"):
        VEditorClient(
            base_url="https://editor.example.com",
            api_key="secret",
            timeout=invalid_timeout,
        )


def test_client_init_retry_adapter_configured():
    client = VEditorClient(
        base_url="https://editor.example.com",
        api_key="secret",
    )
    http_adapter = client.session.adapters.get("http://")
    https_adapter = client.session.adapters.get("https://")
    assert http_adapter is not None
    assert https_adapter is not None
    assert http_adapter.max_retries.total == 3
    assert 502 in http_adapter.max_retries.status_forcelist


def test_client_init_from_event_settings():
    class MockSettings:
        def __init__(self, data):
            self.data = data

        def get(self, key):
            return self.data.get(key)

    mock_event = SimpleNamespace(
        settings=MockSettings(
            {
                "veditor_api_base_url": "https://veditor.eventyay.com",
                "veditor_api_key": "event-specific-key",
            }
        )
    )
    with patch.dict("os.environ", {}, clear=True):
        client = VEditorClient(event=mock_event)
        assert client.base_url == "https://veditor.eventyay.com"
        assert client.api_key == "event-specific-key"


# ============================================================================
# Client API Request & Endpoint Tests
# ============================================================================


@responses.activate
def test_sync_talk_success():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        json={"id": 1, "external_id": "T1", "status": "created"},
        status=201,
    )

    talk_slot = {"external_id": "T1", "title": "Test Talk", "event_id": "event-1"}
    result = client.sync_talk(talk_slot)

    assert result["status"] == "created"
    assert responses.calls[0].request.headers["X-API-Key"] == "test-key"


@responses.activate
def test_sync_talks_bulk_success():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks/schedule/import",
        json={"status": "ok", "synced_count": 2},
        status=200,
    )

    slots = [
        {"external_id": "T1", "title": "Talk 1"},
        {"external_id": "T2", "title": "Talk 2"},
    ]
    result = client.sync_talks("fossasia-2026", slots)

    assert result["status"] == "ok"
    assert result["synced_count"] == 2
    assert "talks" in responses.calls[0].request.body.decode("utf-8")


def test_request_disallows_redirects():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    with patch.object(client.session, "request") as mock_request:
        mock_response = mock_request.return_value
        mock_response.status_code = 200
        mock_response.json.return_value = {"status": "ok"}
        client._request("GET", "/test-endpoint")
        mock_request.assert_called_once()
        _, kwargs = mock_request.call_args
        assert kwargs.get("allow_redirects") is False


@responses.activate
def test_request_sso_jwt_organiser():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/events/fossasia-2026/sso-token",
        json={"token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.dummy_organiser_jwt"},
        status=200,
    )

    token = client.request_sso_jwt(event_id="fossasia-2026", role="organiser")
    assert token == "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.dummy_organiser_jwt"


@responses.activate
def test_get_scoped_event_id_success():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[{"id": 42, "name": "Test Event"}],
        status=200,
    )
    event_id = client.get_scoped_event_id()
    assert event_id == 42


@responses.activate
def test_get_scoped_event_id_empty_raises():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[],
        status=200,
    )
    with pytest.raises(VEditorError, match="No event associated"):
        client.get_scoped_event_id()


@responses.activate
def test_get_scoped_event_id_disambiguates():
    event = SimpleNamespace(slug="summit-2026", name="FOSSASIA Summit 2026")
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key", event=event)
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[
            {"id": 10, "external_id": "other-event", "name": "Other"},
            {"id": 42, "external_id": "summit-2026", "name": "FOSSASIA Summit 2026"},
        ],
        status=200,
    )
    assert client.get_scoped_event_id() == 42


@responses.activate
def test_get_scoped_event_id_multiple_ambiguous_raises():
    event = SimpleNamespace(slug="unknown-slug", name="Unknown Event")
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key", event=event)
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[
            {"id": 10, "external_id": "event-1", "name": "Event 1"},
            {"id": 20, "external_id": "event-2", "name": "Event 2"},
        ],
        status=200,
    )
    with pytest.raises(VEditorError, match="cannot disambiguate"):
        client.get_scoped_event_id()


@responses.activate
def test_get_scoped_event_id_external_id_precedence_over_name():
    # Event matches external_id of event 42, but matches name of event 10.
    # External ID matching must take strict precedence without triggering ambiguity.
    event = SimpleNamespace(slug="summit-2026", name="Other Event")
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key", event=event)
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[
            {"id": 10, "external_id": "other-event", "name": "Other Event"},
            {"id": 42, "external_id": "summit-2026", "name": "Different Name"},
        ],
        status=200,
    )
    assert client.get_scoped_event_id() == 42


@responses.activate
def test_get_scoped_event_id_fallback_to_name_when_no_external_id_matches():
    event = SimpleNamespace(slug="unmatched-slug", name="Target Event")
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key", event=event)
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[
            {"id": 10, "external_id": "other-event", "name": "Other"},
            {"id": 88, "external_id": "another-event", "name": "Target Event"},
        ],
        status=200,
    )
    assert client.get_scoped_event_id() == 88


@responses.activate
def test_get_scoped_event_id_no_event_multiple_raises():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key", event=None)
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[
            {"id": 10, "name": "Event 1"},
            {"id": 20, "name": "Event 2"},
        ],
        status=200,
    )
    with pytest.raises(VEditorError, match="no event context provided to disambiguate"):
        client.get_scoped_event_id()


@responses.activate
def test_request_sso_jwt_speaker():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks/talk-123/sso-token",
        json={"token": "dummy_speaker_jwt"},
        status=200,
    )

    token = client.request_sso_jwt(event_id="fossasia-2026", talk_id="talk-123", role="speaker")
    assert token == "dummy_speaker_jwt"


def test_request_sso_jwt_speaker_missing_talk_id():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    with pytest.raises(ValueError, match="talk_id is required"):
        client.request_sso_jwt(event_id="fossasia-2026", role="speaker")


def test_request_sso_jwt_unsupported_role():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    with pytest.raises(ValueError, match="Unsupported role"):
        client.request_sso_jwt(event_id="fossasia-2026", role="admin")


@responses.activate
def test_request_sso_jwt_missing_token_in_response():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/events/fossasia-2026/sso-token",
        json={"status": "ok"},  # No token field
        status=200,
    )

    with pytest.raises(VEditorError, match="No token received in SSO response"):
        client.request_sso_jwt(event_id="fossasia-2026", role="organiser")


# ============================================================================
# HTTP Error & Network Handling Tests
# ============================================================================


@responses.activate
@pytest.mark.parametrize("status_code", [401, 403])
def test_client_auth_errors(status_code):
    client = VEditorClient(base_url="https://veditor.test", api_key="bad-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        json={"detail": "Invalid API key"},
        status=status_code,
    )

    with pytest.raises(VEditorAuthError) as exc_info:
        client.sync_talk({"external_id": "1", "title": "Talk"})

    assert exc_info.value.status_code == status_code
    assert "Invalid API key" in str(exc_info.value)


@responses.activate
@pytest.mark.parametrize("status_code", [400, 422])
def test_client_sync_validation_errors(status_code):
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks/schedule/import",
        json={"detail": "Field 'title' cannot be empty"},
        status=status_code,
    )

    with pytest.raises(VEditorSyncError) as exc_info:
        client.sync_talks("fossasia-2026", [])

    assert exc_info.value.status_code == status_code
    assert "Field 'title' cannot be empty" in str(exc_info.value)


@responses.activate
@pytest.mark.parametrize("status_code", [500, 502, 503, 504])
def test_client_server_errors(status_code):
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        json={"detail": "Internal server crash"},
        status=status_code,
    )

    with pytest.raises(VEditorNetworkError) as exc_info:
        client.sync_talk({"external_id": "1"})

    assert exc_info.value.status_code == status_code
    assert "Internal server crash" in str(exc_info.value)


@responses.activate
def test_client_timeout_error():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        body=requests.exceptions.Timeout("Connection timed out"),
    )

    with pytest.raises(VEditorNetworkError, match="timed out"):
        client.sync_talk({"external_id": "1"})


@responses.activate
def test_client_connection_error():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        body=requests.exceptions.ConnectionError("Failed to establish a new connection"),
    )

    with pytest.raises(VEditorNetworkError, match="Failed to connect"):
        client.sync_talk({"external_id": "1"})


@responses.activate
def test_client_non_dict_error_response():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    responses.add(
        responses.POST,
        "https://veditor.test/talks",
        json=["bulk error item 1", "bulk error item 2"],
        status=400,
    )

    with pytest.raises(VEditorSyncError) as exc_info:
        client.sync_talk({"external_id": "1"})

    assert "bulk error item 1" in str(exc_info.value)


@responses.activate
def test_get_scoped_event_id_single_event():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    responses.add(
        responses.GET,
        "https://veditor.test/events",
        json=[{"id": 100409, "name": "Codemania"}],
        status=200,
    )
    assert client.get_scoped_event_id() == 100409


def test_client_prevents_global_key_leakage_to_custom_url():
    event_mock = SimpleNamespace(settings=SimpleNamespace(get=lambda k, d=None: "https://attacker.test" if k == "veditor_api_base_url" else None))
    with patch.dict("os.environ", {"VEDITOR_API_KEY": "global-secret-key"}):
        with pytest.raises(VEditorConfigError, match="Cannot use global VEDITOR_API_KEY"):
            VEditorClient(event=event_mock)


def test_client_allows_custom_url_with_explicit_event_key():
    event_mock = SimpleNamespace(
        settings=SimpleNamespace(
            get=lambda k, d=None: "https://custom.test" if k == "veditor_api_base_url" else ("event-key-456" if k == "veditor_api_key" else None)
        )
    )
    client = VEditorClient(event=event_mock)
    assert client.base_url == "https://custom.test"
    assert client.api_key == "event-key-456"


@responses.activate
def test_attach_room_recording_with_source_path_success():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    responses.add(
        responses.POST,
        "https://veditor.test/talks/room/attach-recording",
        json={
            "status": "ok",
            "room": "Main Hall",
            "event_id": 42,
            "attached_count": 3,
            "talk_ids": [101, 102, 103],
        },
        status=200,
    )

    result = client.attach_room_recording(
        room="Main Hall",
        event_id=42,
        source_path="/media/ingest/day1/main_hall.mp4",
        recording_start=datetime(2026, 9, 25, 9, 0, 0, tzinfo=UTC),
    )

    assert result["status"] == "ok"
    assert result["attached_count"] == 3
    assert result["room"] == "Main Hall"
    assert result["event_id"] == 42
    assert result["talk_ids"] == [101, 102, 103]

    assert len(responses.calls) == 1
    req_body = json.loads(responses.calls[0].request.body)
    assert req_body["room"] == "Main Hall"
    assert req_body["event_id"] == 42
    assert req_body["source_path"] == "/media/ingest/day1/main_hall.mp4"
    assert req_body["recording_start"] == "2026-09-25T09:00:00+00:00"


@responses.activate
def test_attach_room_recording_with_relative_key():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")
    responses.add(
        responses.POST,
        "https://veditor.test/talks/room/attach-recording",
        json={"status": "ok", "attached_count": 1, "room": "Room B", "event_id": 10, "talk_ids": [55]},
        status=200,
    )

    result = client.attach_room_recording(
        room="Room B",
        event_id="10",
        relative_key="day1/room_b.mp4",
        recording_start="2026-09-25T10:00:00Z",
    )

    assert result["attached_count"] == 1
    req_body = json.loads(responses.calls[0].request.body)
    assert req_body["relative_key"] == "day1/room_b.mp4"
    assert req_body["recording_start"] == "2026-09-25T10:00:00Z"


def test_attach_room_recording_validation_errors():
    client = VEditorClient(base_url="https://veditor.test", api_key="test-key")

    # Missing room
    with pytest.raises(ValueError, match="Room name is required"):
        client.attach_room_recording(room="", source_path="/media/day1.mp4")

    # Missing both relative_key and source_path
    with pytest.raises(ValueError, match="Either relative_key or source_path must be provided"):
        client.attach_room_recording(room="Main Hall")
