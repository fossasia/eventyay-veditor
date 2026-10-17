"""Views for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
import os
from typing import Any
from urllib.parse import urlencode, urlparse

from django.conf import settings
from django.contrib import messages
from django.contrib.auth.mixins import LoginRequiredMixin
from django.core.exceptions import PermissionDenied
from django.http import Http404, HttpResponseRedirect
from django.shortcuts import redirect
from django.urls import reverse
from django.utils.http import url_has_allowed_host_and_scheme
from django.utils.translation import gettext_lazy as _
from django.views import View
from django.views.generic import TemplateView
from django_scopes import scope, scopes_disabled
from eventyay.base.models import TalkSlot

try:
    from eventyay.base.models import Event, Submission
except ImportError:
    Event = None  # type: ignore
    Submission = None  # type: ignore
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
        has_event_secret = bool(event.settings.get("veditor_webhook_secret")) if hasattr(event, "settings") else False
        global_secret = (
            getattr(settings, "VEDITOR_WEBHOOK_SECRET", None) or os.environ.get("VEDITOR_WEBHOOK_SECRET") or os.environ.get("EVENTYAY_VEDITOR_WEBHOOK_SECRET")
        )
        has_global_secret = bool(global_secret)
        has_saved_secret = bool(has_event_secret or has_global_secret)
        saved_review_days = event.settings.get("speaker_review_window_days") if hasattr(event, "settings") else None
        if saved_review_days is None:
            saved_review_days = 7
        else:
            try:
                saved_review_days = int(saved_review_days)
            except (ValueError, TypeError):
                saved_review_days = 7

        if "form" not in context:
            context["form"] = VEditorSettingsForm(
                initial={
                    "veditor_api_base_url": saved_url,
                    "speaker_review_window_days": saved_review_days,
                },
                has_existing_key=has_saved_key,
                has_existing_secret=has_event_secret,
            )

        context["speaker_review_window_days"] = saved_review_days

        try:
            client = VEditorClient(event=event)
            context["veditor_configured"] = bool(client.api_key)
            context["veditor_base_url"] = client.base_url
        except VEditorConfigError as exc:
            context["veditor_configured"] = False
            context["config_error"] = str(exc)

        try:
            webhook_path = reverse("plugins:veditor:webhook")
            base_webhook_url = self.request.build_absolute_uri(webhook_path)
        except Exception:
            base_webhook_url = self.request.build_absolute_uri("/api/v1/veditor/webhook/")

        event_slug = getattr(event, "slug", None)
        if event_slug:
            sep = "&" if "?" in base_webhook_url else "?"
            context["inbound_webhook_url"] = f"{base_webhook_url}{sep}event={event_slug}"
        else:
            context["inbound_webhook_url"] = base_webhook_url
        context["has_event_scoped_secret"] = has_event_secret
        context["has_global_secret"] = has_global_secret
        context["veditor_webhook_secret_configured"] = has_saved_secret

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
        has_event_secret = bool(event.settings.get("veditor_webhook_secret")) if hasattr(event, "settings") else False

        if action == "save_settings":
            form = VEditorSettingsForm(
                request.POST,
                has_existing_key=has_saved_key,
                has_existing_secret=has_event_secret,
            )
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

                    new_secret = (form.cleaned_data.get("veditor_webhook_secret") or "").strip()
                    if new_secret:
                        event.settings.set("veditor_webhook_secret", new_secret)

                    if "speaker_review_window_days" in request.POST:
                        review_window = form.cleaned_data.get("speaker_review_window_days")
                        if review_window is not None:
                            event.settings.set("speaker_review_window_days", int(review_window))
                        else:
                            event.settings.set("speaker_review_window_days", 7)

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


class SpeakerReviewLaunchView(LoginRequiredMixin, View):
    """View to launch direct 1-click video review for a confirmed session with an on-demand speaker SSO JWT."""

    def get_fallback_url(self, request, event: Any = None) -> str:
        """Resolve a safe return URL when launch cannot proceed."""
        referer = request.META.get("HTTP_REFERER")
        if referer and url_has_allowed_host_and_scheme(
            url=referer,
            allowed_hosts={request.get_host()},
            require_https=request.is_secure(),
        ):
            return referer

        try:
            return reverse("eventyay_common:sessions")
        except Exception:
            pass

        if event and getattr(event, "slug", None):
            org_slug = getattr(getattr(event, "organizer", None), "slug", None)
            if org_slug:
                try:
                    return reverse(
                        "cfp:event.user.submissions",
                        kwargs={"organizer": org_slug, "event": event.slug},
                    )
                except Exception:
                    pass

        return "/"

    def get(self, request, *args: Any, **kwargs: Any) -> HttpResponseRedirect:
        event_slug = kwargs.get("event")
        organizer_slug = kwargs.get("organizer")
        talk_code = kwargs.get("talk_code") or kwargs.get("code")

        event_obj = getattr(request, "event", None)
        if not event_obj and Event is not None:
            with scopes_disabled():
                event_obj = Event.objects.filter(slug=event_slug, organizer__slug=organizer_slug).first()
                if not event_obj and str(event_slug).isdigit():
                    event_obj = Event.objects.filter(id=int(event_slug), organizer__slug=organizer_slug).first()

        if not event_obj:
            raise Http404(_("Event not found."))

        submission = getattr(request, "submission", None)
        if not submission:
            try:
                with scope(event=event_obj):
                    if Submission is not None and getattr(event_obj, "id", None):
                        submission = Submission.objects.filter(code=talk_code).select_related("event", "event__organizer").prefetch_related("speakers").first()
                        if not submission and str(talk_code).isdigit():
                            submission = (
                                Submission.objects.filter(id=int(talk_code)).select_related("event", "event__organizer").prefetch_related("speakers").first()
                            )
            except Exception as db_exc:
                logger.debug("Could not query submission from database: %s", db_exc)

        if not submission:
            raise Http404(_("Talk submission not found."))

        user = request.user
        user_email = (getattr(user, "email", None) or "").strip().lower()

        is_speaker = False
        speakers_attr = getattr(submission, "speakers", None)
        if user_email and speakers_attr:
            speakers = speakers_attr.all() if callable(getattr(speakers_attr, "all", None)) else speakers_attr
            for sp in speakers:
                sp_email = (getattr(sp, "email", None) or "").strip().lower()
                if sp_email and sp_email == user_email:
                    is_speaker = True
                    break

        has_event_perm = hasattr(user, "has_event_permission") and user.has_event_permission(
            getattr(event_obj, "organizer", None),
            event_obj,
            "can_change_event_settings",
            request=request,
        )

        if not is_speaker and not has_event_perm:
            raise PermissionDenied(_("You do not have permission to review this session."))

        # Strict state check: only confirmed sessions can be reviewed
        if getattr(submission, "state", None) != "confirmed":
            messages.warning(
                request,
                _("Video review is only available for confirmed sessions on the event schedule."),
            )
            return HttpResponseRedirect(self.get_fallback_url(request, event_obj))

        try:
            client = VEditorClient(event=event_obj)
        except VEditorConfigError as exc:
            logger.warning("VEditor client configuration error for %s: %s", getattr(event_obj, "slug", ""), exc)
            messages.error(
                request,
                _("Video review is not configured for this event. Please contact the event organizer."),
            )
            return HttpResponseRedirect(self.get_fallback_url(request, event_obj))

        target_event_id = str(event_obj.id)
        try:
            if hasattr(client, "get_scoped_event_id"):
                scoped = client.get_scoped_event_id()
                if scoped:
                    target_event_id = str(scoped)
        except Exception as scoped_exc:
            logger.debug("Could not resolve scoped event ID: %s", scoped_exc)

        display_name = getattr(user, "fullname", None) or getattr(user, "name", None)
        if not display_name and hasattr(user, "get_display_name"):
            display_name = user.get_display_name()
        display_name = display_name or user_email

        submission_code = getattr(submission, "code", talk_code)

        try:
            sso_res = client.request_sso_jwt(
                event_id=target_event_id,
                talk_id=str(submission_code),
                role="speaker",
                email=user_email,
                display_name=display_name,
                return_response_data=True,
            )
            if isinstance(sso_res, tuple) and len(sso_res) == 2:
                token, sso_data = sso_res
            else:
                token, sso_data = str(sso_res), {}
        except (VEditorError, ValueError) as exc:
            # Only attempt talk-sync retry if talk was not found (HTTP 404)
            is_404 = getattr(exc, "status_code", None) == 404 or (getattr(getattr(exc, "response", None), "status_code", None) == 404)
            if not is_404:
                logger.warning(
                    "Failed to request speaker SSO JWT for submission %s: %s",
                    submission_code,
                    exc,
                )
                messages.error(
                    request,
                    _("Failed to launch video review. Please try again later or contact support."),
                )
                return HttpResponseRedirect(self.get_fallback_url(request, event_obj))

            try:
                target_slot = getattr(submission, "slots", None)
                slot_obj = target_slot.first() if target_slot and hasattr(target_slot, "first") else None
                if slot_obj is None:
                    slot_obj = submission
                client.sync_talk(slot_obj, event_id=target_event_id)
                sso_res = client.request_sso_jwt(
                    event_id=target_event_id,
                    talk_id=str(submission_code),
                    role="speaker",
                    email=user_email,
                    display_name=display_name,
                    return_response_data=True,
                )
                if isinstance(sso_res, tuple) and len(sso_res) == 2:
                    token, sso_data = sso_res
                else:
                    token, sso_data = str(sso_res), {}
            except Exception as retry_exc:
                logger.exception(
                    "Failed to establish speaker SSO session for submission %s (initial error: %s, retry error: %s)",
                    submission_code,
                    exc,
                    retry_exc,
                )
                messages.error(
                    request,
                    _("Failed to launch video review. Please try again later or contact support."),
                )
                return HttpResponseRedirect(self.get_fallback_url(request, event_obj))

        redirect_path = sso_data.get("url") if isinstance(sso_data, dict) else None
        if redirect_path:
            parsed_redirect = urlparse(redirect_path)
            if parsed_redirect.scheme in ("http", "https"):
                parsed_base = urlparse(client.base_url)
                allowed_netlocs = {parsed_base.netloc.lower()}
                raw_extra = getattr(settings, "VEDITOR_ALLOWED_ORIGINS", [])
                if isinstance(raw_extra, str):
                    extra_origins = [o.strip() for o in raw_extra.split(",") if o.strip()]
                elif isinstance(raw_extra, (list, tuple, set)):
                    extra_origins = list(raw_extra)
                else:
                    extra_origins = []

                for origin in extra_origins:
                    netloc = urlparse(origin).netloc or str(origin).strip()
                    if netloc:
                        allowed_netlocs.add(netloc.lower())

                if (parsed_redirect.netloc or "").lower() in allowed_netlocs:
                    redirect_url = redirect_path
                else:
                    logger.warning(
                        "SSO redirect host '%s' is not in allowed origins, falling back to client.base_url",
                        parsed_redirect.netloc,
                    )
                    query = urlencode({"sso_token": token})
                    redirect_url = f"{client.base_url}/studio/talks/{submission_code}?{query}"
            else:
                redirect_url = f"{client.base_url}/{redirect_path.lstrip('/')}"
        else:
            query = urlencode({"sso_token": token})
            redirect_url = f"{client.base_url}/studio/talks/{submission_code}?{query}"

        return HttpResponseRedirect(redirect_url)
