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
            if origin not in allowed:
                raise forms.ValidationError(_("The VEditor URL origin is not in the allowed list."))

        return url.rstrip("/")
