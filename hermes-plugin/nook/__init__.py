"""Report Hermes "needs input" moments to Nook.

Writes one JSON file per session into Nook's inbox while Hermes waits on an approval or a
clarifying question, and removes it once answered. Working/done status is read from state.db by
Nook itself, so this plugin only covers what the database does not record.
"""
import json
import os
import re
import time
from pathlib import Path

INBOX = Path.home() / "Library" / "Application Support" / "Nook" / "inbox"


def _path(session_id):
    name = f"{_profile() or 'default'}-{session_id}"
    return INBOX / f"hermes-{re.sub(r'[^A-Za-z0-9_.-]', '_', name)}.json"


def _profile():
    """The profile this Hermes runs as (HERMES_HOME=~/.hermes/profiles/<name>), or None for the default."""
    home = Path(os.environ.get("HERMES_HOME") or "")
    return home.name if home.parent.name == "profiles" else None


def _session_id(kwargs):
    return str(kwargs.get("session_id") or kwargs.get("session_key") or "default")


def _write(session_id, detail):
    try:
        # Owner-only: the detail can quote the command waiting for approval.
        INBOX.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = _path(session_id)
        tmp = INBOX / f".{target.name}.{os.getpid()}.tmp"
        record = json.dumps({
            "app": "Hermes", "bundleId": "com.nousresearch.hermes", "threadId": session_id, "profile": _profile(),
            "state": "needs_input", "detail": detail[:80], "updatedAt": time.time(),
            # Safety net in case the matching "answered" hook never fires.
            "expiresAt": time.time() + 3600,
        })
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            file.write(record)
        os.replace(tmp, target)
    except Exception:
        pass  # observability must never break the agent


def _clear(session_id):
    try:
        _path(session_id).unlink(missing_ok=True)
    except Exception:
        pass


def _on_approval_request(**kwargs):
    if kwargs.get("surface") == "smart":
        return  # auto-decided by the aux model; nobody is waiting on the user
    description = kwargs.get("description") or "command"
    _write(_session_id(kwargs), f"Approve: {description}")


def _on_approval_response(**kwargs):
    _clear(_session_id(kwargs))


def _on_pre_tool_call(tool_name=None, **kwargs):
    if tool_name == "clarify":
        _write(_session_id(kwargs), "Asking you a question")


def _on_post_tool_call(tool_name=None, **kwargs):
    if tool_name == "clarify":
        _clear(_session_id(kwargs))


def register(ctx) -> None:
    ctx.register_hook("pre_approval_request", _on_approval_request)
    ctx.register_hook("post_approval_response", _on_approval_response)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
