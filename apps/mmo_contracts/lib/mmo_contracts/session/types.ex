defmodule MmoContracts.Session.Identity do
  @moduledoc "M1 Identity 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:session_epoch, :scene_id, :scene_epoch]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.State do
  @moduledoc "M1 State 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:position, :velocity, :grounded, :yaw]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.Profile do
  @moduledoc "M1 Profile 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :radius,
    :half_height,
    :speed,
    :acceleration,
    :braking,
    :air_braking,
    :friction,
    :braking_friction_factor,
    :air_control,
    :gravity,
    :jump_speed,
    :step_height,
    :snap_distance,
    :skin,
    :slope_radians,
    :fixed_hz
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.Hello do
  @moduledoc "M1 Hello 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:protocol_version, :kernel_id, :profile_id]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.Join do
  @moduledoc "M1 Join 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:request_id, :username, :token, :cid, :scene_id]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.SessionStart do
  @moduledoc "M1 SessionStart 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :identity,
    :entity_id,
    :entity_epoch,
    :server_tick,
    :server_time_us,
    :content_version,
    :collision_revision,
    :baseline_transaction_seq,
    :state,
    :profile
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.Ready do
  @moduledoc "M1 Ready 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :baseline_transaction_seq, :collision_revision]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.InputStart do
  @moduledoc "M1 InputStart 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [
    :identity,
    :anchor_tick,
    :transaction_seq,
    :collision_revision,
    :state,
    :origin_tick,
    :first_input_seq,
    :prediction_lead_ticks
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.TimeProbe do
  @moduledoc "M1 TimeProbe 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:request_id, :client_send_us]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.TimeReply do
  @moduledoc "M1 TimeReply 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:request_id, :client_send_us, :server_receive_us, :server_send_us, :server_tick]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.EntityEnter do
  @moduledoc """
  M1 EntityEnter 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。
  `kind`（协议 16 起，末尾 1 字节）：0 = 玩家，1 = NPC；真值是 characters 表的 kind 列。
  """
  @enforce_keys [
    :identity,
    :entity_id,
    :entity_epoch,
    :interest_generation,
    :server_tick,
    :state,
    :kind
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.EntityLeave do
  @moduledoc "M1 EntityLeave 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :entity_id, :entity_epoch, :interest_generation, :server_tick]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.Transfer do
  @moduledoc "同一角色在公共时间线上移交的不可变切点。"
  @enforce_keys [
    :identity,
    :next_identity,
    :cut_tick,
    :processed_input_seq,
    :transaction_seq,
    :collision_revision,
    :state
  ]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.SessionEnd do
  @moduledoc "M1 SessionEnd 不可变契约值；字段顺序与单位见 Voxim Docs/M1/plan.md §2。"
  @enforce_keys [:identity, :reason]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.BodyState do
  @moduledoc "魔法增量 4（Hello 26）：本人身体的推导视图（生命、状态、核心/皮肤温度、伤病）；真值在 Scene 的 SceneServer.Body。"
  @enforce_keys [:identity, :life, :status, :core_k, :skin_k, :injuries]
  defstruct @enforce_keys
end

defmodule MmoContracts.Session.BodyInjury do
  @moduledoc "BodyState 的一条伤病：标签（如 trauma.thermal.burn）与严重度 1..。"
  @enforce_keys [:tag, :severity]
  defstruct @enforce_keys
end
