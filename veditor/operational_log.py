"""Privacy-safe operational logs for this plugin.

Delegates to the host logger when it is importable. Otherwise uses
``eventyay.plugins``. Logging never raises into product code.

Emails, names, tokens, secrets, and request or response bodies are dropped.
Only opaque IDs, status codes, durations, and safe error codes are kept.
"""

from __future__ import annotations

import functools
import inspect
import logging
import re
import time
from contextvars import ContextVar

try:
    from eventyay.base.operational_logging import (
        bind_job_id as _host_bind_job_id,
        get_job_id as _host_get_job_id,
        log_event as _HOST_LOG_EVENT,
        reset_job_id as _host_reset_job_id,
    )
except Exception:
    _HOST_LOG_EVENT = None
    _host_bind_job_id = None
    _host_get_job_id = None
    _host_reset_job_id = None

OUTCOME_SUCCESS = "success"
OUTCOME_FAILURE = "failure"

_SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_LOGGER = logging.getLogger("eventyay.plugins")
_job_id: ContextVar[str | None] = ContextVar("veditor_job_id", default=None)

_INT_FIELDS = frozenset(
    {
        "user_id",
        "status",
        "duration_ms",
        "retry_count",
    }
)
_IDENTIFIER_FIELDS = frozenset(
    {
        "error_code",
        "backend",
        "job_name",
        "job_id",
    }
)
_ID_FIELDS = frozenset({"event_id", "object_id"})


def _safe_identifier(value):
    if isinstance(value, str) and _SAFE_IDENTIFIER.fullmatch(value):
        return value
    return None


def _clean(fields):
    extra = {}
    for key, value in fields.items():
        if value is None or value == "":
            continue
        if key in _INT_FIELDS:
            if isinstance(value, bool) or not isinstance(value, int):
                continue
            extra[key] = value
            continue
        if key in _IDENTIFIER_FIELDS:
            cleaned = _safe_identifier(value if isinstance(value, str) else None)
            if cleaned is not None:
                extra[key] = cleaned
            continue
        if key in _ID_FIELDS:
            if isinstance(value, bool):
                continue
            if isinstance(value, int):
                extra[key] = value
            elif isinstance(value, str):
                cleaned = _safe_identifier(value)
                if cleaned is not None:
                    extra[key] = cleaned
    return extra


def log_operation(action, outcome, **fields):
    """Emit one allowlisted operational line. Failures are swallowed."""
    try:
        if not isinstance(action, str) or _safe_identifier(action) is None:
            return
        if outcome not in (OUTCOME_SUCCESS, OUTCOME_FAILURE):
            outcome = OUTCOME_FAILURE
        level = logging.WARNING if outcome == OUTCOME_FAILURE else logging.INFO
        payload = _clean(fields)
        if "job_id" not in payload:
            current_job_id = _safe_identifier(_job_id.get())
            if current_job_id is not None:
                payload["job_id"] = current_job_id
        if _HOST_LOG_EVENT is not None:
            try:
                _HOST_LOG_EVENT("plugins", action, outcome, level=level, **payload)
                return
            except Exception:
                pass
        extra = {
            "component": "plugins",
            "outcome": outcome,
            "action": action,
            **payload,
        }
        _LOGGER.log(level, action, extra=extra)
    except Exception:
        return


def log_plugin_loaded(backend):
    log_operation("plugin.loaded", OUTCOME_SUCCESS, backend=backend)


def _elapsed_ms(started):
    return int((time.monotonic() - started) * 1000)


def _extract_task_and_ids(sig, param_names, args, kwargs):
    candidate = args[0] if args else None
    task = candidate if (candidate is not None and hasattr(candidate, "request") and hasattr(candidate, "autoretry_for")) else None

    try:
        if task is not None or not args or args[0] is None or not param_names or param_names[0] != "self":
            bound_args = sig.bind_partial(*args, **kwargs).arguments
        else:
            bound_args = sig.bind_partial(None, *args, **kwargs).arguments
    except TypeError:
        bound_args = kwargs

    event_id = bound_args.get("event_id")
    object_id = bound_args.get("talk_id")
    if object_id is None or object_id == "":
        object_id = bound_args.get("external_id")
    return task, event_id, object_id


def traced_job(job_name):
    """Log job boundaries without changing the return value or exception."""

    def decorator(fn):
        sig = inspect.signature(fn)
        param_names = tuple(sig.parameters)

        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            task, event_id, object_id = _extract_task_and_ids(sig, param_names, args, kwargs)
            request = getattr(task, "request", None) if task is not None else None
            raw_job_id = getattr(request, "id", None) if request is not None else None
            job_id = _safe_identifier(raw_job_id) if isinstance(raw_job_id, str) else None
            retries = getattr(request, "retries", None) if request is not None else None
            retry_count = retries if isinstance(retries, int) and not isinstance(retries, bool) else None

            token = _job_id.set(job_id) if job_id is not None else None
            prev_host_job_id = None
            host_bound = False
            if job_id is not None and _host_bind_job_id is not None and _host_get_job_id is not None:
                try:
                    prev_host_job_id = _host_get_job_id()
                    _host_bind_job_id(job_id)
                    host_bound = True
                except Exception:
                    host_bound = False

            started = time.monotonic()
            try:
                log_operation(
                    "job.start",
                    OUTCOME_SUCCESS,
                    job_name=job_name,
                    event_id=event_id,
                    object_id=object_id,
                    job_id=job_id,
                    retry_count=retry_count,
                )
                try:
                    result = fn(*args, **kwargs)
                except Exception as exc:
                    limit = getattr(task, "max_retries", None) if task is not None else None
                    autoretry = (getattr(task, "autoretry_for", ()) or ()) if task is not None else ()
                    will_retry = (
                        task is not None
                        and retry_count is not None
                        and (limit is None or (isinstance(limit, int) and not isinstance(limit, bool) and retry_count < limit))
                        and any(isinstance(exc, cls) for cls in autoretry)
                    )
                    retried = type(exc).__name__ == "Retry" or will_retry
                    log_operation(
                        "job.retry" if retried else "job.fail",
                        OUTCOME_FAILURE,
                        job_name=job_name,
                        error_code="retry" if retried else type(exc).__name__,
                        event_id=event_id,
                        object_id=object_id,
                        job_id=job_id,
                        retry_count=retry_count,
                        duration_ms=_elapsed_ms(started),
                    )
                    raise
                log_operation(
                    "job.finish",
                    OUTCOME_SUCCESS,
                    job_name=job_name,
                    event_id=event_id,
                    object_id=object_id,
                    job_id=job_id,
                    retry_count=retry_count,
                    duration_ms=_elapsed_ms(started),
                )
                return result
            finally:
                if token is not None:
                    _job_id.reset(token)
                if host_bound:
                    try:
                        if prev_host_job_id is not None:
                            _host_bind_job_id(prev_host_job_id)
                        elif _host_reset_job_id is not None:
                            _host_reset_job_id()
                    except Exception:
                        pass

        return wrapper

    return decorator
