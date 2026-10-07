-- 矿山工业遗产叙事站 数据库结构
-- 设计原则:
--   1. 历史空间与当前参观边界分表存储, 历史照片挂在"历史几何"上, 不被今天地图覆盖定位
--   2. 井区合并/线路废弃/社区搬迁全部以 event(事件)表达, 不直接改删空间记录
--   3. 时间未知用 NULL + 精度标记, 不用哨兵日期
--   4. 相互矛盾的来源各自保留, 以 source_conflict 标记, 不做静默合并
--   5. 口述许可、照片撤权、安全/危险叙事的证据与不确定性标记原样保存

PRAGMA foreign_keys = ON;

-- ============ 来源 ============
CREATE TABLE source (
  id           INTEGER PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN ('archive','oral','photo','official','newspaper','survey')),
  title        TEXT NOT NULL,
  citation     TEXT,                 -- 可引用的出处串
  reliability  TEXT NOT NULL DEFAULT 'unrated'
                 CHECK (reliability IN ('unrated','low','medium','high')),
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- 相互矛盾来源登记: 同主题不同说法同时存在时双方都保留, 只在此登记
CREATE TABLE source_conflict (
  id            INTEGER PRIMARY KEY,
  topic         TEXT NOT NULL,       -- 如 '1958-08-roof-collapse-deaths'
  source_a_id   INTEGER NOT NULL REFERENCES source(id),
  source_b_id   INTEGER NOT NULL REFERENCES source(id),
  note          TEXT,
  resolved      INTEGER NOT NULL DEFAULT 0,  -- 仅人工可解, 自动流程不得消解
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============ 地点 (历史空间 / 当前地点同一实体表, 但几何分版本) ============
CREATE TABLE place (
  id          INTEGER PRIMARY KEY,
  slug        TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN
                ('shaft','rail_line','rail_station','community','building',
                 'plaza','museum','trail','passage','other')),
  current_status TEXT CHECK (current_status IN
                ('operating','heritage','abandoned','demolished','relocated','restricted')),
  note        TEXT
);

-- 地点几何按时间版本保存; 历史照片引用具体几何版本
-- 时间语义: start_* 含(闭), end_* 不含(开); NULL 表示未知/开放
-- start/end 精度: 'day' 当天00:00起 / 'month' 该月1日00:00起 / 'year' 该年1月1日起 / 'unknown' 端点缺失
CREATE TABLE place_geom (
  id            INTEGER PRIMARY KEY,
  place_id      INTEGER NOT NULL REFERENCES place(id),
  geom_type     TEXT NOT NULL CHECK (geom_type IN ('point','line','polygon')),
  coordinates   TEXT NOT NULL,          -- GeoJSON geometry (本地演示坐标, 非真实投影)
  label         TEXT,
  source_id     INTEGER REFERENCES source(id),
  start_value   TEXT,                   -- ISO 日期或日期时间; NULL=起始未知
  start_prec    TEXT NOT NULL DEFAULT 'unknown'
                  CHECK (start_prec IN ('day','month','year','unknown')),
  end_value     TEXT,                   -- NULL=结束未知(可能仍有效)
  end_prec      TEXT NOT NULL DEFAULT 'unknown'
                  CHECK (end_prec IN ('day','month','year','unknown')),
  certainty     TEXT NOT NULL DEFAULT 'certain'
                  CHECK (certainty IN ('certain','approx','disputed')),
  is_historical INTEGER NOT NULL DEFAULT 0   -- 1=仅历史空间, 绝不参与当前参观/路径
);

-- ============ 地点关系 (带时段): 合并/延续/复用/属于 等 ============
CREATE TABLE place_relation (
  id            INTEGER PRIMARY KEY,
  from_place    INTEGER NOT NULL REFERENCES place(id),
  to_place      INTEGER NOT NULL REFERENCES place(id),
  rel_type      TEXT NOT NULL CHECK (rel_type IN
                  ('merged_into','succeeded_by','reused_as','part_of',
                   'served','relocated_to','connected')),
  source_id     INTEGER REFERENCES source(id),
  start_value   TEXT, start_prec TEXT NOT NULL DEFAULT 'unknown',
  end_value     TEXT, end_prec TEXT NOT NULL DEFAULT 'unknown',
  certainty     TEXT NOT NULL DEFAULT 'certain'
                  CHECK (certainty IN ('certain','approx','disputed'))
);

-- ============ 事件: 井区合并 / 线路废弃 / 社区搬迁 / 轨道断裂 / 事故 ============
CREATE TABLE event (
  id            INTEGER PRIMARY KEY,
  slug          TEXT UNIQUE NOT NULL,
  title         TEXT NOT NULL,
  event_type    TEXT NOT NULL CHECK (event_type IN
                  ('merger','abandonment','relocation','breakage','opening_change',
                   'accident','closure','opening','other')),
  place_id      INTEGER REFERENCES place(id),
  source_id     INTEGER REFERENCES source(id),
  occurred_value TEXT,                  -- NULL=发生时间未知
  occurred_prec TEXT NOT NULL DEFAULT 'unknown'
                  CHECK (occurred_prec IN ('instant','day','month','year','unknown')),
  detail        TEXT,
  certainty     TEXT NOT NULL DEFAULT 'certain'
                  CHECK (certainty IN ('certain','approx','disputed')),
  supersedes_event_id INTEGER REFERENCES event(id),  -- 更正说法指向旧事件; 旧行保留不删
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============ 开放公告 (周历规则 + 跨日特例窗口) ============
CREATE TABLE opening_rule (
  id           INTEGER PRIMARY KEY,
  place_id     INTEGER NOT NULL REFERENCES place(id),
  rule_type    TEXT NOT NULL CHECK (rule_type IN ('weekly','override')),
  weekday      INTEGER CHECK (weekday BETWEEN 0 AND 6), -- 0=周一 ... 6=周日 (仅 weekly)
  open_time    TEXT,                    -- HH:MM; 关闭日为 NULL
  close_time   TEXT,                   -- HH:MM, 可小于 open_time 表示跨日营业
  win_start    TEXT,                   -- override 起始 ISO 日期时间
  win_end      TEXT,                   -- override 结束 ISO 日期时间(不含)
  is_closed    INTEGER NOT NULL DEFAULT 0,
  note         TEXT,
  source_id    INTEGER REFERENCES source(id)
);
CREATE TABLE opening_announcement (
  id           INTEGER PRIMARY KEY,
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,
  win_start    TEXT NOT NULL,          -- ISO 日期时间
  win_end      TEXT NOT NULL,
  place_id     INTEGER REFERENCES place(id)
);

-- ============ 审批: 只有已批准区域才能被参观功能引用 ============
CREATE TABLE approval (
  id           INTEGER PRIMARY KEY,
  place_id     INTEGER NOT NULL REFERENCES place(id),
  scope        TEXT NOT NULL CHECK (scope IN ('tour','photo','all')),
  status       TEXT NOT NULL CHECK (status IN ('approved','revoked','pending','denied')),
  valid_from   TEXT, valid_to TEXT,    -- ISO 日期时间; NULL=开放/未知
  reason       TEXT,
  decided_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============ 口述史: 许可与匿名要求 ============
CREATE TABLE interview (
  id              INTEGER PRIMARY KEY,
  slug            TEXT UNIQUE NOT NULL,
  person_name     TEXT,                -- 真名仅在许可允许时使用
  display_name    TEXT NOT NULL,       -- 对外显示名(可能是匿名代号)
  anonymized      INTEGER NOT NULL DEFAULT 0,
  consent_scope   TEXT NOT NULL DEFAULT 'private'
                    CHECK (consent_scope IN ('private','research','public','withdrawn')),
  consent_detail  TEXT,               -- 许可全文要点/限制
  recorded_value  TEXT, recorded_prec TEXT NOT NULL DEFAULT 'unknown',
  source_id       INTEGER REFERENCES source(id)
);
CREATE TABLE transcript (
  id            INTEGER PRIMARY KEY,
  interview_id  INTEGER NOT NULL REFERENCES interview(id),
  language      TEXT NOT NULL DEFAULT 'zh',
  status        TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','indexed','stale'))
);
CREATE TABLE transcript_segment (
  id            INTEGER PRIMARY KEY,
  transcript_id INTEGER NOT NULL REFERENCES transcript(id),
  seq           INTEGER NOT NULL,
  t_start       TEXT, t_end TEXT,      -- 音视频时间码
  text          TEXT NOT NULL,
  embargoed     INTEGER NOT NULL DEFAULT 0,   -- 被许可限制/匿名要求遮蔽
  search_text   TEXT                  -- 索引文本(可重建); 为 NULL 表示尚未同步到逐字稿索引
);

-- ============ 照片: 定位历史几何版本, 撤权后不公开 ============
CREATE TABLE photo (
  id           INTEGER PRIMARY KEY,
  slug         TEXT UNIQUE NOT NULL,
  caption      TEXT NOT NULL,
  geom_id      INTEGER REFERENCES place_geom(id), -- 挂历史/当时几何, 非今天位置
  taken_value  TEXT, taken_prec TEXT NOT NULL DEFAULT 'unknown',
  source_id    INTEGER REFERENCES source(id),
  rights_status TEXT NOT NULL DEFAULT 'unknown'
                 CHECK (rights_status IN ('unknown','cleared','restricted','withdrawn')),
  caption_status TEXT NOT NULL DEFAULT 'synced'
                 CHECK (caption_status IN ('synced','stale')),
  withdrawn_reason TEXT
);

-- ============ 叙事: 危险劳动/事故, 证据与不确定标记不可被自动摘要淡化 ============
CREATE TABLE narrative (
  id            INTEGER PRIMARY KEY,
  slug          TEXT UNIQUE NOT NULL,
  title         TEXT NOT NULL,
  body          TEXT NOT NULL,
  topic         TEXT,                  -- 与 source_conflict.topic 对应
  sensitivity   TEXT NOT NULL DEFAULT 'normal'
                  CHECK (sensitivity IN ('normal','danger','fatal_accident')),
  certainty     TEXT NOT NULL DEFAULT 'certain'
                  CHECK (certainty IN ('certain','approx','disputed')),
  uncertainty_note TEXT,              -- 不确定标记, 公开接口必须原样回传
  suppression_note TEXT,              -- 如"不得以路线热度/视觉特效弱化", 公开接口回传
  source_id     INTEGER REFERENCES source(id),
  evidence_event_id INTEGER REFERENCES event(id),
  published     INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE narrative_evidence (
  narrative_id INTEGER NOT NULL REFERENCES narrative(id),
  label        TEXT NOT NULL,
  quote        TEXT NOT NULL,          -- 原文引述, 禁止自动改写
  source_id    INTEGER REFERENCES source(id),
  PRIMARY KEY (narrative_id, label)
);

-- ============ 同步渠道: 地图 / 逐字稿索引 / 图片说明 可分别滞后 ============
CREATE TABLE sync_channel (
  id           INTEGER PRIMARY KEY,
  name         TEXT UNIQUE NOT NULL
                 CHECK (name IN ('map','transcript_index','photo_caption','print')),
  cursor_seq   INTEGER NOT NULL DEFAULT 0   -- 已应用到的 outbox 序号
);
CREATE TABLE sync_outbox (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  channel      TEXT NOT NULL,         -- map/transcript_index/photo_caption/print/all
  entity_type  TEXT NOT NULL,         -- event/place/photo/transcript/narrative/opening...
  entity_id    INTEGER NOT NULL,
  payload      TEXT NOT NULL,         -- JSON
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============ 离线包: 旧包必须被拒绝/强升, 不得按旧数据导览 ============
CREATE TABLE offline_package (
  id            INTEGER PRIMARY KEY,
  version       TEXT UNIQUE NOT NULL,   -- 语义版本
  status        TEXT NOT NULL CHECK (status IN ('current','stale','retracted')),
  min_supported TEXT NOT NULL,          -- 最低可用版本
  released_at   TEXT NOT NULL,
  note          TEXT
);

CREATE INDEX idx_geom_place ON place_geom(place_id);
CREATE INDEX idx_rel_from ON place_relation(from_place);
CREATE INDEX idx_event_place ON event(place_id);
CREATE INDEX idx_ts_transcript ON transcript_segment(transcript_id);
CREATE INDEX idx_photo_geom ON photo(geom_id);
