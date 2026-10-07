# 矿山工业遗产叙事站

Web 联动矿井、轨道、工人社区的工业遗产叙事系统。核心约束：
**历史空间与当前参观边界分域；变化以事件表达；时间未知与来源矛盾显式保留；
事故叙述证据优先；参观功能只引用已批准区域。**

## 目录

- `docs/design.md` —— 方案设计（方案选型、时间语义、模型、同步、离线、验收对照）
- `db/schema.sql` —— PostgreSQL 14+/PostGIS 3 双时态数据库骨架（可直接建库审阅）

## 关键决策（摘要）

1. **查询时解析有效区间（双时态 + 事件溯源）为权威层**；按时期生成的空间视图只是
   版本化、可重建的只读缓存。详见 `docs/design.md` §1。
2. 有效区间半开 `[valid_from, valid_to)`；`9999` = 主张至今有效，
   `*_unknown` = 端点未知，二者严格区分；查询分 *确定命中 / 可能命中*。
3. 井区合并、线路废弃、轨道断裂、社区搬迁 = `event`，由事件开闭 `place_relation` 区间；
   互斥来源进 `conflict_group`，不静默合并，裁决本身也是事件。
4. `historical` 与 `current` 双空间域：历史照片只在历史图层定位；
   历史轨道段（`historical_track_segment`）与行人图（`walk_edge`）无任何连接；
   路径在服务端做批准开放面（`access_area` approved）包含校验。
5. 事故/危险劳动：原证据在 `evidence_quote`/`transcript_segment`，
   自动摘要分字段且必须附来源与不确定标记，任何渠道不得移除或视觉淡化。
6. 许可：匿名在存储边界假名化（`interviewee_identity` 受限表）；
   匿名收窄、照片撤权走撤回快道（`revocation_tombstone`），
   同步驱动地图切片、逐字稿索引、图片说明三渠道。
7. 渠道状态经 `channel_sync` 对用户可见（"逐字稿索引尚未同步到 v412"）；
   打印安全信息带资料时间与版本，并区分历史通道/当前路径图例。
8. 旧离线包返回走 `offline_package` 版本协商 + `revoked_manifest` 吊销 + 过期在线核对。

## 验收点对照

| 验收输入 | 落点 |
|---|---|
| 轨道断裂 | `event(track_break)` 终结关系/轨道段区间；断裂段仅历史展示 |
| 开放范围跨日变更 | `opening_announcement` 时段区间按查询时刻相交 |
| 受访者匿名要求 | `consent` 收窄 + tombstone + 受限身份表 + 三渠道摘除 |
| 照片撤权 | `photo_right=revoked` + 公开桶摘除 + caption 占位 + 离线吊销 |
| 旧离线包返回 | 版本协商三态：current / upgrade_required / revoked |
| 历史通道≠当前路径 | realm 隔离、步行图独立、服务端开放面校验、打印图例分离 |
| 时间未知 / 来源矛盾 | unknown 哨兵 + possible 图层；conflict_group + resolution 事件 |
