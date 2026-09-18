"""Unit and integration tests for the Connect view and navigation signals."""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from django.contrib.messages.storage.fallback import FallbackStorage
from django.contrib.sessions.middleware import SessionMiddleware
from django.core.exceptions import PermissionDenied
from django.test import RequestFactory
from django.urls import reverse

from veditor.exceptions import VEditorNetworkError, VEditorSyncError
from veditor.signals import control_nav_veditor
from veditor.views import ConnectView


def setup_request(request):
    """Helper to attach session and messages storage to a RequestFactory request."""
    middleware = SessionMiddleware(lambda req: None)
    middleware.process_request(request)
    request.session.save()
    request._messages = FallbackStorage(request)
    return request


class MockEventSettings:
    def __init__(self, data=None):
        self.data = data or {}

    def get(self, key, default=None):
        return self.data.get(key, default)

    def set(self, key, value):
        self.data[key] = value


@pytest.fixture
def event():
    """Mock event fixture avoiding database connections in CI."""
    organizer = SimpleNamespace(slug="test-org")
    schedule = SimpleNamespace(scheduled_talks=[])
    return SimpleNamespace(
        id=42,
        slug="test-conf",
        name="Test Conference 2026",
        organizer=organizer,
        settings=MockEventSettings(),
        current_schedule=schedule,
        wip_schedule=None,
        get_talk_slots=lambda: [],
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
