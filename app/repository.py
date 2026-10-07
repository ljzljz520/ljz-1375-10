"""领域查询: 按时期解析有效区间(查询时解析方案)。

方案选择说明见 README: 不按时期物化空间视图, 而在查询时用区间过滤, 因为
  - 时间未知的记录无法安全落到某张"时期快照"里, 物化会强迫伪造边界;
  - 矛盾来源需并存, 物化视图通常只留一个赢家;
  - 历史几何与当前参观边界同库不同标记, 每次查询都重新判定, 杜绝旧快照泄漏成"当前可走"。
"""
from __future__ import annotations
import json
from datetime import datetime, timedelta
from typing import Optional

from .temporal import Interval, interval_status, parse_dt, semver_tuple
from .db import emit_outbox

WEEKDAY_NAMES = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


# ---------------- 基础组装 ----------------

def _geom_interval(row) -> Interval:
    return Interval.of(row["start_value"], row["start_prec"],
                       row["end_value"], row["end_prec"])


def _rel_interval(row) -> Interval:
    return Interval.of(row["start_value"], row["start_prec"],
                       row["end_value"], row["end_prec"])


def _geom_feature(conn, row, t):
    status = interval_status(_geom_interval(row), t)
    props = {
        "geom_id": row["id"], "place_id": row["place_id"],
        "name": row["name"], "kind": row["kind"],
        "current_status": row["current_status"],
        "label": row["label"],
        "certainty": row["certainty"],
        "is_historical": bool(row["is_historical"]),
        "interval": {
            "start": row["start_value"], "start_prec": row["start_prec"],
            "end": row["end_value"], "end_prec": row["end_prec"],
        },
        "status_at": status,  # definite / possible / none
        "provisional": status == "possible",
    }
    return {"type": "Feature", "geometry": json.loads(row["coordinates"]),
            "properties": props}


def spatial_view(conn, t: datetime, historical_only: bool = False) -> dict:
    """查询时解析: 返回 t 时点的空间视图(GeoJSON FeatureCollection)。

    historical_only=True 仅取历史空间层; 否则取当前层。
    status_at='possible' 的要素单独标记 provisional, 前端必须显示"时间存疑"。
    """
    rows = conn.execute(
        """SELECT g.*, p.name, p.kind, p.current_status
             FROM place_geom g JOIN place p ON p.id = g.place_id
            ORDER BY g.place_id, g.id""").fetchall()
    features, provisional = [], []
    for r in rows:
        st = interval_status(_geom_interval(r), t)
        if st == "none":
            continue
        if bool(r["is_historical"]) != historical_only:
            continue
        f = _geom_feature(conn, r, t)
        features.append(f)
        if st == "possible":
            provisional.append(f["properties"]["geom_id"])
    return {"type": "FeatureCollection", "as_of": t.isoformat(),
            "layer": "historical" if historical_only else "current",
            "features": features, "provisional_geom_ids": provisional}


def place_timeline(conn, place_id: int) -> dict:
    geoms = conn.execute(
        "SELECT * FROM place_geom WHERE place_id=? ORDER BY COALESCE(start_value,'')",
        (place_id,)).fetchall()
    rels = conn.execute(
        """SELECT r.*, pf.name AS from_name, pt.name AS to_name
             FROM place_relation r
             JOIN place pf ON pf.id=r.from_place JOIN place pt ON pt.id=r.to_place
            WHERE r.from_place=? OR r.to_place=? ORDER BY COALESCE(r.start_value,'')""",
        (place_id, place_id)).fetchall()
    events = conn.execute(
        "SELECT * FROM event WHERE place_id=? ORDER BY COALESCE(occurred_value,'')",
        (place_id,)).fetchall()
    return {
        "place": dict(conn.execute("SELECT * FROM place WHERE id=?", (place_id,)).fetchone()),
        "geoms": [dict(g) for g in geoms],
        "relations": [dict(r) for r in rels],
        "events": [dict(e) for e in events],
    }


# ---------------- 审批 ----------------

def is_approved(conn, place_id: int, t: datetime, scope: str = "tour") -> bool:
    row = conn.execute(
        """SELECT * FROM approval WHERE place_id=? AND scope IN (?, 'all')
           ORDER BY decided_at DESC, id DESC LIMIT 1""",
        (place_id, scope)).fetchone()
    if not row or row["status"] != "approved":
        return False
    if row["valid_from"] and t < parse_dt(row["valid_from"]):
        return False
    if row["valid_to"] and t >= parse_dt(row["valid_to"]):
        return False
    return True


# ---------------- 参观路径: 只走当前、已批准、t 时点有效的连接 ----------------

BREAK_REL_TYPES = {"connected", "reused_as"}


def _active_edges(conn, t: datetime):
    rows = conn.execute(
        """SELECT r.*, pf.slug AS fslug, pt.slug AS tslug,
                  pf.name AS fname, pt.name AS tname,
                  pf.kind AS fkind, pt.kind AS tkind
             FROM place_relation r
             JOIN place pf ON pf.id=r.from_place
             JOIN place pt ON pt.id=r.to_place
            WHERE r.rel_type IN ('connected','reused_as')
         ORDER BY r.id""").fetchall()
    edges = []
    for r in rows:
        iv = _rel_interval(r)
        st = interval_status(iv, t)
        if st == "none":
            continue
        # 任何一端点是纯历史空间则不可作为当前路径
        g_a = conn.execute(
            "SELECT is_historical FROM place_geom WHERE place_id=? ORDER BY id LIMIT 1",
            (r["from_place"],)).fetchone()
        g_b = conn.execute(
            "SELECT is_historical FROM place_geom WHERE place_id=? ORDER BY id LIMIT 1",
            (r["to_place"],)).fetchone()
        historical = (g_a and g_a["is_historical"]) or (g_b and g_b["is_historical"])
        edges.append({"row": r, "status": st, "historical": bool(historical)})
    return edges


def tour_route(conn, origin_slug: str, dest_slug: str, t: datetime) -> dict:
    """BFS。硬规则: 未批准区域/历史通道绝不入图; 时间存疑边不用于导览(只可能, 不确定)。"""
    places = {r["slug"]: r for r in conn.execute("SELECT * FROM place").fetchall()}
    if origin_slug not in places or dest_slug not in places:
        return {"ok": False, "error": "unknown_place", "blocked": []}
    origin, dest = places[origin_slug], places[dest_slug]
    blocked = []
    for p in (origin, dest):
        if not is_approved(conn, p["id"], t):
            blocked.append({"place": p["slug"], "reason": "not_approved",
                            "detail": "该区域未在当前时段获批, 不生成进入路线"})
    adj = {}
    edges = _active_edges(conn, t)
    for e in edges:
        r = e["row"]
        reasons = []
        if e["historical"]:
            reasons.append("historical_passage")
        if e["status"] != "definite":
            reasons.append("time_uncertain")
        a_ok = is_approved(conn, r["from_place"], t)
        b_ok = is_approved(conn, r["to_place"], t)
        if not a_ok:
            reasons.append(f"endpoint_not_approved:{r['fslug']}")
        if not b_ok:
            reasons.append(f"endpoint_not_approved:{r['tslug']}")
        # 断裂事件: 边的终点侧若有 breakage/closure 事件发生在 t 或之前, 且与该边相关
        break_events = conn.execute(
            """SELECT * FROM event
                WHERE event_type IN ('breakage','closure','abandonment')
                  AND COALESCE(occurred_value,'') != ''
                  AND (place_id=? OR place_id=?)""",
            (r["from_place"], r["to_place"])).fetchall()
        broke = None
        for ev in rows_events_within(break_events, t):
            broke = ev
            reasons.append("broken_or_closed")
            break
        if reasons:
            blocked.append({
                "edge": [r["fslug"], r["tslug"]], "reasons": reasons,
                "event": {"id": broke["id"], "title": broke["title"],
                          "occurred": broke["occurred_value"],
                          "detail": broke["detail"]} if broke else None})
            continue
        adj.setdefault(r["from_place"], []).append((r["to_place"], r))
        adj.setdefault(r["to_place"], []).append((r["from_place"], r))

    if blocked and any(b.get("place") in (origin_slug, dest_slug) for b in blocked):
        return {"ok": False, "error": "restricted_destination",
                "as_of": t.isoformat(), "blocked": blocked, "path": []}

    # BFS
    from collections import deque
    q = deque([(origin["id"], [])])
    seen = {origin["id"]}
    found = None
    while q:
        node, path = q.popleft()
        if node == dest["id"]:
            found = path
            break
        for nxt, rel in adj.get(node, []):
            if nxt in seen:
                continue
            seen.add(nxt)
            q.append((nxt, path + [(node, nxt, rel)]))
    if found is None:
        return {"ok": False, "error": "no_route", "as_of": t.isoformat(),
                "blocked": blocked, "path": []}
    id2slug = {p["id"]: p["slug"] for p in places.values()}
    id2name = {p["id"]: p["name"] for p in places.values()}
    steps = [{"place": origin_slug, "name": origin["name"]}]
    for a, b, rel in found:
        steps.append({"place": id2slug[b], "name": id2name[b],
                      "via": rel["rel_type"], "certainty": rel["certainty"]})
    return {"ok": True, "as_of": t.isoformat(), "path": steps, "blocked": blocked}


def rows_events_within(events, t):
    for ev in events:
        try:
            occ = parse_dt(ev["occurred_value"])
        except (ValueError, TypeError):
            continue
        if occ is not None and occ <= t:
            yield ev


# ---------------- 开放状态 (含跨日) ----------------

def opening_status(conn, place_id: int, t: datetime) -> dict:
    # 特例窗口优先
    ov = conn.execute(
        """SELECT * FROM opening_rule
            WHERE rule_type='override' AND place_id=?
              AND win_start <= ? AND win_end > ?
            ORDER BY id DESC LIMIT 1""",
        (place_id, t.isoformat(sep=" "), t.isoformat(sep=" "))).fetchone()
    if ov:
        if ov["is_closed"]:
            return {"open": False, "basis": "override_closed", "note": ov["note"],
                    "window": [ov["win_start"], ov["win_end"]]}
        return _eval_window(ov["open_time"], ov["close_time"], t, "override", ov["note"],
                            [ov["win_start"], ov["win_end"]])
    rules = conn.execute(
        "SELECT * FROM opening_rule WHERE rule_type='weekly' AND place_id=? AND weekday=?",
        (place_id, t.weekday())).fetchall()
    if not rules:
        return {"open": None, "basis": "no_rule"}
    rule = rules[0]
    if rule["is_closed"] or not rule["open_time"]:
        return {"open": False, "basis": "weekly_closed", "weekday": WEEKDAY_NAMES[t.weekday()]}
    return _eval_window(rule["open_time"], rule["close_time"], t, "weekly",
                        rule["note"], None)


def _eval_window(open_time, close_time, t, basis, note, window):
    oh, om = map(int, open_time.split(":"))
    ch, cm = map(int, close_time.split(":"))
    now_min = t.hour * 60 + t.minute
    o_min, c_min = oh * 60 + om, ch * 60 + cm
    spans_midnight = c_min <= o_min
    if spans_midnight:
        is_open = now_min >= o_min or now_min < c_min
    else:
        is_open = o_min <= now_min < c_min
    return {"open": is_open, "basis": basis, "note": note, "window": window,
            "open_time": open_time, "close_time": close_time,
            "spans_midnight": spans_midnight}


def announcements(conn, t: datetime):
    rows = conn.execute(
        "SELECT * FROM opening_announcement WHERE win_start <= ? ORDER BY win_start DESC",
        (t.isoformat(sep=" "),)).fetchall()
    return [dict(r) for r in rows]


# ---------------- 口述史 / 匿名 ----------------

def public_interview(conn, interview_id: int) -> Optional[dict]:
    iv = conn.execute("SELECT * FROM interview WHERE id=?", (interview_id,)).fetchone()
    if not iv:
        return None
    data = dict(iv)
    withdrawn = iv["consent_scope"] == "withdrawn"
    if iv["anonymized"] or iv["consent_scope"] != "public":
        data["person_name"] = None  # 真名不下发
    data["display_name"] = iv["display_name"]
    tr = conn.execute(
        "SELECT * FROM transcript WHERE interview_id=? ORDER BY id LIMIT 1",
        (interview_id,)).fetchone()
    segments = []
    if tr and not withdrawn:
        segs = conn.execute(
            "SELECT * FROM transcript_segment WHERE transcript_id=? ORDER BY seq",
            (tr["id"],)).fetchall()
        for s in segs:
            if s["embargoed"]:
                segments.append({"seq": s["seq"], "t_start": s["t_start"], "t_end": s["t_end"],
                                 "text": None, "redacted": True,
                                 "redact_reason": "受访者匿名或许可限制"})
            else:
                segments.append({"seq": s["seq"], "t_start": s["t_start"], "t_end": s["t_end"],
                                 "text": s["text"], "redacted": False})
    data["withdrawn"] = withdrawn
    if withdrawn:
        data["consent_detail"] = "许可已撤回, 逐字稿不公开"
    data["transcript"] = {"id": tr["id"] if tr else None,
                          "status": tr["status"] if tr else None,
                          "segments": segments}
    return data


def anonymize_interview(conn, interview_id: int, display_name: str, reason: str) -> dict:
    iv = conn.execute("SELECT * FROM interview WHERE id=?", (interview_id,)).fetchone()
    if not iv:
        raise KeyError("interview not found")
    conn.execute(
        "UPDATE interview SET anonymized=1, person_name=NULL, display_name=? WHERE id=?",
        (display_name, interview_id))
    tr = conn.execute(
        "SELECT id FROM transcript WHERE interview_id=? ORDER BY id LIMIT 1",
        (interview_id,)).fetchone()
    embargoed_segs = []
    if tr:
        # 含可识别个人信息的段落按匿名要求遮蔽(本演示以标记段为准, 另可按关键词)
        conn.execute(
            "UPDATE transcript_segment SET embargoed=1, search_text=NULL "
            "WHERE transcript_id=? AND (embargoed=1 OR text LIKE '%真名%' OR text LIKE '%住址%')",
            (tr["id"],))
        conn.execute("UPDATE transcript SET status='stale' WHERE id=?", (tr["id"],))
        embargoed_segs = [r["seq"] for r in conn.execute(
            "SELECT seq FROM transcript_segment WHERE transcript_id=? AND embargoed=1",
            (tr["id"],)).fetchall()]
    payload = {"interview_id": interview_id, "display_name": display_name,
               "reason": reason, "embargoed_segments": embargoed_segs}
    emit_outbox(conn, "transcript_index", "interview", interview_id, payload)
    emit_outbox(conn, "map", "interview", interview_id, payload)
    return payload


def reindex_transcript(conn, transcript_id: int) -> dict:
    tr = conn.execute("SELECT * FROM transcript WHERE id=?", (transcript_id,)).fetchone()
    if not tr:
        raise KeyError("transcript not found")
    segs = conn.execute(
        "SELECT * FROM transcript_segment WHERE transcript_id=? ORDER BY seq",
        (transcript_id,)).fetchall()
    n = 0
    for s in segs:
        txt = None if s["embargoed"] else s["text"]
        conn.execute("UPDATE transcript_segment SET search_text=? WHERE id=?",
                     (txt, s["id"]))
        n += 1
    conn.execute("UPDATE transcript SET status='indexed' WHERE id=?", (transcript_id,))
    payload = {"transcript_id": transcript_id, "segments": n}
    emit_outbox(conn, "transcript_index", "transcript", transcript_id, payload)
    return payload


def search_transcripts(conn, q: str):
    rows = conn.execute(
        """SELECT s.seq, s.text, s.embargoed, t.id AS transcript_id,
                  i.display_name, i.anonymized
             FROM transcript_segment s
             JOIN transcript t ON t.id=s.transcript_id
             JOIN interview i ON i.id=t.interview_id
            WHERE s.search_text LIKE ? ORDER BY t.id, s.seq""",
        (f"%{q}%",)).fetchall()
    return [{"transcript_id": r["transcript_id"], "seq": r["seq"], "text": r["text"]}
            for r in rows]


# ---------------- 照片 ----------------

def photo_public(conn, photo_id: int) -> Optional[dict]:
    r = conn.execute(
        """SELECT ph.*, g.place_id, g.coordinates, g.is_historical,
                  g.start_value AS geom_start, g.end_value AS geom_end,
                  p.name AS place_name, p.slug AS place_slug
             FROM photo ph
             LEFT JOIN place_geom g ON g.id=ph.geom_id
             LEFT JOIN place p ON p.id=g.place_id
            WHERE ph.id=?""", (photo_id,)).fetchone()
    if not r:
        return None
    d = dict(r)
    d["withdrawn"] = r["rights_status"] == "withdrawn"
    if d["withdrawn"]:
        # 撤权: 不返回图址/坐标/说明正文
        for k in ("coordinates", "caption", "geom_id"):
            d[k] = None
    return d


def photos_for_map(conn, t: datetime):
    """照片按拍摄期定位到历史几何层, 并明确标注"历史位置, 非今日现场"。"""
    rows = conn.execute(
        """SELECT ph.id, ph.slug, ph.caption, ph.taken_value, ph.rights_status,
                  ph.caption_status, g.id AS geom_id, g.coordinates,
                  g.is_historical, g.place_id, p.name AS place_name
             FROM photo ph
             JOIN place_geom g ON g.id=ph.geom_id
             JOIN place p ON p.id=g.place_id
            WHERE ph.rights_status != 'withdrawn'
         ORDER BY ph.id""").fetchall()
    out = []
    for r in rows:
        try:
            taken = parse_dt(r["taken_value"])
        except (ValueError, TypeError):
            taken = None
        out.append({
            "photo_id": r["id"], "slug": r["slug"], "caption": r["caption"],
            "taken": r["taken_value"], "geom_id": r["geom_id"],
            "place_id": r["place_id"], "place_name": r["place_name"],
            "geometry": json.loads(r["coordinates"]),
            "is_historical_position": bool(r["is_historical"]),
            "position_note": "历史照片位置(按拍摄时期), 不代表今日现场坐标",
            "caption_status": r["caption_status"],
        })
    return out


def withdraw_photo(conn, photo_id: int, reason: str) -> dict:
    r = conn.execute("SELECT * FROM photo WHERE id=?", (photo_id,)).fetchone()
    if not r:
        raise KeyError("photo not found")
    conn.execute(
        "UPDATE photo SET rights_status='withdrawn', withdrawn_reason=?, caption_status='stale' WHERE id=?",
        (reason, photo_id))
    payload = {"photo_id": photo_id, "reason": reason, "action": "withdrawn"}
    emit_outbox(conn, "photo_caption", "photo", photo_id, payload)
    emit_outbox(conn, "map", "photo", photo_id, payload)
    return payload


def update_caption(conn, photo_id: int, caption: str) -> dict:
    r = conn.execute("SELECT * FROM photo WHERE id=?", (photo_id,)).fetchone()
    if not r:
        raise KeyError("photo not found")
    conn.execute(
        "UPDATE photo SET caption=?, caption_status='stale' WHERE id=?",
        (caption, photo_id))
    payload = {"photo_id": photo_id, "caption": caption, "action": "caption_updated"}
    # 说明先入库(stale), 同步渠道应用后才变 synced
    emit_outbox(conn, "photo_caption", "photo", photo_id, payload)
    return payload


def mark_caption_synced(conn, photo_id: int) -> None:
    conn.execute("UPDATE photo SET caption_status='synced' WHERE id=?", (photo_id,))


# ---------------- 叙事: 证据/不确定性原样保留 ----------------

def public_narrative(conn, slug: str) -> Optional[dict]:
    n = conn.execute("SELECT * FROM narrative WHERE slug=? AND published=1", (slug,)).fetchone()
    if not n:
        return None
    d = {k: n[k] for k in n.keys()}
    d["evidence"] = [dict(r) for r in conn.execute(
        "SELECT label, quote, source_id FROM narrative_evidence WHERE narrative_id=? ORDER BY label",
        (n["id"],)).fetchall()]
    contradictory = False
    alternatives = []
    if n["topic"]:
        cf = conn.execute(
            "SELECT * FROM source_conflict WHERE topic=? AND resolved=0", (n["topic"],)).fetchall()
        contradictory = bool(cf)
        others = conn.execute(
            "SELECT * FROM narrative WHERE topic=? AND id!=? AND published=1",
            (n["topic"], n["id"])).fetchall()
        alternatives = [{"slug": o["slug"], "title": o["title"],
                         "certainty": o["certainty"], "body": o["body"],
                         "uncertainty_note": o["uncertainty_note"]} for o in others]
    d["contradictory"] = contradictory
    d["alternatives"] = alternatives
    d["must_preserve"] = {
        "evidence_quotes_verbatim": True,
        "uncertainty_marker_required": n["certainty"] != "certain" or contradictory,
        "no_visual_softening": n["sensitivity"] in ("danger", "fatal_accident"),
    }
    return d


def list_narratives(conn):
    return [{"slug": r["slug"], "title": r["title"], "sensitivity": r["sensitivity"],
             "certainty": r["certainty"]}
            for r in conn.execute(
                "SELECT slug,title,sensitivity,certainty FROM narrative WHERE published=1 ORDER BY id")]


def list_conflicts(conn):
    rows = conn.execute(
        """SELECT c.*, sa.title AS source_a, sb.title AS source_b
             FROM source_conflict c
             JOIN source sa ON sa.id=c.source_a_id
             JOIN source sb ON sb.id=c.source_b_id
         ORDER BY c.id""").fetchall()
    return [dict(r) for r in rows]


# ---------------- 事件登记 (井区合并/废弃/搬迁/断裂) ----------------

def report_breakage(conn, slug, title, place_id, occurred, detail,
                    source_id=None, close_edge_place_ids=None) -> dict:
    occurred_dt = parse_dt(occurred) if occurred else None
    cur = conn.execute(
        "INSERT INTO event(slug,title,event_type,place_id,source_id,occurred_value,occurred_prec,detail)"
        " VALUES (?,?, 'breakage', ?,?, ?, COALESCE(?, 'unknown'),?)",
        (slug, title, place_id, source_id,
         occurred_dt.isoformat(sep=" ") if occurred_dt else None,
         "instant" if occurred_dt else "unknown", detail))
    event_id = cur.lastrowid
    closed_edges = []
    if close_edge_place_ids and len(close_edge_place_ids) == 2:
        a, b = close_edge_place_ids
        rel = conn.execute(
            """SELECT * FROM place_relation
                WHERE rel_type IN ('connected','reused_as')
                  AND ((from_place=? AND to_place=?) OR (from_place=? AND to_place=?))
             ORDER BY id DESC LIMIT 1""", (a, b, b, a)).fetchone()
        if rel:
            conn.execute(
                "UPDATE place_relation SET end_value=?, end_prec='day' WHERE id=?",
                (occurred_dt.date().isoformat() if occurred_dt else None, rel["id"]))
            closed_edges.append(rel["id"])
    payload = {"event_id": event_id, "closed_edges": closed_edges}
    emit_outbox(conn, "map", "event", event_id, payload)
    emit_outbox(conn, "print", "event", event_id, payload)
    return payload


def add_opening_override(conn, place_id, win_start, win_end, is_closed,
                         open_time=None, close_time=None, note=None, source_id=None) -> dict:
    cur = conn.execute(
        """INSERT INTO opening_rule(rule_type,place_id,open_time,close_time,
               win_start,win_end,is_closed,note,source_id)
           VALUES ('override',?,?,?,?,?,?,?,?)""",
        (place_id, open_time, close_time, win_start, win_end,
         1 if is_closed else 0, note, source_id))
    rule_id = cur.lastrowid
    payload = {"rule_id": rule_id, "place_id": place_id,
               "window": [win_start, win_end], "closed": bool(is_closed)}
    emit_outbox(conn, "map", "opening_rule", rule_id, payload)
    emit_outbox(conn, "print", "opening_rule", rule_id, payload)
    return payload


# ---------------- 离线包 ----------------

def offline_check(conn, version: str) -> dict:
    current = conn.execute(
        "SELECT * FROM offline_package WHERE status='current' ORDER BY released_at DESC LIMIT 1"
    ).fetchone()
    if not current:
        return {"supported": True}
    try:
        old = semver_tuple(version) < semver_tuple(current["min_supported"])
    except ValueError:
        old = True
    if old:
        return {"supported": False, "status": "upgrade_required",
                "your_version": version,
                "current_version": current["version"],
                "min_supported": current["min_supported"],
                "reason": "旧离线包的开放范围与轨道状态已过期, 不得用于导览"}
    return {"supported": True, "current_version": current["version"],
            "your_version": version}


# ---------------- 打印安全页数据 ----------------

def print_safety(conn, t: datetime) -> dict:
    approved_places = []
    for r in conn.execute("SELECT * FROM place ORDER BY id").fetchall():
        if is_approved(conn, r["id"], t):
            st = opening_status(conn, r["id"], t)
            approved_places.append({"slug": r["slug"], "name": r["name"], "opening": st})
    breaks = [dict(e) for e in conn.execute(
        """SELECT * FROM event
            WHERE event_type IN ('breakage','closure')
              AND COALESCE(occurred_value,'') != ''
         ORDER BY occurred_value DESC""").fetchall()]
    return {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "data_as_of": t.isoformat(timespec="seconds"),
        "approved_places": approved_places,
        "active_incidents": breaks,
        "warnings": [
            "历史巷道/旧轨道仅为历史图层, 不是当前可走路径",
            "导览仅含当前已批准区域; 限制区不生成路线",
            "如渠道同步落后, 以本页标注的资料时间为准并联系现场工作人员",
        ],
    }
