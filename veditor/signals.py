"""Signal receivers for registering the VEditor plugin navigation tab."""

from __future__ import annotations

import logging

from django.db import transaction
from django.dispatch import receiver
from django.urls import resolve, reverse
from django.utils.translation import gettext_lazy as _
from eventyay.control.signals import nav_event_common

logger = logging.getLogger(__name__)


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


try:
    from eventyay.agenda.signals import register_recording_provider
except ImportError:
    register_recording_provider = None

from .recording import VEditorRecordingProvider

if register_recording_provider is not None:

    @receiver(register_recording_provider, dispatch_uid="veditor_recording_provider")
    def agenda_recording_veditor(sender, **kwargs) -> VEditorRecordingProvider | None:
        """Register the VEditor recording provider for public talk schedules."""
        plugin_list = getattr(sender, "plugin_list", None)
        if isinstance(plugin_list, (list, tuple, set)):
            if "veditor" not in plugin_list:
                return None
        else:
            plugins = getattr(sender, "plugins", None)
            if not plugins or not isinstance(plugins, (str, list, tuple, set)):
                return None
            if isinstance(plugins, str):
                active_plugins = [p.strip() for p in plugins.split(",") if p.strip()]
            else:
                active_plugins = list(plugins)
            if "veditor" not in active_plugins:
                return None

        return VEditorRecordingProvider(sender)


try:
    from eventyay.schedule.signals import schedule_release
except ImportError:
    schedule_release = None

if schedule_release is not None:

    @receiver(schedule_release, dispatch_uid="veditor_schedule_release")
    def on_schedule_release(sender, schedule=None, user=None, **kwargs) -> None:
        """Automatically synchronize schedule and event metadata with VEditor when a schedule is released."""
        if not sender:
            return
        plugin_list = getattr(sender, "plugin_list", None)
        if isinstance(plugin_list, (list, tuple, set)):
            if "veditor" not in plugin_list:
                return
        else:
            plugins = getattr(sender, "plugins", None)
            if not plugins:
                return
            plugin_set = {p.strip() for p in str(plugins).split(",") if p.strip()}
            if "veditor" not in plugin_set:
                return

        from .tasks import sync_event_schedule_task

        event_id = getattr(sender, "id", None) or getattr(sender, "slug", None)
        if not event_id:
            return

        from django.conf import settings

        def _dispatch_sync() -> None:
            if getattr(settings, "DEBUG", False):
                try:
                    sync_event_schedule_task(event_id=event_id)
                    return
                except Exception as exc:
                    logger.warning("Inline sync_event_schedule_task failed for event %s: %s", event_id, exc)

            try:
                sync_event_schedule_task.delay(event_id=event_id)
            except Exception as delay_exc:
                logger.warning(
                    "Failed to enqueue sync_event_schedule_task.delay for %s: %s. Falling back to synchronous execution.",
                    event_id,
                    delay_exc,
                )
                try:
                    sync_event_schedule_task(event_id=event_id)
                except Exception as sync_exc:
                    logger.warning("Synchronous fallback for sync_event_schedule_task failed for %s: %s", event_id, sync_exc)

        transaction.on_commit(_dispatch_sync)
