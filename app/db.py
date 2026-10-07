"""SQLite 连接、初始化与同步出库箱。"""
from __future__ import annotations
import json
import os
import sqlite3
from pathlib import Path

SCHEMA_PATH = Path(__file__).with_name("schema.sql")
DEFAULT_DB = Path(__file__).resolve().parent.parent / "data" / "mine.db"

CHANNELS = ("map", "transcript_index", "photo_caption", "print")


def get_conn(path: str | os.PathLike | None = None) -> sqlite3.Connection:
    path = str(path or os.environ.get("MINE_DB", DEFAULT_DB))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
    for name in CHANNELS:
        conn.execute(
            "INSERT OR IGNORE INTO sync_channel(name, cursor_seq) VALUES (?,0)", (name,)
        )
    conn.commit()


def reset_db(conn: sqlite3.Connection) -> None:
    """清空重建(测试与重新播种用)。"""
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    conn.execute("PRAGMA foreign_keys = OFF")
    for r in rows:
        conn.execute(f"DROP TABLE IF EXISTS {r['name']}")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.commit()
    init_db(conn)


def emit_outbox(conn: sqlite3.Connection, channel: str, entity_type: str,
                entity_id: int, payload: dict) -> None:
    """在同一事务里写渠道通知; channel='all' 扇出到全部渠道。"""
    targets = CHANNELS if channel == "all" else (channel,)
    body = json.dumps(payload, ensure_ascii=False)
    for ch in targets:
        conn.execute(
            "INSERT INTO sync_outbox(channel, entity_type, entity_id, payload) "
            "VALUES (?,?,?,?)",
            (ch, entity_type, entity_id, body),
        )


def channel_cursors(conn: sqlite3.Connection) -> dict:
    rows = conn.execute("SELECT name, cursor_seq FROM sync_channel").fetchall()
    cursors = {r["name"]: r["cursor_seq"] for r in rows}
    max_seq = conn.execute(
        "SELECT COALESCE(MAX(seq),0) AS m FROM sync_outbox"
    ).fetchone()["m"]
    out = {}
    for ch in CHANNELS:
        cur = cursors.get(ch, 0)
        out[ch] = {
            "applied_seq": cur,
            "latest_seq": max_seq,
            "in_sync": cur >= max_seq,
            "pending": [
                {"seq": r["seq"], "entity_type": r["entity_type"], "entity_id": r["entity_id"]}
                for r in conn.execute(
                    "SELECT seq, entity_type, entity_id FROM sync_outbox "
                    "WHERE channel=? AND seq>? ORDER BY seq", (ch, cur)
                ).fetchall()
            ],
        }
    return out


def apply_channel(conn: sqlite3.Connection, channel: str) -> dict:
    """把某渠道应用到最新(演示中即推进游标), 返回处理的条目。"""
    if channel not in CHANNELS:
        raise ValueError(f"未知渠道: {channel}")
    cur = conn.execute(
        "SELECT cursor_seq FROM sync_channel WHERE name=?", (channel,)
    ).fetchone()["cursor_seq"]
    rows = conn.execute(
        "SELECT seq FROM sync_outbox WHERE channel=? AND seq>? ORDER BY seq",
        (channel, cur),
    ).fetchall()
    if rows:
        conn.execute(
            "UPDATE sync_channel SET cursor_seq=? WHERE name=?",
            (rows[-1]["seq"], channel),
        )
    return {"channel": channel, "applied": [r["seq"] for r in rows]}
