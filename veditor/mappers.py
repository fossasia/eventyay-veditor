"""Data mappers for serializing Eventyay talk slots to VEditor schemas."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any


def to_utc_isoformat(dt: datetime | None) -> str | None:
    """Normalize a datetime object to a UTC ISO-8601 string."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    else:
        dt = dt.astimezone(UTC)
    return dt.isoformat()


def serialize_talk(talk_slot: Any, event_id: str | None = None) -> dict[str, Any]:
    """Serialize an Eventyay TalkSlot into a VEditor talk dictionary.

    Extracts:
    - external_id: submission.code, talk_slot.id, or external_id
    - title: submission.title or talk_slot.description
    - room: room.name or None
    - start: ISO-8601 UTC timestamp
    - end: ISO-8601 UTC timestamp
    - event_id: explicit event_id or derived from submission/schedule event slug
    """
    # 1. Resolve external_id
    submission = getattr(talk_slot, "submission", None)
    external_id: str | None = None
    if submission is not None:
        external_id = getattr(submission, "code", None) or str(getattr(submission, "id", ""))
    if not external_id and hasattr(talk_slot, "id"):
        external_id = str(talk_slot.id)
    elif not external_id and isinstance(talk_slot, dict):
        external_id = str(talk_slot.get("external_id") or talk_slot.get("id") or "")

    # 2. Resolve title
    title = ""
    if submission is not None:
        title = getattr(submission, "title", "") or ""
    if not title:
        title = getattr(talk_slot, "description", "") or ""
    if not title and isinstance(talk_slot, dict):
        title = talk_slot.get("title", "")
    title = str(title) if title else ""

    # 3. Resolve room
    room_obj = getattr(talk_slot, "room", None)
    room: str | None = None
    if room_obj is not None:
        room = getattr(room_obj, "name", str(room_obj))
    elif isinstance(talk_slot, dict):
        room = talk_slot.get("room")
    room = str(room) if room else None

    # 4. Resolve start and end datetimes
    start_dt = getattr(talk_slot, "start", None) if not isinstance(talk_slot, dict) else talk_slot.get("start")
    end_dt = getattr(talk_slot, "end", None) if not isinstance(talk_slot, dict) else talk_slot.get("end")

    def _parse_and_normalize(dt_val: Any) -> str | None:
        if dt_val is None:
            return None
        if isinstance(dt_val, str):
            try:
                dt_obj = datetime.fromisoformat(dt_val)
            except (ValueError, TypeError) as exc:
                raise ValueError(f"Invalid ISO-8601 timestamp '{dt_val}': {exc}") from exc
            return to_utc_isoformat(dt_obj)
        if isinstance(dt_val, datetime):
            return to_utc_isoformat(dt_val)
        return str(dt_val)

    start_iso = _parse_and_normalize(start_dt)
    end_iso = _parse_and_normalize(end_dt)

    # 5. Resolve event_id
    resolved_event_id = event_id
    if resolved_event_id is None:
        if submission is not None and getattr(submission, "event", None):
            resolved_event_id = getattr(submission.event, "id", None) or getattr(submission.event, "slug", None)
        elif hasattr(talk_slot, "schedule") and getattr(talk_slot.schedule, "event", None):
            resolved_event_id = getattr(talk_slot.schedule.event, "id", None) or getattr(talk_slot.schedule.event, "slug", None)
        elif isinstance(talk_slot, dict):
            resolved_event_id = talk_slot.get("event_id")

    if resolved_event_id is not None and not isinstance(resolved_event_id, int):
        try:
            resolved_event_id = int(resolved_event_id)
        except (ValueError, TypeError):
            pass

    return {
        "external_id": external_id or "",
        "title": title,
        "room": room,
        "start": start_iso,
        "end": end_iso,
        "event_id": resolved_event_id,
    }


def serialize_talks(talk_slots: list[Any], event_id: str | None = None) -> list[dict[str, Any]]:
    """Serialize a list of TalkSlot instances to VEditor talk dictionaries, deduplicating records."""
    serialized = []
    seen = set()
    for slot in talk_slots:
        data = serialize_talk(slot, event_id=event_id)
        # Deduplicate on external_id when available, falling back to (event_id, title, start)
        ext_id = data.get("external_id")
        if ext_id:
            key = (data.get("event_id"), "ext", str(ext_id))
        else:
            key = (data.get("event_id"), "title_start", data.get("title"), data.get("start"))
        if key not in seen:
            seen.add(key)
            serialized.append(data)
    return serialized
