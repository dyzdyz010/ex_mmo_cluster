# Phase 5.C 第一批 tag catalog seed (v1).
#
# 设计草案：docs/plans/2026-05-13-phase5c-first-batch-catalog-seed.md
# 用户 2026-05-13 approve C-8 推荐方案（8 个第一批 tag）。
#
# Tag 是纯 set membership，无 value / merge_rule / dynamic（Phase 1.3 T-2
# 决策：要 value 走 AttributeSet / AttributeCatalog）。
# 一旦发出即冻结：id ↔ name 映射 wire 上下游已落地后不可重排。

%{
  catalog_version: 2,
  definitions: [
    %{id: 1, name: "flammable"},
    %{id: 2, name: "conductive"},
    %{id: 3, name: "wet"},
    %{id: 4, name: "frozen"},
    %{id: 5, name: "burning"},
    %{id: 6, name: "magical"},
    %{id: 7, name: "structural"},
    %{id: 8, name: "transparent"},
    # 功能完善 · 反应层 R7:电负载"通电"权威状态(闭环电流驱动 → 设备基础)。append-only。
    %{id: 9, name: "powered"}
  ]
}
