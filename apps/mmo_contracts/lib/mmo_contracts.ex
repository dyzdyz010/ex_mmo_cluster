defmodule MmoContracts do
  @moduledoc """
  `mmo_contracts` 是 Hemifuture 体素 MMO 服务端**承重契约的单一来源**。

  它承载冻结架构规范(`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`,含 v2.0.2 反哺修订)
  中跨 app 共享的**信封与分类**,使 gate / world / scene / data 各层引用同一份定义,
  避免在各处重复或漂移。

  对齐迁移主线见 `docs/voxel-server-authority/2026-06-14-architecture-triage-and-alignment.md`。

  ## 当前内容(梯队 0 · 契约骨架前置)

  - `MmoContracts.StateClass` —— PERS-5 状态四分类。
  - `MmoContracts.Envelope.*` —— FROZEN-5 信封 typed struct 骨架(梯队 0 step 0.2)。
  - `MmoContracts.CellId` —— cell_id `(level, morton)` 与 v2.0.2 `region_id` 聚合等价(step 0.3)。
  - `MmoContracts.StateRegistry` —— 状态持有者分类登记与完备性校验(step 0.4)。

  ## 纪律

  - 本库**只放契约**(类型、struct、校验、版本字段),不放运行时行为、不依赖任何 sibling app。
  - 信封演进遵循 FROZEN-2/4:envelope 与兼容规则冻结,payload 走版本化;字段**只追加不破坏**。
  """
end
