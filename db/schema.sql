-- =====================================================================
-- 矿山工业遗产叙事站 —— 双时态数据库骨架 (PostgreSQL 14+ / PostGIS 3+)
-- 权威模型：事件 + 双时态断言（方案 B）；时期快照为派生只读缓存（见文末）
-- 约定：
--   * 有效区间半开 [valid_from, valid_to)
--   * 9999-12-31 = 断言主张"至今有效"（ongoing），必须有近期来源
--   * valid_from/valid_to = NULL 配合 *_unknown = true 表示"端点未知"
--     （未知 ≠ 开放，详见 docs/design.md §2）
--   * 记录区间 [recorded_from, recorded_to) 支撑迟到来源/修正/撤证审计
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------- 枚举 ----------
CREATE TYPE realm_kind         AS ENUM ('historical', 'current');
CREATE TYPE place_kind         AS ENUM ('mine', 'railway_line', 'community', 'other');
CREATE TYPE relation_kind      AS ENUM ('merged_into', 'relocated_to', 'connected_to',
                                        'served', 'abandoned', 'split_from');
CREATE TYPE event_kind         AS ENUM ('merge', 'abandonment', 'track_break', 'relocation',
                                        'opening_change', 'consent_grant', 'consent_withdrawal',
                                        'photo_revocation', 'assertion_resolution');
CREATE TYPE certainty_kind     AS ENUM ('definite', 'probable', 'disputed', 'unknown');
CREATE TYPE approval_status    AS ENUM ('approved', 'pending', 'suspended', 'revoked');
CREATE TYPE consent_status     AS ENUM ('active', 'narrowed', 'withdrawn', 'expired');
CREATE TYPE anonymization_kind AS ENUM ('none', 'pseudonym', 'full');
CREATE TYPE geo_quality        AS ENUM ('surveyed', 'reconstructed', 'approximate', 'disputed');
CREATE TYPE loc_certainty      AS ENUM ('precise', 'approximate', 'disputed', 'unknown');

-- =====================================================================
-- 1. 来源
-- =====================================================================
CREATE TABLE source (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ref             TEXT NOT NULL UNIQUE,            -- 档号/口述编号/公告号
    kind            TEXT NOT NULL CHECK (kind IN
                    ('archive','oral_history','photo','announcement','survey','scholarship','other')),
    title           TEXT,
    creator         TEXT,
    source_date     date,                            -- 来源自身日期，允许 NULL（未知）
    source_date_fuzzy boolean NOT NULL DEFAULT false,
    reliability     SMALLINT NOT NULL DEFAULT 3 CHECK (reliability BETWEEN 1 AND 5),
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 2. 地点（跨时期稳定身份）
-- =====================================================================
CREATE TABLE place (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stable_code     TEXT NOT NULL UNIQUE,            -- 如 MINE-03 / RAIL-SOUTH / COMM-DONGSHAN
    kind            place_kind NOT NULL,
    realm_origin    realm_kind NOT NULL,             -- 该身份起源的空间域（关系/几何仍各自带 realm）
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- 2a. 地名随时间变化（合并改名、社区更名）
CREATE TABLE place_name_version (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_id        BIGINT NOT NULL REFERENCES place(id),
    name            TEXT NOT NULL,
    valid_from      date,
    valid_from_unknown boolean NOT NULL DEFAULT false,
    valid_to        date,
    valid_to_unknown  boolean NOT NULL DEFAULT false,
    certainty       certainty_kind NOT NULL DEFAULT 'definite',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);

-- 2b. 几何版本：历史复原与当前测绘分开；历史照片只能落在 historical 几何上
CREATE TABLE place_geometry_version (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_id        BIGINT NOT NULL REFERENCES place(id),
    realm           realm_kind NOT NULL,
    geom            geometry(Geometry, 3857) NOT NULL,
    geometric_quality geo_quality NOT NULL,
    valid_from      date,
    valid_from_unknown boolean NOT NULL DEFAULT false,
    valid_to        date,
    valid_to_unknown  boolean NOT NULL DEFAULT false,
    certainty       certainty_kind NOT NULL DEFAULT 'definite',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31',
    CONSTRAINT ck_current_surveyed CHECK (
        -- 当前参观边界只允许实测几何；复原/约测几何不得进入 current 域
        realm = 'historical' OR geometric_quality = 'surveyed'
    )
);
CREATE INDEX idx_pgv_place_time ON place_geometry_version (place_id, valid_from, valid_to);
CREATE INDEX idx_pgv_realm_geom ON place_geometry_version USING gist (realm, geom);

-- =====================================================================
-- 3. 历史照片（定位永不进入 current 图层）
-- =====================================================================
CREATE TABLE historical_photo (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_id        BIGINT REFERENCES place(id),     -- 被摄对象（可空：位置未知时）
    shot_at_geom    geometry(Point, 3857),           -- 拍摄/被摄位置（历史复原）
    location_certainty loc_certainty NOT NULL DEFAULT 'unknown',
    shot_date       date,
    shot_date_fuzzy boolean NOT NULL DEFAULT false,
    shot_date_unknown boolean NOT NULL DEFAULT false,
    caption         TEXT,
    object_key      TEXT,                            -- 受控公开桶 key；撤权后摘除
                                                     -- 权利关系经 photo_right.photo_id 反查
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31',
    CONSTRAINT ck_photo_unknown_no_date CHECK (
        -- 标记为"拍摄时间未知"的照片不得同时携带精确日期
        shot_date_unknown = false OR shot_date IS NULL
    )
);
CREATE INDEX idx_photo_geom ON historical_photo USING gist (shot_at_geom);

-- =====================================================================
-- 4. 带时段的地点关系（合并/搬迁/连接/废弃/服务）
-- =====================================================================
CREATE TABLE place_relation (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relation_type   relation_kind NOT NULL,
    from_place_id   BIGINT NOT NULL REFERENCES place(id),
    to_place_id     BIGINT REFERENCES place(id),     -- abandoned 可为空
    realm           realm_kind NOT NULL,
    valid_from      date,
    valid_from_unknown boolean NOT NULL DEFAULT false,
    valid_to        date,
    valid_to_unknown  boolean NOT NULL DEFAULT false,
    ongoing         boolean NOT NULL DEFAULT false,  -- true 且有近期来源时 valid_to=9999
    certainty       certainty_kind NOT NULL DEFAULT 'definite',
    conflict_group_id BIGINT,                        -- 互斥断言同组
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    opened_by_event BIGINT,                          -- → event
    closed_by_event BIGINT,                          -- → event（断裂/废弃/搬迁终结区间）
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_pr_from ON place_relation (from_place_id, relation_type, valid_from, valid_to);
CREATE INDEX idx_pr_to   ON place_relation (to_place_id, relation_type);
CREATE INDEX idx_pr_conflict ON place_relation (conflict_group_id) WHERE conflict_group_id IS NOT NULL;

-- =====================================================================
-- 5. 事件：井区合并 / 线路废弃 / 轨道断裂 / 社区搬迁 / 开放变更 / 许可撤回 / 冲突裁决
-- =====================================================================
CREATE TABLE event (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type      event_kind NOT NULL,
    occurred_on     date,
    occurred_unknown boolean NOT NULL DEFAULT false, -- "具体日期不可考"
    granularity     TEXT NOT NULL DEFAULT 'day'
                    CHECK (granularity IN ('day','month','year','decade')),
    title           TEXT NOT NULL,
    narrative       TEXT,
    place_ids       BIGINT[] NOT NULL DEFAULT '{}',
    payload         jsonb NOT NULL DEFAULT '{}',     -- 类型化细节（前后归属、断裂里程等）
    certainty       certainty_kind NOT NULL DEFAULT 'definite',
    conflict_group_id BIGINT,
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_by     TEXT NOT NULL,
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_event_places ON event USING gin (place_ids);
CREATE INDEX idx_event_time ON event (occurred_on);

ALTER TABLE place_relation
    ADD CONSTRAINT fk_pr_open_event  FOREIGN KEY (opened_by_event) REFERENCES event(id),
    ADD CONSTRAINT fk_pr_close_event FOREIGN KEY (closed_by_event) REFERENCES event(id);

-- 冲突组：同一事实槽位的互斥断言集合，裁决前不允许静默选一
CREATE TABLE conflict_group (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic           TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
    resolved_by_event BIGINT REFERENCES event(id),   -- assertion_resolution
    resolution_note TEXT
);
ALTER TABLE place_relation ADD CONSTRAINT fk_pr_conflict
    FOREIGN KEY (conflict_group_id) REFERENCES conflict_group(id);
ALTER TABLE event ADD CONSTRAINT fk_ev_conflict
    FOREIGN KEY (conflict_group_id) REFERENCES conflict_group(id);

-- =====================================================================
-- 6. 当前参观边界与开放公告（current 域；只有 approved 可用于参观功能）
-- =====================================================================
CREATE TABLE access_area (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    boundary        geometry(Polygon, 3857) NOT NULL,
    approval_status approval_status NOT NULL DEFAULT 'pending',
    valid_from      date NOT NULL,
    valid_to        date NOT NULL DEFAULT '9999-12-31',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_access_boundary ON access_area USING gist (boundary)
    WHERE approval_status = 'approved';

-- 开放范围跨日变更：同一区域多条 [open_from, open_to) 公告，不重叠
CREATE TABLE opening_announcement (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    access_area_id  BIGINT NOT NULL REFERENCES access_area(id),
    open_from       timestamptz NOT NULL,             -- 精确到时段，支撑同日开闭
    open_to         timestamptz NOT NULL,
    published_at    timestamptz NOT NULL,
    note            TEXT,
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    event_id        BIGINT REFERENCES event(id),      -- opening_change
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31',
    CONSTRAINT ck_open_half_open CHECK (open_from < open_to)
);
CREATE INDEX idx_oa_area_time ON opening_announcement (access_area_id, open_from, open_to)
    WHERE recorded_to = '9999-12-31';

-- 当前行人可走图：仅来自 current 域测绘，与历史轨道无任何连接
CREATE TABLE walk_edge (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geom            geometry(LineString, 3857) NOT NULL,
    valid_from      date NOT NULL,
    valid_to        date NOT NULL DEFAULT '9999-12-31',
    accessible      boolean NOT NULL DEFAULT true
);
CREATE INDEX idx_walk_edge_gist ON walk_edge USING gist (geom) WHERE accessible;

-- 历史轨道段：纯展示，严禁入步行图
CREATE TABLE historical_track_segment (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_place_id   BIGINT NOT NULL REFERENCES place(id),
    geom            geometry(LineString, 3857) NOT NULL,
    valid_from      date,
    valid_from_unknown boolean NOT NULL DEFAULT false,
    valid_to        date,
    valid_to_unknown  boolean NOT NULL DEFAULT false,
    broken          boolean NOT NULL DEFAULT false,   -- 断裂段（断裂事件置位）
    certainty       certainty_kind NOT NULL DEFAULT 'definite',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_hts_gist ON historical_track_segment USING gist (geom);

-- =====================================================================
-- 7. 叙述 / 事故 / 原证据 / 逐字稿（证据与摘要分表，标记不可移除）
-- =====================================================================
CREATE TABLE interviewee_identity (            -- 受限表：仅最小权限角色可读
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    real_name       TEXT,
    contact         TEXT,
    pseudonym       TEXT,
    anonymization   anonymization_kind NOT NULL DEFAULT 'pseudonym'
);

CREATE TABLE narrative (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic           TEXT NOT NULL,
    severity        TEXT CHECK (severity IN ('daily','hazardous_labor','incident','fatality','other')),
    body            TEXT NOT NULL,                 -- 人工/编辑正文
    auto_summary    TEXT,                          -- 自动摘要（永远不得脱离原证据单独展示）
    summary_provenance jsonb,                      -- {"model":"...","at":"...","reviewed_by":"..."}
    uncertain_markers jsonb NOT NULL DEFAULT '[]', -- ["伤亡人数存疑","时间口述不一致"...]
    conflict_group_id BIGINT REFERENCES conflict_group(id),
    place_ids       BIGINT[] NOT NULL DEFAULT '{}',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    consent_id      BIGINT,                        -- → consent（应用层 FK）
    published       boolean NOT NULL DEFAULT false,
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_narrative_places ON narrative USING gin (place_ids);

-- 原证据引用：逐字稿原话 / 卷宗原文，展示优先级高于摘要
CREATE TABLE evidence_quote (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    narrative_id    BIGINT NOT NULL REFERENCES narrative(id),
    quote_kind      TEXT NOT NULL CHECK (quote_kind IN ('transcript','archive','photo_caption')),
    quote_text      TEXT NOT NULL,
    locator         TEXT,                          -- 时间码 mm:ss / 页码 / 档号
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    consent_id      BIGINT,
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);

-- 逐字稿分段：只有许可覆盖的段才能进公开索引
CREATE TABLE transcript_segment (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    interviewee_id  BIGINT REFERENCES interviewee_identity(id),
    t_start         numeric(10,2),
    t_end           numeric(10,2),
    text            TEXT NOT NULL,
    consent_id      BIGINT,
    index_public    boolean NOT NULL DEFAULT false,-- 由许可状态驱动；撤权时快道置 false
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);
CREATE INDEX idx_transcript_fts ON transcript_segment
    USING gin (to_tsvector('simple', text)) WHERE index_public;

-- =====================================================================
-- 8. 口述许可 / 照片权利 / 撤回
-- =====================================================================
CREATE TABLE consent (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    interviewee_id  BIGINT NOT NULL REFERENCES interviewee_identity(id),
    scope           TEXT NOT NULL,                 -- 用途/地域/媒介范围（可结构化拆表）
    anonymization   anonymization_kind NOT NULL DEFAULT 'pseudonym',
    status          consent_status NOT NULL DEFAULT 'active',
    valid_from      date NOT NULL,
    valid_to        date NOT NULL DEFAULT '9999-12-31',
    source_ids      BIGINT[] NOT NULL DEFAULT '{}',
    withdrawal_event_id BIGINT REFERENCES event(id),
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);

CREATE TABLE photo_right (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    photo_id        BIGINT NOT NULL REFERENCES historical_photo(id),
    holder          TEXT,
    license_scope   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'licensed'
                    CHECK (status IN ('licensed','expired','revoked')),
    valid_from      date NOT NULL,
    valid_to        date NOT NULL DEFAULT '9999-12-31',
    revocation_event_id BIGINT REFERENCES event(id),
    recorded_from   timestamptz NOT NULL DEFAULT now(),
    recorded_to     timestamptz NOT NULL DEFAULT '9999-12-31'
);

-- consent 表晚于叙述表创建，此处补齐许可外键（读路径据此过滤）
ALTER TABLE narrative
    ADD CONSTRAINT fk_narrative_consent FOREIGN KEY (consent_id) REFERENCES consent(id);
ALTER TABLE evidence_quote
    ADD CONSTRAINT fk_quote_consent FOREIGN KEY (consent_id) REFERENCES consent(id);
ALTER TABLE transcript_segment
    ADD CONSTRAINT fk_segment_consent FOREIGN KEY (consent_id) REFERENCES consent(id);

-- =====================================================================
-- 9. 内容版本与多渠道同步（地图 / 逐字稿索引 / 图片说明 / 离线包）
-- =====================================================================
CREATE TABLE content_version (
    version         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note            TEXT,
    created_by      TEXT NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE channel_sync (
    channel         TEXT PRIMARY KEY CHECK (channel IN
                    ('map_tiles','transcript_index','captions','offline_package')),
    version         BIGINT NOT NULL REFERENCES content_version(version),
    state           TEXT NOT NULL CHECK (state IN
                    ('synced','building','stale','failed','withdrawn')),
    note            TEXT,                          -- 给网页看的"尚未同步"解释
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- 撤回墓碑：撤权/匿名收窄的快道，各渠道必须 ack 后才算追平
CREATE TABLE revocation_tombstone (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_kind     TEXT NOT NULL CHECK (entity_kind IN ('photo','transcript','narrative','identity')),
    entity_id       BIGINT NOT NULL,
    event_id        BIGINT NOT NULL REFERENCES event(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entity_kind, entity_id)
);
CREATE TABLE channel_tombstone_ack (
    tombstone_id    BIGINT REFERENCES revocation_tombstone(id),
    channel         TEXT REFERENCES channel_sync(channel),
    acked_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tombstone_id, channel)
);

-- =====================================================================
-- 10. 离线包版本与吊销（旧包返回）
-- =====================================================================
CREATE TABLE offline_package (
    package_version BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content_version BIGINT NOT NULL REFERENCES content_version(version),
    manifest_hash   TEXT NOT NULL,
    expires_at      timestamptz NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE revoked_manifest (
    manifest_hash   TEXT PRIMARY KEY,
    reason          TEXT NOT NULL,                 -- 撤权 / 安全边界变化
    revoked_at      timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 11. 派生：时期快照缓存（方案 A，只读、可整体重建、永不原地更新）
-- =====================================================================
CREATE TABLE era_snapshot (
    snapshot_version BIGINT NOT NULL,
    as_of           date NOT NULL,
    realm           realm_kind NOT NULL,
    place_id        BIGINT NOT NULL,
    name            TEXT,
    geom            geometry(Geometry, 3857),
    relations       jsonb NOT NULL DEFAULT '[]',
    certainty       certainty_kind NOT NULL,
    generated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (snapshot_version, place_id)
);
CREATE INDEX idx_era_lookup ON era_snapshot (as_of, realm, place_id);

-- =====================================================================
-- 12. 路由安全：路径规划前的服务端开放面包含校验（示例查询）
--     任何候选边的中点/缓冲区不在当日 approved 开放面内 → 拒绝，
--     历史轨道不在 walk_edge 中，结构上无法被当作步道。
-- =====================================================================
-- SELECT we.id
-- FROM walk_edge we
-- JOIN access_area aa
--   ON aa.approval_status = 'approved'
--  AND aa.valid_from <= :d AND :d < aa.valid_to
--  AND ST_Contains(aa.boundary, ST_LineInterpolatePoint(we.geom, 0.5))
-- WHERE we.accessible
--   AND we.valid_from <= :d AND :d < we.valid_to
--   AND ST_DWithin(  -- 整条边留安全缓冲，防止贴边穿出
--       aa.boundary, we.geom, 0) = TRUE ;          -- 实际用 ST_Covers(geom, edge) 逐段校验
--
-- 当日开放范围（跨日公告区间相交；未到发布时间不生效）：
-- SELECT aa.*
-- FROM access_area aa
-- JOIN opening_announcement oa ON oa.access_area_id = aa.id
-- WHERE aa.approval_status = 'approved'
--   AND oa.published_at <= now()
--   AND oa.open_from <= :ts AND :ts < oa.open_to
--   AND aa.valid_from <= :d AND :d < aa.valid_to;

-- =====================================================================
-- 13. AS OF 折叠：确定层 vs 可能层（unknown 端点不产生"确定命中"）
-- =====================================================================
-- SELECT pr.*,
--   CASE
--     WHEN pr.valid_from IS NOT NULL AND pr.valid_to IS NOT NULL
--          AND pr.valid_from <= :d AND :d < pr.valid_to THEN 'definite_hit'
--     WHEN (pr.valid_from_unknown OR pr.valid_to_unknown)
--          AND (pr.valid_to IS NULL OR :d < pr.valid_to)
--          AND (pr.valid_from IS NULL OR :d >= pr.valid_from) THEN 'possible_hit'
--     ELSE 'miss'
--   END AS hit_kind
-- FROM place_relation pr
-- WHERE pr.recorded_to = '9999-12-31'              -- 仅当前记录版本
--   AND pr.from_place_id = :place
--   AND (
--        (pr.valid_from IS NOT NULL AND pr.valid_to IS NOT NULL
--         AND pr.valid_from <= :d AND :d < pr.valid_to)
--     OR (pr.valid_from_unknown AND (pr.valid_to IS NULL OR :d < pr.valid_to))
--     OR (pr.valid_to_unknown   AND (pr.valid_from IS NULL OR :d >= pr.valid_from))
--   );
