"""Views for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
import os
from typing import Any
from urllib.parse import urlparse

from django.conf import settings
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
from .tasks import process_talk_approved

logger = logging.getLogger(__name__)


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

    def _display_dispatch_result(self, request, result: Any) -> None:
        """Render user feedback based on the outcome of process_talk_approved."""
        if isinstance(result, dict) and result.get("sent_count", 0) > 0:
            recipients = ", ".join(result.get("recipients", []))
            messages.success(
                request,
                _("Speaker review link has been dispatched to {recipients}.").format(recipients=recipients),
            )
        elif isinstance(result, dict) and result.get("failed"):
            err_msg = result["failed"][0].get("error", "Unknown error")
            messages.error(
                request,
                _("Failed to dispatch speaker review link: {error}").format(error=err_msg),
            )
        elif isinstance(result, dict) and result.get("status") == "skipped":
            messages.warning(
                request,
                result.get("message", _("No speakers registered for this talk.")),
            )
        elif isinstance(result, dict) and result.get("status") == "error":
            err_msg = result.get("error", _("Unknown error"))
            messages.error(
                request,
                _("Failed to dispatch speaker review link: {error}").format(error=err_msg),
            )
        else:
            messages.warning(request, _("No speaker review link was dispatched."))

    def post(self, request, *args, **kwargs):
        """Handle saving settings or executing talk synchronization and redirect."""
        event = request.event
        action = request.POST.get("action")
        saved_key = (event.settings.get("veditor_api_key") if hasattr(event, "settings") else None) or os.environ.get("VEDITOR_API_KEY")
        has_saved_key = bool(saved_key)

        if action == "save_settings":
            form = VEditorSettingsForm(request.POST, has_existing_key=has_saved_key)
            if form.is_valid():
                base_url_val = (form.cleaned_data.get("veditor_api_base_url") or "").strip()
                new_key = (form.cleaned_data.get("veditor_api_key") or "").strip()

                current_url = (event.settings.get("veditor_api_base_url") if hasattr(event, "settings") else None) or ""
                if current_url and base_url_val:
                    cur_parsed = urlparse(current_url)
                    new_parsed = urlparse(base_url_val)
                    cur_origin = f"{cur_parsed.scheme}://{cur_parsed.netloc}"
                    new_origin = f"{new_parsed.scheme}://{new_parsed.netloc}"
                    if cur_origin != new_origin and not new_key:
                        form.add_error("veditor_api_key", _("A new API key is required when changing the VEditor server origin."))
                        context = self.get_context_data(**kwargs)
                        context["form"] = form
                        return self.render_to_response(context)

                if hasattr(event, "settings"):
                    if base_url_val:
                        event.settings.set("veditor_api_base_url", base_url_val.rstrip("/"))
                    elif "veditor_api_base_url" in form.cleaned_data:
                        event.settings.set("veditor_api_base_url", "")

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

        elif action == "resend_speaker_link":
            talk_id = request.POST.get("talk_id")
            external_id = request.POST.get("external_id") or request.POST.get("submission_code")
            if not external_id and not talk_id:
                messages.error(request, _("No talk selected for speaker review link dispatch."))
                return redirect(
                    reverse(
                        "plugins:veditor:connect",
                        kwargs={"organizer": event.organizer.slug, "event": event.slug},
                    )
                )

            if getattr(settings, "DEBUG", False):
                try:
                    result = process_talk_approved(
                        event_id=getattr(event, "id", None),
                        talk_id=talk_id or external_id,
                        external_id=external_id,
                    )
                    self._display_dispatch_result(request, result)
                    return redirect(
                        reverse(
                            "plugins:veditor:connect",
                            kwargs={"organizer": event.organizer.slug, "event": event.slug},
                        )
                    )
                except Exception as exc:
                    logger.warning("Direct dispatch failed, falling back to celery: %s", exc)

            try:
                process_talk_approved.delay(
                    event_id=getattr(event, "id", None),
                    talk_id=talk_id or external_id,
                    external_id=external_id,
                )
                messages.success(request, _("Speaker review link has been queued for dispatch."))
            except Exception:
                result = process_talk_approved(
                    event_id=getattr(event, "id", None),
                    talk_id=talk_id or external_id,
                    external_id=external_id,
                )
                self._display_dispatch_result(request, result)

            return redirect(
                reverse(
                    "plugins:veditor:connect",
                    kwargs={"organizer": event.organizer.slug, "event": event.slug},
                )
            )

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
