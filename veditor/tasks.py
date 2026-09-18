"""Celery tasks for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.core.mail import EmailMultiAlternatives
from django.template.loader import render_to_string
from eventyay.base.models import Event, Submission, TalkSlot

try:
    from django_scopes import scopes_disabled
except ImportError:
    from contextlib import nullcontext as scopes_disabled

from .client import VEditorClient
from .exceptions import (
    VEditorConfigError,
    VEditorError,
    VEditorNetworkError,
)

logger = logging.getLogger(__name__)

try:
    from eventyay.celery_app import app

    task_decorator = app.task
except ImportError:
    from celery import shared_task

    task_decorator = shared_task


@task_decorator(
    name="veditor.process_talk_approved",
    bind=True,
    autoretry_for=(VEditorNetworkError,),
    retry_backoff=True,
    max_retries=3,
)
def process_talk_approved(
    self: Any,
    event_id: int | str | None = None,
    talk_id: int | str = "",
    external_id: str | None = None,
    raw_payload: dict[str, Any] | None = None,
    force: bool = False,
) -> dict[str, Any]:
    """Process a talk.approved signal from VEditor and dispatch magic links to speakers.

    Steps:
    1. Resolve Event and Submission/TalkSlot using external_id, talk_id, or event_id.
    2. Extract speakers associated with the submission.
    3. Mint a talk-scoped speaker SSO JWT via VEditorClient.
    4. Construct the studio magic link: <base_url>/studio/talks/<talk_id>?sso_token=<token>.
    5. Render plain-text and responsive HTML email templates.
    6. Dispatch the notification email with Celery retry handling for network transient errors.
    """
    logger.info(
        "Processing talk.approved for event_id=%s, talk_id=%s, external_id=%s, force=%s",
        event_id,
        talk_id,
        external_id,
        force,
    )

    with scopes_disabled():
        # 1. Resolve Event
        event_obj: Event | None = None
        if event_id is not None:
            if str(event_id).isdigit():
                event_obj = Event.objects.filter(id=int(event_id)).first()
            if not event_obj:
                event_obj = Event.objects.filter(slug=str(event_id)).first()

        # 2. Resolve Submission and TalkSlot strictly scoped to event_obj when available
        submission: Submission | None = None
        talk_slot: TalkSlot | None = None

        if external_id:
            if event_obj:
                submission = Submission.objects.filter(event=event_obj, code=str(external_id)).first()
                if not submission and str(external_id).isdigit():
                    submission = Submission.objects.filter(event=event_obj, id=int(external_id)).first()
                if not submission and str(external_id).isdigit():
                    talk_slot = TalkSlot.objects.filter(submission__event_id=event_obj.id, id=int(external_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission
            else:
                submission = Submission.objects.filter(code=str(external_id)).first()
                if not submission and str(external_id).isdigit():
                    submission = Submission.objects.filter(id=int(external_id)).first()
                if not submission and str(external_id).isdigit():
                    talk_slot = TalkSlot.objects.filter(id=int(external_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission

        if not submission and talk_id:
            if event_obj:
                submission = Submission.objects.filter(event=event_obj, code=str(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    submission = Submission.objects.filter(event=event_obj, id=int(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    talk_slot = TalkSlot.objects.filter(submission__event_id=event_obj.id, id=int(talk_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission
            else:
                submission = Submission.objects.filter(code=str(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    submission = Submission.objects.filter(id=int(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    talk_slot = TalkSlot.objects.filter(id=int(talk_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission

        if submission and not event_obj:
            event_obj = getattr(submission, "event", None)
        if not event_obj and talk_slot and hasattr(talk_slot, "schedule"):
            event_obj = getattr(talk_slot.schedule, "event", None)

        if not submission:
            logger.error(
                "Could not resolve submission for talk approval: event_id=%s, talk_id=%s, external_id=%s",
                event_id,
                talk_id,
                external_id,
            )
            return {
                "status": "error",
                "error": "Submission not found",
                "event_id": event_id,
                "talk_id": talk_id,
                "external_id": external_id,
            }

        if not event_obj:
            logger.error("Could not resolve event for submission code=%s", submission.code)
            return {
                "status": "error",
                "error": "Event not found",
                "submission_code": submission.code,
            }

        # 3. Resolve Speakers
        speakers = list(submission.speakers.all())
        if not speakers:
            logger.warning("No speakers registered for submission code=%s", submission.code)
            return {
                "status": "skipped",
                "message": f"No speakers registered for talk {submission.code}",
                "talk_id": talk_id,
                "sent_count": 0,
            }

        # 4. Initialize VEditor Client
        client = VEditorClient(event=event_obj)
        if not client.base_url or not client.api_key:
            logger.error("VEditor client is not configured for event %s", event_obj.slug)
            raise VEditorConfigError(f"VEditor client is not configured for event {event_obj.slug}")

        # 5. Generate SSO token and dispatch emails
        sent_recipients: list[str] = []
        failed_recipients: list[dict[str, str]] = []
        resolved_talk_id = str(talk_id) if talk_id else str(external_id or submission.code)

        # Resolve remote or local VEditor-scoped event ID
        target_event_id = str(event_obj.id)
        try:
            if hasattr(client, "get_scoped_event_id"):
                scoped = client.get_scoped_event_id()
                if scoped:
                    target_event_id = str(scoped)
        except Exception as scoped_exc:
            logger.debug("Could not resolve scoped event ID: %s", scoped_exc)

        # If talk_id is non-numeric (e.g. passed from submission code), auto-resolve integer ID via VEditor sync
        if not resolved_talk_id.isdigit():
            try:
                target_slot = talk_slot or (submission.slots.first() if hasattr(submission, "slots") else None) or submission
                sync_resp = client.sync_talk(target_slot, event_id=target_event_id)
                if isinstance(sync_resp, dict) and "id" in sync_resp:
                    resolved_talk_id = str(sync_resp["id"])
                    logger.info("Resolved VEditor integer talk_id=%s for submission %s", resolved_talk_id, submission.code)
            except Exception as sync_exc:
                logger.warning("Could not auto-resolve integer talk_id from VEditor for %s: %s", submission.code, sync_exc)

        for speaker in speakers:
            speaker_email = getattr(speaker, "email", None)
            if not speaker_email:
                logger.warning("Speaker %s has no email address, skipping", speaker)
                continue

            # Idempotency check across retries and duplicate webhooks
            delivery_key = f"veditor:sent_review:{getattr(event_obj, 'id', '')}:{getattr(submission, 'id', '')}:{speaker_email}"
            if not force and cache.get(delivery_key):
                logger.info("Speaker review already dispatched to %s, skipping", speaker_email)
                sent_recipients.append(speaker_email)
                continue

            display_name = getattr(speaker, "fullname", None) or getattr(speaker, "name", None)
            if not display_name and hasattr(speaker, "get_display_name"):
                display_name = speaker.get_display_name()
            display_name = display_name or speaker_email

            try:
                token = client.request_sso_jwt(
                    event_id=target_event_id,
                    talk_id=resolved_talk_id,
                    role="speaker",
                    email=speaker_email,
                    display_name=display_name,
                )
            except VEditorNetworkError:
                logger.warning(
                    "Transient network failure requesting SSO token for %s; triggering retry",
                    speaker_email,
                )
                raise
            except (VEditorError, ValueError) as exc:
                logger.exception("Failed to generate speaker SSO token for %s: %s", speaker_email, exc)
                failed_recipients.append({"email": speaker_email, "error": str(exc)})
                continue

            magic_link = f"{client.base_url}/studio/talks/{resolved_talk_id}?sso_token={token}"

            context = {
                "event": event_obj,
                "submission": submission,
                "talk_title": submission.title,
                "speaker": speaker,
                "speaker_name": display_name,
                "magic_link": magic_link,
            }

            subject = f"[{event_obj.name}] Video Review Ready: {submission.title}"
            body_text = render_to_string("veditor/mail/speaker_review.txt", context)
            body_html = render_to_string("veditor/mail/speaker_review.html", context)

            sender = (event_obj.settings.get("mail_from") if hasattr(event_obj, "settings") else None) or getattr(
                settings, "DEFAULT_FROM_EMAIL", "noreply@eventyay.com"
            )

            msg = EmailMultiAlternatives(
                subject=subject,
                body=body_text,
                from_email=sender,
                to=[speaker_email],
            )
            msg.attach_alternative(body_html, "text/html")
            msg.send(fail_silently=False)

            if not force:
                cache.set(delivery_key, True, timeout=86400 * 7)

            sent_recipients.append(speaker_email)
            logger.info("Dispatched speaker review magic link for talk %s to %s", resolved_talk_id, speaker_email)

        return {
            "status": "success",
            "event_id": event_obj.id,
            "talk_id": resolved_talk_id,
            "external_id": external_id or submission.code,
            "sent_count": len(sent_recipients),
            "recipients": sent_recipients,
            "failed": failed_recipients,
        }
