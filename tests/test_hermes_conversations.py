"""Regression test for Nook's Hermes chat handling (AgentReader.swift).

Runs the actual SQL shipped in AgentReader.swift against a fixture Hermes
state.db: subchats (subagent runs) must not surface as chats of their own or
fail the chat that spawned them, branch chats must stay their own chat, and a
turn that simply ended (final answer without a "stop" marker) must not read
as failed. Run: python3 -m unittest discover -s tests  (from the Nook folder)
"""
import re
import sqlite3
import time
import unittest
from pathlib import Path

SOURCE = (Path(__file__).parent.parent / "Sources" / "AgentReader.swift").read_text()


def sql_block(marker):
    """The triple-quoted SQL in AgentReader.swift containing `marker`."""
    for block in re.findall(r'"""\n(.*?)"""', SOURCE, re.S):
        if marker in block:
            return block
    raise AssertionError(f"no SQL block containing {marker!r}")


def quote(value):
    return "'" + value.replace("'", "''") + "'"


LEASE_SQL = sql_block("session_turn_leases").replace(r"\(now)", str(time.time()))
ENDED_SQL = sql_block("WITH RECURSIVE lineage")
CONVERSATION_SQL = (
    sql_block("WITH RECURSIVE up(")
    .replace(r"\(config)", "CASE WHEN json_valid(s.model_config) THEN s.model_config ELSE json_object() END")
)


def ended_cleanly(db, conversation):
    """ENDED_SQL plus the classification AgentReader applies to its last row."""
    rows = db.execute(ENDED_SQL.replace(r"\(id)", quote(conversation))).fetchall()
    if not rows:
        return True
    role, finish_reason, tool_calls = rows[0]
    if (finish_reason or "").lower() in {"error", "agent_error", "content_filter"}:
        return False
    if role in {"user", "tool"}:
        return False
    if role == "assistant" and tool_calls is not None:
        return False
    return True


def conversation(db, session_id):
    rows = db.execute(CONVERSATION_SQL.replace(r"\(id)", quote(session_id))).fetchall()
    return rows[0][0] if rows else session_id  # Swift falls back to the reported id


class HermesConversations(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(
            """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, parent_session_id TEXT,
              started_at REAL, ended_at REAL, end_reason TEXT, title TEXT, cwd TEXT,
              session_key TEXT, model_config TEXT);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,
              role TEXT, content TEXT, tool_calls TEXT, tool_name TEXT, finish_reason TEXT,
              timestamp REAL);
            CREATE TABLE session_turn_leases (conversation_id TEXT PRIMARY KEY, holder TEXT,
              acquired_at REAL, expires_at REAL);
            """
        )
        # (id, source, parent, end_reason, model_config, session_key)
        sessions = [
            ("root", "desktop", None, None, None, None),
            ("sub", "desktop", "root", "agent_close", '{"_delegate_from": "root"}', None),
            ("root2", "desktop", None, "compression", None, None),
            ("tip", "desktop", "root2", None, None, None),
            ("branch", "desktop", "root", "branched", '{"_branched_from": "root"}', None),
            ("branchsub", "desktop", "branch", "agent_close", '{"_delegate_from": "branch"}', None),
            ("toolroot", "tool", None, None, None, None),
            ("keyed", "desktop", None, None, None, "key-1"),
        ]
        for sid, source, parent, end_reason, config, key in sessions:
            self.db.execute(
                "INSERT INTO sessions VALUES (?, ?, ?, 100, 200, ?, ?, '/tmp', ?, ?)",
                (sid, source, parent, end_reason, f"Chat {sid}", key, config),
            )
        # The parent chat ended on its final answer (no "stop" marker written);
        # its subagent's last act was a tool result, later than the answer.
        messages = [
            ("root", "user", None, None),
            ("root", "assistant", None, None),  # plain end: finish_reason is NULL
            ("sub", "assistant", '[{"id": "c1"}]', "tool_calls"),
            ("sub", "tool", None, None),
            ("root2", "assistant", None, "stop"),
            ("tip", "assistant", None, None),  # compression tip carries the final answer
        ]
        for i, (sid, role, tool_calls, finish) in enumerate(messages):
            self.db.execute(
                "INSERT INTO messages (session_id, role, content, tool_calls, finish_reason, timestamp)"
                " VALUES (?, ?, 'x', ?, ?, ?)",
                (sid, role, tool_calls, finish, 100 + i),
            )
        future = time.time() + 600
        for sid in ("root", "sub", "branch", "toolroot"):
            self.db.execute("INSERT INTO session_turn_leases VALUES (?, 'h', 100, ?)", (sid, future))
        self.db.commit()

    def test_subchat_lease_is_not_a_chat_but_branch_is(self):
        ids = {row[0] for row in self.db.execute(LEASE_SQL)}
        self.assertEqual(ids, {"root", "branch"})  # no "sub", no internal "toolroot"

    def test_plain_end_is_done_and_subchat_cannot_fail_parent(self):
        self.assertTrue(ended_cleanly(self.db, "root"))

    def test_compression_tip_is_the_same_chat(self):
        self.assertTrue(ended_cleanly(self.db, "root2"))
        self.assertEqual(conversation(self.db, "tip"), "root2")

    def test_subchat_belongs_to_parent_branch_stays_itself(self):
        self.assertEqual(conversation(self.db, "sub"), "root")
        self.assertEqual(conversation(self.db, "branch"), "branch")
        self.assertEqual(conversation(self.db, "branchsub"), "branch")
        self.assertEqual(conversation(self.db, "key-1"), "keyed")

    def test_real_failures_still_fail(self):
        self.db.execute(
            "INSERT INTO messages (session_id, role, content, finish_reason, timestamp)"
            " VALUES ('root', 'assistant', 'boom', 'error', 999)"
        )
        self.assertFalse(ended_cleanly(self.db, "root"))


if __name__ == "__main__":
    unittest.main()
