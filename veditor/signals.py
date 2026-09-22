"""Signal receivers for registering the VEditor plugin navigation tab."""

from __future__ import annotations

from django.dispatch import receiver
from django.urls import resolve, reverse
from django.utils.translation import gettext_lazy as _
from eventyay.control.signals import nav_event_common


@receiver(nav_event_common, dispatch_uid="veditor_nav_event_common")
def control_nav_veditor(sender, request=None, **kwargs) -> list[dict]:
    """Attach the Video Editor navigation tab in the organizer dashboard."""
    if not request or not getattr(request, "user", None) or not request.user.is_authenticated:
        return []

    organizer = getattr(sender, "organizer", None)
    if not organizer or not getattr(organizer, "slug", None) or not getattr(sender, "slug", None):
        return []

    if not request.user.has_event_permission(
        organizer,
        sender,
        "can_change_event_settings",
        request=request,
    ):
        return []

    try:
        resolved = resolve(request.path_info)
        is_active = resolved.namespace == "plugins:veditor" and resolved.url_name == "connect"
    except Exception:
        is_active = False

    return [
        {
            "label": _("Video Editor"),
            "url": reverse(
                "plugins:veditor:connect",
                kwargs={
                    "organizer": organizer.slug,
                    "event": sender.slug,
                },
            ),
            "active": is_active,
            "icon": "video-camera",
        }
    ]
