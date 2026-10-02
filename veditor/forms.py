"""Forms for VEditor integration settings."""

from __future__ import annotations

from typing import Any

from django import forms
from django.utils.translation import gettext_lazy as _


class VEditorSettingsForm(forms.Form):
    """Form to configure per-event VEditor connection credentials."""

    veditor_api_key = forms.CharField(
        label=_("VEditor API Key"),
        required=False,
        widget=forms.PasswordInput(
            render_value=False,
            attrs={"class": "form-control", "placeholder": "••••••••"},
        ),
        help_text=_("The client API key generated in VEditor for this event."),
    )
    veditor_api_base_url = forms.URLField(
        label=_("VEditor Service URL"),
        required=False,
        widget=forms.URLInput(attrs={"class": "form-control", "placeholder": "http://localhost:8080"}),
        help_text=_("Optional: Custom VEditor service URL. If blank, the system default URL is used."),
    )

    def __init__(self, *args: Any, has_existing_key: bool = False, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.has_existing_key = has_existing_key
        if has_existing_key:
            self.fields["veditor_api_key"].help_text = _("Leave blank to keep the currently configured API key, or enter a new key to update.")
        else:
            self.fields["veditor_api_key"].widget.attrs["placeholder"] = _("API key generated in VEditor")

    def clean_veditor_api_key(self) -> str:
        key = (self.cleaned_data.get("veditor_api_key") or "").strip()
        if not key and not self.has_existing_key:
            raise forms.ValidationError(_("This field is required."))
        return key

    def clean_veditor_api_base_url(self) -> str:
        """Validate base URL scheme and optional origin allowlist if provided."""
        from urllib.parse import urlparse

        from django.conf import settings

        url = (self.cleaned_data.get("veditor_api_base_url") or "").strip()
        if not url:
            return ""

        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise forms.ValidationError(_("Invalid URL. Must begin with http:// or https://."))

        hostname = (parsed.hostname or "").lower()
        is_loopback = hostname in ("localhost", "127.0.0.1", "::1")
        if parsed.scheme == "http" and not is_loopback:
            raise forms.ValidationError(_("Insecure HTTP is only permitted for local development (localhost/127.0.0.1). Production URLs must use HTTPS."))

        allowed = getattr(settings, "VEDITOR_ALLOWED_ORIGINS", None)
        if allowed:
            origin = f"{parsed.scheme}://{parsed.netloc}"
            if origin not in allowed and parsed.netloc not in allowed and hostname not in allowed:
                raise forms.ValidationError(_("The VEditor URL origin is not in the allowed list."))

        return url.rstrip("/")


class RoomRecordingAttachmentForm(forms.Form):
    """Form to attach a shared room recording file to scheduled talks in an event room."""

    room = forms.ChoiceField(
        label=_("Room"),
        required=True,
        widget=forms.Select(attrs={"class": "form-control"}),
        help_text=_("Select the authoritative event room where this recording took place."),
    )
    source_path = forms.CharField(
        label=_("Recording Storage Path"),
        required=False,
        widget=forms.TextInput(
            attrs={
                "class": "form-control",
                "placeholder": "/media/ingest/day1/hall_a.mp4",
            }
        ),
        help_text=_("Absolute file path on shared storage or media mount accessible to VEditor."),
    )
    relative_key = forms.CharField(
        label=_("Relative Ingest Key"),
        required=False,
        widget=forms.TextInput(
            attrs={
                "class": "form-control",
                "placeholder": "recordings/hall_a.mp4",
            }
        ),
        help_text=_("Path relative to VEditor's configured ingest roots (if using ingest roots)."),
    )
    recording_start = forms.CharField(
        label=_("Recording Start Time (Optional)"),
        required=False,
        widget=forms.TextInput(
            attrs={
                "class": "form-control",
                "placeholder": "2026-09-25T09:00:00Z",
            }
        ),
        help_text=_("Optional ISO-8601 start time if the recording started earlier or later than the first talk."),
    )

    def __init__(self, *args: Any, event: Any = None, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        if event is not None and hasattr(event, "rooms"):
            rooms = list(event.rooms.all().order_by("name"))
            self.fields["room"].choices = [(r.name, r.name) for r in rooms]
            if not self.fields["room"].choices:
                self.fields["room"].choices = [("", _("No rooms found for this event"))]

    def clean(self) -> dict[str, Any]:
        cleaned_data = super().clean()
        source_path = (cleaned_data.get("source_path") or "").strip()
        relative_key = (cleaned_data.get("relative_key") or "").strip()
        recording_start = (cleaned_data.get("recording_start") or "").strip()

        if not source_path and not relative_key:
            raise forms.ValidationError(_("You must specify either a Recording Storage Path or a Relative Ingest Key."))

        cleaned_data["source_path"] = source_path
        cleaned_data["relative_key"] = relative_key
        cleaned_data["recording_start"] = recording_start
        return cleaned_data
