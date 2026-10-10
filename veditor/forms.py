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
    """Form to attach a room recording (via livestream/video URL or file upload) to scheduled talks."""

    room = forms.ChoiceField(
        label=_("Room"),
        required=True,
        widget=forms.Select(attrs={"class": "form-control"}),
        help_text=_("Select the authoritative event room where this recording took place."),
    )
    video_url = forms.URLField(
        label=_("Video / Livestream URL"),
        required=False,
        widget=forms.URLInput(
            attrs={
                "class": "form-control",
                "placeholder": "https://www.youtube.com/watch?v=... or https://vimeo.com/...",
            }
        ),
        help_text=_("Public or unlisted livestream/video link (YouTube, Vimeo, or direct video stream URL)."),
    )
    video_file = forms.FileField(
        label=_("Upload Video File"),
        required=False,
        widget=forms.ClearableFileInput(
            attrs={
                "class": "form-control",
                "accept": "video/*",
            }
        ),
        help_text=_("Select a local MP4, WebM, or video file to upload directly from your computer."),
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
            try:
                from django_scopes import scope
            except ImportError:
                scope = None

            if scope:
                with scope(event=event):
                    rooms = list(event.rooms.all().order_by("name"))
            else:
                rooms = list(event.rooms.all().order_by("name"))

            self.fields["room"].choices = [(r.name, r.name) for r in rooms]
            if not self.fields["room"].choices:
                self.fields["room"].choices = [("", _("No rooms found for this event"))]

    def clean(self) -> dict[str, Any]:
        cleaned_data = super().clean()
        video_url = (cleaned_data.get("video_url") or "").strip()
        video_file = cleaned_data.get("video_file")
        recording_start = (cleaned_data.get("recording_start") or "").strip()

        if not video_url and not video_file:
            raise forms.ValidationError(_("You must specify either a Video / Livestream URL or upload a Video File."))

        if video_url and video_file:
            raise forms.ValidationError(_("Please specify either a Video URL or upload a File, not both."))

        if recording_start:
            from datetime import datetime

            try:
                # Replace 'Z' with '+00:00' to support standard ISO-8601 UTC notation
                normalized_dt = recording_start.replace("Z", "+00:00") if recording_start.endswith("Z") else recording_start
                parsed_dt = datetime.fromisoformat(normalized_dt)
                if parsed_dt.tzinfo is None:
                    self.add_error(
                        "recording_start",
                        _("Recording start time must include a timezone offset (e.g., 2026-09-25T09:00:00Z or +02:00)."),
                    )
            except ValueError:
                self.add_error("recording_start", _("Recording start time must be a valid ISO-8601 formatted timestamp (e.g., 2026-09-25T09:00:00Z)."))

        cleaned_data["video_url"] = video_url
        cleaned_data["video_file"] = video_file
        cleaned_data["recording_start"] = recording_start
        return cleaned_data
