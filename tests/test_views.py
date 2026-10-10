"""Unit and integration tests for the Connect view and navigation signals."""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from django.contrib.messages.storage.fallback import FallbackStorage
from django.contrib.sessions.middleware import SessionMiddleware
from django.core.exceptions import PermissionDenied
from django.test import RequestFactory
from django.urls import reverse
from eventyay.control.signals import nav_event, nav_event_common

from veditor.exceptions import VEditorNetworkError, VEditorSyncError
from veditor.signals import control_nav_veditor
from veditor.views import ConnectView


def setup_request(request):
    """Helper to attach session and messages storage to a RequestFactory request."""
    middleware = SessionMiddleware(lambda req: None)
    middleware.process_request(request)
    request.session.save()
    request._messages = FallbackStorage(request)
    request.LANGUAGE_CODE = "en"
    return request


class MockEventSettings:
    def __init__(self, data=None):
        self.data = data or {}
        self.locales = self.data.get("locales", ["en"])
        self.presale_css_file = None

    def get(self, key, default=None, *args, **kwargs):
        return self.data.get(key, default)

    def set(self, key, value):
        self.data[key] = value

    def __getattr__(self, item):
        return self.data.get(item, None)


@pytest.fixture
def event():
    """Mock event fixture avoiding database connections in CI."""
    organizer = SimpleNamespace(id=1, pk=1, slug="test-org", settings=MockEventSettings({"locales": ["en"]}))
    schedule = SimpleNamespace(scheduled_talks=[])
    return SimpleNamespace(
        id=42,
        pk=42,
        slug="test-conf",
        name="Test Conference 2026",
        organizer=organizer,
        settings=MockEventSettings(),
        current_schedule=schedule,
        wip_schedule=None,
        get_talk_slots=lambda: [],
        talks_published=False,
        testmode=False,
        live=True,
        orders=SimpleNamespace(filter=lambda **kw: SimpleNamespace(exists=lambda: False)),
        cache=SimpleNamespace(get=lambda k, default=None: False if k == "complain_testmode_orders" else default, get_or_set=lambda k, val, ttl=None: val),
    )


@pytest.fixture
def user():
    """Mock unprivileged user fixture."""
    mock_u = MagicMock()
    mock_u.is_authenticated = True
    mock_u.has_event_permission.return_value = False
    return mock_u


@pytest.fixture
def organizer_user():
    """Mock organizer user fixture with can_change_event_settings permission."""
    mock_u = MagicMock()
    mock_u.is_authenticated = True
    mock_u.has_event_permission.return_value = True
    return mock_u


@pytest.fixture
def rf():
    return RequestFactory()


# ============================================================================
# Navigation Signal Tests
# ============================================================================


def test_signals_nav_unauthenticated(event, rf):
    request = setup_request(rf.get("/"))
    request.user = SimpleNamespace(is_authenticated=False)
    items = control_nav_veditor(sender=event, request=request)
    assert items == []


def test_signals_nav_no_permission(event, user, rf):
    request = setup_request(rf.get("/"))
    request.user = user
    items = control_nav_veditor(sender=event, request=request)
    assert items == []


def test_signals_nav_with_permission(event, organizer_user, rf):
    request = setup_request(rf.get("/"))
    request.user = organizer_user
    items = control_nav_veditor(sender=event, request=request)
    assert len(items) == 1
    assert items[0]["label"] == "Video Editor"
    assert items[0]["icon"] == "video-camera"
    assert reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}) in items[0]["url"]


def test_signals_nav_missing_organizer(organizer_user, rf):
    request = setup_request(rf.get("/"))
    request.user = organizer_user
    # Sender without organizer
    sender_no_org = SimpleNamespace(slug="event-slug")
    assert control_nav_veditor(sender=sender_no_org, request=request) == []

    # Sender with organizer but organizer has no slug
    sender_org_no_slug = SimpleNamespace(slug="event-slug", organizer=SimpleNamespace(slug=None))
    assert control_nav_veditor(sender=sender_org_no_slug, request=request) == []

    # Sender with organizer but sender has no slug
    sender_no_event_slug = SimpleNamespace(slug=None, organizer=SimpleNamespace(slug="org-slug"))
    assert control_nav_veditor(sender=sender_no_event_slug, request=request) == []


# ============================================================================
# Connect View Tests
# ============================================================================


def test_connect_view_get_unauthorized(event, user, rf):
    request = setup_request(rf.get(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    with pytest.raises(PermissionDenied):
        view(request, organizer=event.organizer.slug, event=event.slug)


def test_connect_view_get_authorized(event, organizer_user, rf):
    request = setup_request(rf.get(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 200
    assert response.context_data["event"] == event
    assert response.context_data["talks_count"] == 0


def test_connect_view_post_success(event, organizer_user, rf):
    request = setup_request(rf.post(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "https://editor.example.com"
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.sync_talks.return_value = {"status": "ok", "imported_count": 0}
        mock_client.request_sso_jwt.return_value = "mock_signed_jwt_token"

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert response.url == f"https://editor.example.com/studio?event_id={event.id}&sso_token=mock_signed_jwt_token"
        assert mock_client.sync_talks.called
        assert mock_client.request_sso_jwt.called


def test_connect_view_post_sync_error_blocks_redirect(event, organizer_user, rf):
    request = setup_request(rf.post(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "https://editor.example.com"
        mock_client.sync_talks.side_effect = VEditorSyncError("Invalid talk structure", status_code=422)

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        # Must stay on the connect page with 200, NOT redirect to VEditor
        assert response.status_code == 200
        assert not mock_client.request_sso_jwt.called
        messages = [m.message for m in request._messages]
        assert any("Failed to synchronize talks" in str(m) for m in messages)


def test_connect_view_post_network_error_blocks_redirect(event, organizer_user, rf):
    request = setup_request(rf.post(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "https://editor.example.com"
        mock_client.sync_talks.side_effect = VEditorNetworkError("VEditor server connection refused")

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        # Must stay on the connect page with 200, NOT redirect to VEditor
        assert response.status_code == 200
        assert not mock_client.request_sso_jwt.called
        messages = [m.message for m in request._messages]
        assert any("Failed to synchronize talks" in str(m) for m in messages)


def test_connect_view_post_save_settings(event, organizer_user, rf):
    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "save_settings",
                "veditor_api_base_url": "http://localhost:8080/",
                "veditor_api_key": "new-secret-key",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 302
    assert event.settings.get("veditor_api_base_url") == "http://localhost:8080"
    assert event.settings.get("veditor_api_key") == "new-secret-key"


def test_connect_view_post_save_settings_api_key_only(event, organizer_user, rf):
    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "save_settings",
                "veditor_api_base_url": "",
                "veditor_api_key": "key-without-explicit-url",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 302
    assert event.settings.get("veditor_api_key") == "key-without-explicit-url"


def test_connect_view_post_with_auto_event_id(event, organizer_user, rf):
    event.settings.set("veditor_api_base_url", "http://localhost:8080")
    event.settings.set("veditor_api_key", "valid-key")

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={"action": "sync_and_launch"},
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "http://localhost:8080"
        mock_client.get_scoped_event_id.return_value = 77
        mock_client.sync_talks.return_value = {"status": "ok"}
        mock_client.request_sso_jwt.return_value = "jwt_token_123"

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert response.url == "http://localhost:8080/studio?event_id=77&sso_token=jwt_token_123"
        mock_client.get_scoped_event_id.assert_called_once()
        mock_client.sync_talks.assert_called_once_with(event_id=77, talk_slots=[])
        mock_client.request_sso_jwt.assert_called_once_with(
            event_id=77,
            role="organizer",
            email=organizer_user.email,
            display_name=organizer_user.fullname,
        )


# ============================================================================
# Schedule Scoping & Talk Slots Resolution Tests
# ============================================================================


def test_talk_slots_published_schedule(event):
    view = ConnectView()
    slot1 = SimpleNamespace(id=1, submission_id=101)
    slot2 = SimpleNamespace(id=2, submission_id=102)
    event.current_schedule = SimpleNamespace(scheduled_talks=[slot1, slot2])
    view.request = SimpleNamespace(event=event)

    slots = view.get_talk_slots()
    assert slots == [slot1, slot2]


def test_talk_slots_scheduled_talks_queryset(event):
    view = ConnectView()
    slot = SimpleNamespace(id=1, submission_id=101)
    mock_qs = MagicMock()
    mock_qs.filter.return_value.select_related.return_value.order_by.return_value = [slot]
    event.current_schedule = SimpleNamespace(scheduled_talks=mock_qs)
    view.request = SimpleNamespace(event=event)

    slots = view.get_talk_slots()
    assert slots == [slot]
    mock_qs.filter.assert_called_once_with(submission__isnull=False)
    mock_qs.filter.return_value.select_related.assert_called_once_with("submission", "room")
    mock_qs.filter.return_value.select_related.return_value.order_by.assert_called_once_with("start")


def test_talk_slots_wip_schedule_fallback(event):
    view = ConnectView()
    event.current_schedule = None
    slot = SimpleNamespace(id=3, submission_id=103)
    mock_talks = MagicMock()
    mock_talks.filter.return_value.select_related.return_value.order_by.return_value = [slot]
    event.wip_schedule = SimpleNamespace(talks=mock_talks)
    view.request = SimpleNamespace(event=event)

    slots = view.get_talk_slots()
    assert slots == [slot]


def test_talk_slots_no_schedule(event):
    view = ConnectView()
    event.current_schedule = None
    event.wip_schedule = None
    view.request = SimpleNamespace(event=event)

    slots = view.get_talk_slots()
    assert slots == []


# ============================================================================
# URL Structure & Form Validation Tests
# ============================================================================


def test_urls_has_no_event_patterns():
    import veditor.urls

    assert not hasattr(veditor.urls, "event_patterns")


def test_form_url_validation():
    from veditor.forms import VEditorSettingsForm

    # Valid HTTPS
    form = VEditorSettingsForm(data={"veditor_api_base_url": "https://editor.example.com", "veditor_api_key": "key"})
    assert form.is_valid()
    assert form.cleaned_data["veditor_api_base_url"] == "https://editor.example.com"

    # Valid loopback HTTP (localhost, 127.0.0.1)
    form_lh = VEditorSettingsForm(data={"veditor_api_base_url": "http://localhost:8080/", "veditor_api_key": "key"})
    assert form_lh.is_valid()
    assert form_lh.cleaned_data["veditor_api_base_url"] == "http://localhost:8080"

    form_ip = VEditorSettingsForm(data={"veditor_api_base_url": "http://127.0.0.1:8080", "veditor_api_key": "key"})
    assert form_ip.is_valid()

    # Insecure non-loopback HTTP rejected
    form_insecure = VEditorSettingsForm(data={"veditor_api_base_url": "http://insecure.example.com", "veditor_api_key": "key"})
    assert not form_insecure.is_valid()
    assert "veditor_api_base_url" in form_insecure.errors


def test_form_allowed_origins(settings):
    from veditor.forms import VEditorSettingsForm

    # Netloc or bare hostname in VEDITOR_ALLOWED_ORIGINS is permitted
    settings.VEDITOR_ALLOWED_ORIGINS = ["editor.eventyay.com", "custom.domain.org:8443"]

    form_hostname = VEditorSettingsForm(data={"veditor_api_base_url": "https://editor.eventyay.com", "veditor_api_key": "key"})
    assert form_hostname.is_valid()

    form_netloc = VEditorSettingsForm(data={"veditor_api_base_url": "https://custom.domain.org:8443", "veditor_api_key": "key"})
    assert form_netloc.is_valid()

    form_unallowed = VEditorSettingsForm(data={"veditor_api_base_url": "https://untrusted.domain.org", "veditor_api_key": "key"})
    assert not form_unallowed.is_valid()
    assert "veditor_api_base_url" in form_unallowed.errors


def test_form_blank_api_key_handling():
    from veditor.forms import VEditorSettingsForm

    # Blank key is valid when has_existing_key=True
    form_existing = VEditorSettingsForm(
        data={"veditor_api_base_url": "https://editor.example.com", "veditor_api_key": ""},
        has_existing_key=True,
    )
    assert form_existing.is_valid()

    # Blank key is rejected when has_existing_key=False
    form_new = VEditorSettingsForm(
        data={"veditor_api_base_url": "https://editor.example.com", "veditor_api_key": ""},
        has_existing_key=False,
    )
    assert not form_new.is_valid()
    assert "veditor_api_key" in form_new.errors


def test_connect_view_post_open_studio_action_skips_talk_sync(event, organizer_user, rf):
    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={"action": "open_studio"},
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "https://editor.example.com"
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.request_sso_jwt.return_value = "mock_token"

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert response.url == f"https://editor.example.com/studio?event_id={event.id}&sso_token=mock_token"
        assert not mock_client.sync_talks.called
        assert mock_client.request_sso_jwt.called


def test_connect_view_post_sso_error_does_not_label_sync_failure(event, organizer_user, rf):
    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={"action": "sync_and_launch"},
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.base_url = "https://editor.example.com"
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.sync_talks.return_value = {"status": "ok"}
        mock_client.request_sso_jwt.side_effect = VEditorNetworkError("SSO signature endpoint unreachable")

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 200
        messages = [str(m.message) for m in request._messages]
        assert any("Failed to establish VEditor SSO session" in m for m in messages)
        assert not any("Failed to synchronize talks" in m for m in messages)


def test_connect_view_post_save_settings_preserves_existing_key(event, organizer_user, rf):
    event.settings.set("veditor_api_key", "original-secret-key")
    event.settings.set("veditor_api_base_url", "http://localhost:8080")

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "save_settings",
                "veditor_api_base_url": "https://editor.example.com",
                "veditor_api_key": "",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 302
    assert event.settings.get("veditor_api_base_url") == "https://editor.example.com"
    assert event.settings.get("veditor_api_key") == "original-secret-key"


def test_signals_nav_registration():
    """Verify VEditor is registered only with the common navigation signal."""
    tickets_uids = {key[0] for key, _, _, _ in nav_event.receivers}
    common_uids = {key[0] for key, _, _, _ in nav_event_common.receivers}

    assert "veditor_nav_event" not in tickets_uids
    assert "veditor_nav_event_common" in common_uids


def test_connect_view_post_sync_schedule_success(event, organizer_user, rf):
    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={"action": "sync_schedule"},
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.sync_talks.return_value = {"status": "ok", "imported_count": 5}

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert response.url == reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})
        assert mock_client.sync_talks.called
        assert not mock_client.request_sso_jwt.called
        messages = [str(m.message) for m in request._messages]
        assert any("Successfully synchronized 5 talk(s) with VEditor" in m for m in messages)


def test_connect_view_get_populates_rooms_in_room_form(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_room2 = SimpleNamespace(name="Workshop Room")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1, mock_room2]
    mock_rooms.count.return_value = 2
    event.rooms = mock_rooms

    request = setup_request(rf.get(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView()
    view.setup(request, organizer=event.organizer.slug, event=event.slug)
    context = view.get_context_data()

    assert "room_form" in context
    assert context["rooms_count"] == 2
    choices = [c[0] for c in context["room_form"].fields["room"].choices]
    assert "Main Hall" in choices
    assert "Workshop Room" in choices


def test_connect_view_post_attach_room_recording_success(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
                "video_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                "recording_start": "2026-09-25T09:00:00Z",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    distinct_veditor_event_id = 98765
    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = distinct_veditor_event_id
        mock_client.sync_talks.return_value = {"status": "ok"}
        mock_client.attach_room_recording.return_value = {
            "status": "ok",
            "attached_count": 3,
            "room": "Main Hall",
            "event_id": distinct_veditor_event_id,
            "talk_ids": [101, 102, 103],
        }

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        # Verify auto-sync ran prior to attachment and used the resolved scoped event ID
        assert mock_client.get_scoped_event_id.called
        mock_client.sync_talks.assert_called_once_with(event_id=distinct_veditor_event_id, talk_slots=[])
        mock_client.attach_room_recording.assert_called_once_with(
            room="Main Hall",
            event_id=distinct_veditor_event_id,
            video_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            video_file=None,
            recording_start="2026-09-25T09:00:00Z",
        )
        messages = [str(m.message) for m in request._messages]
        assert any("Successfully attached room recording for room 'Main Hall'" in m for m in messages)
        assert any("IDs: 101, 102, 103" in m for m in messages)


def test_connect_view_post_attach_room_recording_sync_failure_stops_attachment(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
                "video_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = 1234
        mock_client.sync_talks.side_effect = VEditorSyncError("Network timeout during talk sync")

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert mock_client.sync_talks.called
        assert not mock_client.attach_room_recording.called
        messages = [str(m.message) for m in request._messages]
        assert any("Failed to synchronize schedule prior to attaching recording" in m for m in messages)


def test_connect_view_post_attach_room_recording_unexpected_sync_failure_propagates(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
                "video_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = 1234
        mock_client.sync_talks.side_effect = RuntimeError("Unexpected internal crash")

        view = ConnectView.as_view()
        with pytest.raises(RuntimeError, match="Unexpected internal crash"):
            view(request, organizer=event.organizer.slug, event=event.slug)


def test_connect_view_post_attach_room_recording_with_file(event, organizer_user, rf):
    from django.core.files.uploadedfile import SimpleUploadedFile

    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    uploaded_video = SimpleUploadedFile("hall_a.mp4", b"fake-video-bytes", content_type="video/mp4")

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
                "video_file": uploaded_video,
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.sync_talks.return_value = {"status": "ok"}
        mock_client.attach_room_recording.return_value = {
            "status": "ok",
            "attached_count": 2,
            "room": "Main Hall",
            "event_id": event.id,
            "talk_ids": [10, 11],
        }

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        assert mock_client.attach_room_recording.called
        call_kwargs = mock_client.attach_room_recording.call_args[1]
        assert call_kwargs["room"] == "Main Hall"
        assert call_kwargs["video_file"] is not None


def test_connect_view_post_attach_room_recording_validation_error(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 200
    assert "room_form" in response.context_data
    assert response.context_data["room_form"].errors


def test_connect_view_post_attach_room_recording_api_error(event, organizer_user, rf):
    mock_room1 = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room1]
    event.rooms = mock_rooms

    request = setup_request(
        rf.post(
            reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug}),
            data={
                "action": "attach_room_recording",
                "room": "Main Hall",
                "video_url": "https://vimeo.com/invalid",
            },
        )
    )
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    with patch("veditor.views.VEditorClient") as mock_client_cls:
        mock_client = mock_client_cls.return_value
        mock_client.get_scoped_event_id.return_value = event.id
        mock_client.sync_talks.return_value = {"status": "ok"}
        mock_client.attach_room_recording.side_effect = VEditorSyncError("Invalid stream URL")

        view = ConnectView.as_view()
        response = view(request, organizer=event.organizer.slug, event=event.slug)

        assert response.status_code == 302
        messages = [str(m.message) for m in request._messages]
        assert any("Failed to attach room recording: Invalid stream URL" in m for m in messages)


def test_connect_view_rendered_ui_unconfigured(event, organizer_user, rf):
    """Verify template and view context in unconfigured state match Eventyay design tokens."""
    request = setup_request(rf.get(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 200
    assert response.template_name == ["veditor/connect.html"]
    assert response.context_data["veditor_configured"] is False

    from django.template.loader import get_template

    template = get_template("veditor/connect.html")
    source = template.template.source

    assert "Video Editor (VEditor)" in source
    assert "Not Configured" in source
    assert "Setup & Integration Guide" in source
    assert "veditor-dashboard-hero" not in source
    assert "Open Studio without Sync" not in source
    assert "Zero-Config Target Event" not in source


def test_connect_view_rendered_ui_configured(event, organizer_user, rf):
    """Verify template and view context in configured state use clean action buttons and full-width layout."""
    event.settings.set("veditor_api_key", "test-secret-key")
    event.settings.set("veditor_api_base_url", "https://editor.example.com")

    request = setup_request(rf.get(reverse("plugins:veditor:connect", kwargs={"organizer": event.organizer.slug, "event": event.slug})))
    request.user = organizer_user
    request.event = event
    request.organizer = event.organizer

    view = ConnectView.as_view()
    response = view(request, organizer=event.organizer.slug, event=event.slug)

    assert response.status_code == 200
    assert response.template_name == ["veditor/connect.html"]
    assert response.context_data["veditor_configured"] is True

    from django.template.loader import get_template

    template = get_template("veditor/connect.html")
    source = template.template.source

    assert "Video Editor (VEditor)" in source
    assert "Connected" in source
    assert "VEditor Connection & Studio" in source
    assert "Sync Schedule & Launch Studio" in source
    assert "Launch Studio" in source
    assert "veditor-dashboard-hero" not in source
    assert "Open Studio without Sync" not in source
    assert "Zero-Config Target Event" not in source


def test_room_recording_attachment_form_recording_start_timezone_validation(event):
    from veditor.forms import RoomRecordingAttachmentForm

    mock_room = SimpleNamespace(name="Main Hall")
    mock_rooms = MagicMock()
    mock_rooms.all.return_value.order_by.return_value = [mock_room]
    event.rooms = mock_rooms

    # Naive timestamp without timezone offset should be rejected
    form_naive = RoomRecordingAttachmentForm(
        event=event,
        data={
            "room": "Main Hall",
            "video_url": "https://example.com/video.mp4",
            "recording_start": "2026-09-25T09:00:00",
        },
    )
    assert not form_naive.is_valid()
    assert "recording_start" in form_naive.errors
    assert "must include a timezone offset" in str(form_naive.errors["recording_start"])

    # Timezone-aware timestamp with UTC 'Z' should be accepted
    form_utc = RoomRecordingAttachmentForm(
        event=event,
        data={
            "room": "Main Hall",
            "video_url": "https://example.com/video.mp4",
            "recording_start": "2026-09-25T09:00:00Z",
        },
    )
    assert form_utc.is_valid()

    # Timezone-aware timestamp with explicit offset should be accepted
    form_offset = RoomRecordingAttachmentForm(
        event=event,
        data={
            "room": "Main Hall",
            "video_url": "https://example.com/video.mp4",
            "recording_start": "2026-09-25T09:00:00+02:00",
        },
    )
    assert form_offset.is_valid()
