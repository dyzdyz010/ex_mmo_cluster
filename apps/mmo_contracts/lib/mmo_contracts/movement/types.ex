defmodule MmoContracts.Movement.InputFrame do
  @moduledoc "M1 InputFrame 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:input_seq, :axis_x, :axis_z, :yaw, :jump_pressed]
  defstruct @enforce_keys
end

defmodule MmoContracts.Movement.InputBatch do
  @moduledoc "M1 InputBatch 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :frames]
  defstruct @enforce_keys
end

defmodule MmoContracts.Movement.OwnerAck do
  @moduledoc "M1 OwnerAck 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :identity,
    :server_tick,
    :processed_input_seq,
    :collision_revision,
    :state,
    :substituted_through_seq
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Movement.SnapshotRecord do
  @moduledoc "M1 SnapshotRecord 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:entity_id, :entity_epoch, :interest_generation, :collision_revision, :state]
  defstruct @enforce_keys
end

defmodule MmoContracts.Movement.Snapshot do
  @moduledoc "M1 Snapshot 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :server_tick, :records]
  defstruct @enforce_keys
end
