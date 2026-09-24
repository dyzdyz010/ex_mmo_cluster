defmodule MmoContracts.Voxel.ChunkOccupancy do
  @moduledoc "M1 ChunkOccupancy 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:coord, :n, :scale_m, :origin_m, :cells]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.CanonicalSnapshot do
  @moduledoc "M1 CanonicalSnapshot 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :content_version,
    :transaction_seq,
    :l0_min,
    :l0_max_exclusive,
    :regions,
    :chunks
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.CanonicalDelta do
  @moduledoc "M1 CanonicalDelta 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:transaction_seq, :transaction, :chunks]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.CollisionApplied do
  @moduledoc "M1 CollisionApplied 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :collision_revision, :transaction_seq, :apply_tick, :changed_chunks]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.CanonicalBootstrap do
  @moduledoc "M1 CanonicalBootstrap 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :identity,
    :content_version,
    :collision_revision,
    :transaction_seq,
    :l0_min,
    :l0_max_exclusive,
    :travel_min_m,
    :travel_max_exclusive_m,
    :regions
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.TimelineFence do
  @moduledoc "M1 TimelineFence 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :server_tick, :transaction_seq, :collision_revision]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.CollisionWindow do
  @moduledoc "完整移动碰撞窗口在 apply_tick 原子替换；N 仍是 World 事务水位。"
  @enforce_keys [
    :identity,
    :apply_tick,
    :content_version,
    :collision_revision,
    :transaction_seq,
    :l0_min,
    :l0_max_exclusive,
    :travel_min_m,
    :travel_max_exclusive_m,
    :regions
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Voxel.PropertyBatch do
  @moduledoc "全局系统功能：同一窗口与提交点的完整属性快照或状态增量。"
  @enforce_keys [
    :identity,
    :transaction_seq,
    :l0_min,
    :l0_max_exclusive,
    :complete,
    :hp_enabled,
    :digest,
    :thermal_enabled,
    :ambient_kelvin,
    :epochs,
    :states
  ]
  # 协议 19：受保护区域记录（`Voxel.Codec.encode_protection/1`）；完整批次为窗口内全部区域，增量批次为本事务的变化。
  # 魔法增量 2（协议 25）：拟态记录（`Voxel.Codec.encode_semblances/1`），完整批次为窗口内全部拟态，增量批次为本事务的变化。
  defstruct @enforce_keys ++ [protection: <<>>, semblances: <<>>]
end
