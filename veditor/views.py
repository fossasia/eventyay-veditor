"""Views for the VEditor Eventyay plugin."""

from __future__ import annotations

import os
from typing import Any

from django.contrib import messages
from django.http import HttpResponseRedirect
from django.shortcuts import redirect
from django.urls import reverse
from django.utils.translation import gettext_lazy as _
from django.views.generic import TemplateView
from django_scopes import scope
from eventyay.base.models import TalkSlot
from eventyay.control.permissions import EventPermissionRequiredMixin

from .client import VEditorClient
from .exceptions import VEditorConfigError, VEditorError
from .forms import VEditorSettingsForm


class ConnectView(EventPermissionRequiredMixin, TemplateView):
    """View to view event sync status and launch VEditor with single-click SSO."""

    permission = "can_change_event_settings"
    template_name = "veditor/connect.html"

    def get_talk_slots(self) -> list[TalkSlot]:
        """Fetch all scheduled and confirmed talk slots for the current active schedule."""
        event = self.request.event
        with scope(event=event):
            schedule = getattr(event, "current_schedule", None) or getattr(event, "wip_schedule", None)

            if not schedule:
                return []

            if hasattr(schedule, "scheduled_talks"):
                slots = list(schedule.scheduled_talks)
            else:
                slots = list(schedule.talks.filter(submission__isnull=False).select_related("submission", "room").order_by("start"))

            # Deduplicate by slot occurrence identity to avoid multiples across schedule revisions
            seen_slot_ids = set()
            unique_slots = []
            for slot in slots:
                slot_id = getattr(slot, "id", None)
                if slot_id is not None:
                    if slot_id not in seen_slot_ids:
                        seen_slot_ids.add(slot_id)
                        unique_slots.append(slot)
                else:
                    unique_slots.append(slot)

            return unique_slots

    def get_context_data(self, **kwargs: Any) -> dict[str, Any]:
        """Populate template context with event details, talk counts, and settings form."""
        context = super().get_context_data(**kwargs)
        event = self.request.event
        talk_slots = self.get_talk_slots()

        context["event"] = event
        context["talks"] = talk_slots
        context["talks_count"] = len(talk_slots)

        # Pre-populate form with saved event settings or platform environment defaults
        saved_url = (
            (event.settings.get("veditor_api_base_url") if hasattr(event, "settings") else None)
            or os.environ.get("VEDITOR_API_BASE_URL")
            or "http://localhost:8080"
        )
        saved_key = (event.settings.get("veditor_api_key") if hasattr(event, "settings") else None) or os.environ.get("VEDITOR_API_KEY")
        has_saved_key = bool(saved_key)

        if "form" not in context:
            context["form"] = VEditorSettingsForm(
                initial={
                    "veditor_api_base_url": saved_url,
                },
                has_existing_key=has_saved_key,
            )

        try:
            client = VEditorClient(event=event)
            context["veditor_configured"] = bool(client.api_key)
            context["veditor_base_url"] = client.base_url
        except VEditorConfigError as exc:
            context["veditor_configured"] = False
            context["config_error"] = str(exc)

        return context

    def post(self, request, *args, **kwargs):
        """Handle saving settings or executing talk synchronization and redirect."""
        event = request.event
        action = request.POST.get("action")
        saved_key = (event.settings.get("veditor_api_key") if hasattr(event, "settings") else None) or os.environ.get("VEDITOR_API_KEY")
        has_saved_key = bool(saved_key)

        if action == "save_settings":
            form = VEditorSettingsForm(request.POST, has_existing_key=has_saved_key)
            if form.is_valid():
                if hasattr(event, "settings"):
                    base_url_val = (form.cleaned_data.get("veditor_api_base_url") or "").strip()
                    if base_url_val:
                        event.settings.set("veditor_api_base_url", base_url_val.rstrip("/"))
                    elif "veditor_api_base_url" in form.cleaned_data:
                        event.settings.set("veditor_api_base_url", "")

                    new_key = (form.cleaned_data.get("veditor_api_key") or "").strip()
                    if new_key:
                        event.settings.set("veditor_api_key", new_key)

                messages.success(request, _("VEditor connection settings saved successfully."))
                return redirect(
                    reverse(
                        "plugins:veditor:connect",
                        kwargs={"organizer": event.organizer.slug, "event": event.slug},
                    )
                )
            else:
                context = self.get_context_data(**kwargs)
                context["form"] = form
                return self.render_to_response(context)

        # Action: sync talks and launch VEditor, or open studio directly
        talk_slots = self.get_talk_slots()

        try:
            client = VEditorClient(event=event)
            # Auto-resolve target event ID from the event-scoped API key
            target_event_id = client.get_scoped_event_id()
        except (VEditorError, ValueError) as exc:
            messages.error(
                request,
                _("Failed to connect to VEditor: {error}").format(error=str(exc)),
            )
            context = self.get_context_data(**kwargs)
            return self.render_to_response(context)

        # 1. Bulk synchronize talks unless explicitly skipped (open_studio action)
        if action != "open_studio":
            try:
                client.sync_talks(event_id=target_event_id, talk_slots=talk_slots)
            except (VEditorError, ValueError) as exc:
                messages.error(
                    request,
                    _("Failed to synchronize talks with VEditor: {error}").format(error=str(exc)),
                )
                context = self.get_context_data(**kwargs)
                return self.render_to_response(context)

        # 2. Request scoped SSO JWT for organizer with user identity
        user_email = getattr(request.user, "email", None) if getattr(request, "user", None) and request.user.is_authenticated else None
        display_name = None
        if getattr(request, "user", None) and request.user.is_authenticated:
            display_name = getattr(request.user, "fullname", None) or getattr(request.user, "name", None)
            if not display_name and hasattr(request.user, "get_display_name"):
                display_name = request.user.get_display_name()

        try:
            token = client.request_sso_jwt(
                event_id=target_event_id,
                role="organizer",
                email=user_email,
                display_name=display_name,
            )
            # The SSO token is transmitted via a short-lived query param on initial landing.
            # VEditor immediately consumes it, exchanges it for an HttpOnly cookie, and issues
            # an HTTP 303 redirect that strips the token parameter from the browser URL,
            # mitigating exposure in browser history and logs.
            redirect_url = f"{client.base_url}/studio?event_id={target_event_id}&sso_token={token}"
            return HttpResponseRedirect(redirect_url)
        except (VEditorError, ValueError) as exc:
            messages.error(
                request,
                _("Failed to establish VEditor SSO session: {error}").format(error=str(exc)),
            )
            context = self.get_context_data(**kwargs)
            return self.render_to_response(context)
