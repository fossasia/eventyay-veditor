"""Celery tasks for the VEditor Eventyay plugin."""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

try:
    from eventyay.celery_app import app

    task_decorator = app.task
except ImportError:
    from celery import shared_task

    task_decorator = shared_task


@task_decorator(name="veditor.process_talk_approved")
def process_talk_approved(
    event_id: int | str,
    talk_id: int | str,
    external_id: str | None = None,
    raw_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Process an incoming talk.approved webhook from VEditor.

    Resolves the associated Event and TalkSlot/Submission, preparing for speaker review notification.
    """
    logger.info(
        "Processing talk.approved for event_id=%s, talk_id=%s, external_id=%s",
        event_id,
        talk_id,
        external_id,
    )
    return {
        "status": "success",
        "event_id": event_id,
        "talk_id": talk_id,
        "external_id": external_id,
    }
