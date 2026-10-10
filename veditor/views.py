"""Views for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
import os
from typing import Any
from urllib.parse import urlencode

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
from .forms import RoomRecordingAttachmentForm, VEditorSettingsForm
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
                talks_qs = schedule.scheduled_talks
                if hasattr(talks_qs, "filter"):
                    slots = list(talks_qs.filter(submission__isnull=False).select_related("submission", "room").order_by("start"))
                else:
                    slots = list(talks_qs)
            elif hasattr(schedule, "talks"):
                slots = list(schedule.talks.filter(submission__isnull=False).select_related("submission", "room").order_by("start"))
            else:
                slots = []

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

        if "room_form" not in context:
            context["room_form"] = RoomRecordingAttachmentForm(event=event)

        rooms_list = []
        if hasattr(event, "rooms"):
            try:
                from django_scopes import scope
            except ImportError:
                scope = None

            if scope:
                with scope(event=event):
                    rooms_list = list(event.rooms.all().order_by("name"))
            else:
                rooms_list = list(event.rooms.all().order_by("name"))
        context["rooms"] = rooms_list
        context["rooms_count"] = len(rooms_list)

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
            if result.get("skipped"):
                skipped = ", ".join(result["skipped"])
                messages.info(
                    request,
                    _("Speaker review link was already dispatched to {recipients}.").format(recipients=skipped),
                )
            else:
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

        elif action == "sync_schedule":
            talk_slots = self.get_talk_slots()
            try:
                client = VEditorClient(event=event)
                target_event_id = client.get_scoped_event_id()
                res = client.sync_talks(event_id=target_event_id, talk_slots=talk_slots)
                imported_count = res.get("imported_count", len(talk_slots)) if isinstance(res, dict) else len(talk_slots)
                messages.success(
                    request,
                    _("Successfully synchronized {count} talk(s) with VEditor.").format(count=imported_count),
                )
            except (VEditorError, ValueError) as exc:
                logger.error("Failed to synchronize talks for event %s: %s", event.slug, exc)
                messages.error(
                    request,
                    _("Failed to synchronize talks with VEditor: {error}").format(error=str(exc)),
                )
            return redirect(
                reverse(
                    "plugins:veditor:connect",
                    kwargs={"organizer": event.organizer.slug, "event": event.slug},
                )
            )

        elif action == "attach_room_recording":
            room_form = RoomRecordingAttachmentForm(request.POST, request.FILES, event=event)
            if room_form.is_valid():
                room_name = room_form.cleaned_data["room"]
                video_url = room_form.cleaned_data.get("video_url") or None
                video_file = room_form.cleaned_data.get("video_file") or None
                recording_start = room_form.cleaned_data.get("recording_start") or None

                try:
                    client = VEditorClient(event=event)
                    target_event_id = client.get_scoped_event_id()

                    # 1. Automatically ensure talks & room schedules are synchronized first!
                    talk_slots = self.get_talk_slots()
                    try:
                        client.sync_talks(event_id=target_event_id, talk_slots=talk_slots)
                    except (VEditorError, ValueError) as sync_exc:
                        logger.error("Auto-sync prior to room attachment failed for %s: %s", room_name, sync_exc)
                        messages.error(
                            request,
                            _("Failed to synchronize schedule prior to attaching recording: {error}").format(error=str(sync_exc)),
                        )
                        return redirect(
                            reverse(
                                "plugins:veditor:connect",
                                kwargs={"organizer": event.organizer.slug, "event": event.slug},
                            )
                        )

                    # 2. Attach recording via URL or uploaded file
                    res = client.attach_room_recording(
                        room=room_name,
                        event_id=target_event_id,
                        video_url=video_url,
                        video_file=video_file,
                        recording_start=recording_start,
                    )
                    attached_count = res.get("attached_count", 0) if isinstance(res, dict) else 0
                    talk_ids = res.get("talk_ids", []) if isinstance(res, dict) else []
                    if talk_ids:
                        talk_ids_str = ", ".join(str(tid) for tid in talk_ids)
                        msg = _(
                            "Successfully attached room recording for room '{room}'. "
                            "{count} talk(s) matched (IDs: {talk_ids}) and queued for detection and cutting."
                        ).format(room=room_name, count=attached_count, talk_ids=talk_ids_str)
                    else:
                        msg = _("Successfully attached room recording for room '{room}'. {count} talk(s) matched and queued for detection and cutting.").format(
                            room=room_name, count=attached_count
                        )
                    messages.success(request, msg)
                except (VEditorError, ValueError) as exc:
                    logger.error("Failed attaching room recording for room %s: %s", room_name, exc)
                    messages.error(
                        request,
                        _("Failed to attach room recording: {error}").format(error=str(exc)),
                    )

                return redirect(
                    reverse(
                        "plugins:veditor:connect",
                        kwargs={"organizer": event.organizer.slug, "event": event.slug},
                    )
                )
            else:
                context = self.get_context_data(**kwargs)
                context["room_form"] = room_form
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
                        force=True,
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
                    force=True,
                )
                messages.success(request, _("Speaker review link has been queued for dispatch."))
            except Exception:
                try:
                    result = process_talk_approved(
                        event_id=getattr(event, "id", None),
                        talk_id=talk_id or external_id,
                        external_id=external_id,
                        force=True,
                    )
                except Exception as exc:
                    logger.exception("Speaker review dispatch failed: %s", exc)
                    messages.error(
                        request,
                        _("Failed to dispatch speaker review link: {error}").format(error=str(exc)),
                    )
                else:
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
            query_params = urlencode({"event_id": str(target_event_id), "sso_token": token})
            redirect_url = f"{client.base_url}/studio?{query_params}"
            return HttpResponseRedirect(redirect_url)
        except (VEditorError, ValueError) as exc:
            messages.error(
                request,
                _("Failed to establish VEditor SSO session: {error}").format(error=str(exc)),
            )
            context = self.get_context_data(**kwargs)
            return self.render_to_response(context)
