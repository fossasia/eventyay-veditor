"""Celery tasks for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
from typing import Any
from urllib.parse import urlparse

from django.conf import settings
from django.core.cache import cache
from django.core.mail import EmailMultiAlternatives
from django.template.loader import render_to_string

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

try:
    from eventyay.base.models import Event, QueuedMail, Submission, TalkSlot
except ImportError:
    Event = None  # type: ignore
    QueuedMail = None  # type: ignore
    Submission = None  # type: ignore
    TalkSlot = None  # type: ignore


@task_decorator(
    name="veditor.process_talk_approved",
    bind=True,
    autoretry_for=(VEditorNetworkError,),
    retry_backoff=True,
    max_retries=3,
)
def process_talk_approved(
    self: Any = None,
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
    5. Render email templates and dispatch using Eventyay's native QueuedMail (with EmailMultiAlternatives fallback).
    """
    # Allow calling directly as a function without bound task instance
    if self is not None and not hasattr(self, "request") and event_id is None:
        event_id = self
        self = None

    logger.info(
        "Processing talk.approved for event_id=%s, talk_id=%s, external_id=%s, force=%s",
        event_id,
        talk_id,
        external_id,
        force,
    )
    with scopes_disabled():
        # 1. Resolve Event
        event_obj: Any = None
        if event_id is not None and Event is not None:
            if str(event_id).isdigit():
                event_obj = Event.objects.filter(id=int(event_id)).first()
            if not event_obj:
                event_obj = Event.objects.filter(slug=str(event_id)).first()

        # 2. Resolve Submission and TalkSlot strictly scoped to event_obj when available
        submission: Any = None
        talk_slot: Any = None

        if external_id:
            if event_obj and Submission is not None:
                submission = Submission.objects.filter(event=event_obj, code=str(external_id)).first()
                if not submission and str(external_id).isdigit():
                    submission = Submission.objects.filter(event=event_obj, id=int(external_id)).first()
                if not submission and str(external_id).isdigit() and TalkSlot is not None:
                    talk_slot = TalkSlot.objects.filter(submission__event_id=event_obj.id, id=int(external_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission
            elif Submission is not None:
                submission = Submission.objects.filter(code=str(external_id)).first()
                if not submission and str(external_id).isdigit():
                    submission = Submission.objects.filter(id=int(external_id)).first()
                if not submission and str(external_id).isdigit() and TalkSlot is not None:
                    talk_slot = TalkSlot.objects.filter(id=int(external_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission

        if not submission and talk_id:
            if event_obj and Submission is not None:
                submission = Submission.objects.filter(event=event_obj, code=str(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    submission = Submission.objects.filter(event=event_obj, id=int(talk_id)).first()
                if not submission and str(talk_id).isdigit() and TalkSlot is not None:
                    talk_slot = TalkSlot.objects.filter(submission__event_id=event_obj.id, id=int(talk_id)).select_related("submission").first()
                    if talk_slot:
                        submission = talk_slot.submission
            elif Submission is not None:
                submission = Submission.objects.filter(code=str(talk_id)).first()
                if not submission and str(talk_id).isdigit():
                    submission = Submission.objects.filter(id=int(talk_id)).first()
                if not submission and str(talk_id).isdigit() and TalkSlot is not None:
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
        speakers = list(submission.speakers.all()) if hasattr(submission, "speakers") else []
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
        skipped_recipients: list[str] = []
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

        missing_email_speakers: list[str] = []
        task_id_val = getattr(getattr(self, "request", None), "id", None)

        for speaker in speakers:
            speaker_email = getattr(speaker, "email", None)
            if not speaker_email:
                speaker_name = getattr(speaker, "fullname", None) or getattr(speaker, "name", None) or str(speaker)
                logger.warning("Speaker %s has no email address, skipping", speaker_name)
                missing_email_speakers.append(speaker_name)
                continue

            # Idempotency check across retries and duplicate webhooks
            delivery_key = f"veditor:sent_review:{getattr(event_obj, 'id', '')}:{getattr(submission, 'id', '')}:{speaker_email}"
            task_sent_key = f"veditor:task_delivery:{task_id_val}:{speaker_email}" if task_id_val else None

            # Prevent duplicate email to already-sent speaker on Celery task retry
            if task_sent_key and cache.get(task_sent_key):
                logger.info("Speaker review already dispatched to %s in current task run, skipping", speaker_email)
                skipped_recipients.append(speaker_email)
                continue

            if not force and cache.get(delivery_key):
                logger.info("Speaker review already dispatched to %s, skipping", speaker_email)
                skipped_recipients.append(speaker_email)
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
            if len(subject) > 200:
                subject = subject[:197] + "..."
            body_text = render_to_string("veditor/mail/speaker_review.txt", context)

            # Dispatch using native Eventyay QueuedMail when available, else fallback to EmailMultiAlternatives
            if QueuedMail is not None:
                recipient_locale = str(getattr(speaker, "locale", None) or getattr(event_obj, "locale", None) or "en")[:32]
                mail_obj = QueuedMail.objects.create(
                    event=event_obj,
                    to=str(speaker_email)[:1000],
                    subject=subject,
                    text=body_text,
                    locale=recipient_locale,
                )
                speaker_pk = getattr(speaker, "pk", None) or getattr(speaker, "id", None)
                if speaker_pk and hasattr(mail_obj, "to_users"):
                    mail_obj.to_users.add(speaker)
                if hasattr(mail_obj, "submissions"):
                    mail_obj.submissions.add(submission)
                mail_obj.send()
            else:
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

            if task_sent_key:
                cache.set(task_sent_key, True, timeout=86400)
            cache.set(delivery_key, True, timeout=86400 * 7)

            sent_recipients.append(speaker_email)
            logger.info("Dispatched speaker review magic link for talk %s to %s", resolved_talk_id, speaker_email)

        for s_name in missing_email_speakers:
            failed_recipients.append({"speaker": s_name, "error": "missing_email"})

        if not sent_recipients and not skipped_recipients and missing_email_speakers:
            return {
                "status": "skipped",
                "reason": "missing_email",
                "message": "Registered speaker(s) do not have an email address configured",
                "event_id": getattr(event_obj, "id", None),
                "talk_id": resolved_talk_id,
                "external_id": external_id or submission.code,
                "sent_count": 0,
                "recipients": [],
                "skipped": [],
                "failed": failed_recipients,
            }

        status_result = "success" if sent_recipients else ("skipped" if skipped_recipients else ("error" if failed_recipients else "skipped"))
        return {
            "status": status_result,
            "event_id": getattr(event_obj, "id", None),
            "talk_id": resolved_talk_id,
            "external_id": external_id or submission.code,
            "sent_count": len(sent_recipients),
            "recipients": sent_recipients,
            "skipped": skipped_recipients,
            "failed": failed_recipients,
        }


@task_decorator(name="veditor.process_talk_published")
def process_talk_published(
    event_id: int | str,
    talk_id: int | str,
    video_url: str,
    external_id: str | None = None,
    raw_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Process an incoming talk.published webhook from VEditor.

    Attaches or updates the video recording resource on the Eventyay submission
    and marks the recording as ready for the public schedule.
    """
    logger.info(
        "Processing talk.published for event_id=%s, talk_id=%s, external_id=%s, video_url=%s",
        event_id,
        talk_id,
        external_id,
        video_url,
    )
    if not video_url or not isinstance(video_url, str) or not video_url.strip():
        logger.warning("Empty or invalid video_url received for talk.published: %r", video_url)
        return {
            "status": "error",
            "message": "Missing or invalid video_url",
            "event_id": event_id,
            "talk_id": talk_id,
        }

    video_url = video_url.strip()
    parsed_video = urlparse(video_url)
    if parsed_video.scheme not in ("http", "https") or not parsed_video.netloc:
        logger.warning("Empty or invalid video_url received for talk.published: %r", video_url)
        return {
            "status": "error",
            "message": "Missing or invalid video_url scheme/host",
            "event_id": event_id,
            "talk_id": talk_id,
        }

    try:
        from django.db import DatabaseError
        from django_scopes import scopes_disabled
        from eventyay.base.models import Event, Resource, TalkSlot
    except ImportError as exc:
        logger.error("Eventyay models not available: %s", exc)
        return {
            "status": "error",
            "message": f"Eventyay models not available: {exc}",
            "event_id": event_id,
            "talk_id": talk_id,
        }

    try:
        with scopes_disabled():
            # 1. Resolve event
            event_obj = None
            if event_id is not None and event_id != "":
                try:
                    if str(event_id).isdigit():
                        event_obj = Event.objects.filter(id=int(event_id)).first()
                    if not event_obj:
                        event_obj = Event.objects.filter(slug=str(event_id)).first()
                except (DatabaseError, RuntimeError) as exc:
                    logger.debug("Database error resolving event %s: %s", event_id, exc)

            if not event_obj:
                logger.warning("Event not found for talk.published: event_id=%s", event_id)
                return {
                    "status": "not_found",
                    "message": f"Event {event_id} not found",
                    "event_id": event_id,
                    "talk_id": talk_id,
                    "external_id": external_id,
                }

            # 2. Resolve submission strictly scoped to event_obj
            submission: Submission | None = None

            # Strategy A: by external_id (submission code, id, or slot id)
            if external_id:
                ext_str = str(external_id).strip()
                try:
                    submission = event_obj.submissions.filter(code__iexact=ext_str).first()
                except (DatabaseError, RuntimeError):
                    pass
                if not submission and ext_str.isdigit():
                    try:
                        submission = event_obj.submissions.filter(id=int(ext_str)).first()
                    except (DatabaseError, RuntimeError):
                        pass
                if not submission and ext_str.isdigit():
                    try:
                        slot = (
                            TalkSlot.objects.filter(
                                id=int(ext_str),
                                submission__event=event_obj,
                                submission__isnull=False,
                            )
                            .select_related("submission")
                            .first()
                        )
                        if slot:
                            submission = slot.submission
                    except (DatabaseError, RuntimeError):
                        pass

            # Strategy B: by talk_id (if talk_id is numeric)
            if not submission and talk_id is not None and str(talk_id).isdigit():
                talk_int = int(talk_id)
                try:
                    slot = (
                        TalkSlot.objects.filter(
                            id=talk_int,
                            submission__event=event_obj,
                            submission__isnull=False,
                        )
                        .select_related("submission")
                        .first()
                    )
                    if slot:
                        submission = slot.submission
                except (DatabaseError, RuntimeError):
                    pass
                if not submission:
                    try:
                        submission = event_obj.submissions.filter(id=talk_int).first()
                    except (DatabaseError, RuntimeError):
                        pass

            if not submission:
                logger.warning(
                    "Could not resolve Submission for talk.published: event_id=%s, talk_id=%s, external_id=%s",
                    event_id,
                    talk_id,
                    external_id,
                )
                return {
                    "status": "not_found",
                    "message": "Submission not found",
                    "event_id": event_id,
                    "talk_id": talk_id,
                    "external_id": external_id,
                }

            # Enforce cross-event tenant isolation
            sub_event_id = getattr(submission, "event_id", getattr(getattr(submission, "event", None), "id", None))
            if sub_event_id is not None and sub_event_id != event_obj.id:
                logger.error(
                    "Cross-event boundary violation: submission %s belongs to event %s, not %s",
                    submission.code,
                    sub_event_id,
                    event_obj.id,
                )
                return {
                    "status": "error",
                    "message": "Submission belongs to a different event",
                    "event_id": event_id,
                    "talk_id": talk_id,
                }

            # 3. Check do_not_record flag
            if getattr(submission, "do_not_record", False):
                logger.info(
                    "Submission %s has do_not_record set to True; skipping recording attachment.",
                    submission.code,
                )
                return {
                    "status": "skipped",
                    "reason": "do_not_record",
                    "submission_code": submission.code,
                }

            # 4. Update or create Resource safely without MultipleObjectsReturned
            resource = (
                Resource.objects.filter(
                    submission=submission,
                    description__iexact="Video Recording",
                )
                .order_by("id")
                .first()
            )
            created = False
            if resource:
                resource.link = video_url
                resource.kind = "generic"
                resource.save(update_fields=["link", "kind"])
            else:
                resource = Resource.objects.create(
                    submission=submission,
                    description="Video Recording",
                    link=video_url,
                    kind="generic",
                )
                created = True

            # 5. Provide backwards compatibility for recording_url attribute if present
            if hasattr(submission, "recording_url"):
                submission.recording_url = video_url
                try:
                    submission.save(update_fields=["recording_url"])
                except Exception as exc:  # noqa: BLE001
                    logger.warning(
                        "Failed updating recording_url on submission %s: %s",
                        getattr(submission, "code", None),
                        exc,
                    )

            logger.info(
                "Successfully synced recording URL for submission %s (Resource ID=%s, created=%s)",
                submission.code,
                resource.id,
                created,
            )

            return {
                "status": "success",
                "submission_code": submission.code,
                "video_url": video_url,
                "resource_id": resource.id,
                "created": created,
            }
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed processing talk.published for talk_id=%s: %s", talk_id, exc)
        return {
            "status": "error",
            "message": str(exc),
            "event_id": event_id,
            "talk_id": talk_id,
        }
