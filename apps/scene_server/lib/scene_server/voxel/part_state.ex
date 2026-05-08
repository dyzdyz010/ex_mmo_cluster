defmodule SceneServer.Voxel.PartState do
  @moduledoc """
  Runtime state for one prefab part inside a `SceneObjectInstance`.

  Phase 4 (D6 / D7):每 part 持有 `health`(damage 累计)+ `state_flags`
  (damaged / destroyed 位)。攻击命中某 micro slot → 服务端找出
  `owner_part_id` → `PartState.health -= damage`,`health <= 0` 触发
  `destroy_part`(D8 路径)。

  `health` 初始值 = part 在蓝图中的 `micro_count × ratio`,Phase 4 ratio 默认
  1.0(决策稿 D6)。Phase 5 引入 `PartDefinition.default_health_ratio` 协议
  字段后改 per-part。
  """

  import Bitwise

  @flag_damaged 0x01
  @flag_destroyed 0x02

  @max_u32 0xFFFF_FFFF

  defstruct part_id: 0, health: 0, state_flags: 0

  @type t :: %__MODULE__{
          part_id: 0..0xFFFF_FFFF,
          health: integer(),
          state_flags: 0..0xFFFF_FFFF
        }

  @doc "The 'damaged' state_flag bit (set when the part has taken any damage)."
  @spec flag_damaged() :: 1
  def flag_damaged, do: @flag_damaged

  @doc "The 'destroyed' state_flag bit (set when health <= 0 and mask wiped)."
  @spec flag_destroyed() :: 2
  def flag_destroyed, do: @flag_destroyed

  @doc "Builds and validates a PartState."
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    opts
    |> Map.new()
    |> normalize!()
  end

  @doc "Normalizes a struct or compatible map (string or atom keys)."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = ps) do
    ps |> Map.from_struct() |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      part_id: uint!(fetch(attrs, :part_id, 0), @max_u32, :part_id),
      health: int!(fetch(attrs, :health, 0), :health),
      state_flags: uint!(fetch(attrs, :state_flags, 0), @max_u32, :state_flags)
    }
  end

  @doc "True when the `damaged` bit is set."
  @spec damaged?(t()) :: boolean()
  def damaged?(%__MODULE__{state_flags: f}), do: band(f, @flag_damaged) != 0

  @doc "True when the `destroyed` bit is set."
  @spec destroyed?(t()) :: boolean()
  def destroyed?(%__MODULE__{state_flags: f}), do: band(f, @flag_destroyed) != 0

  @doc """
  Subtracts `damage` from `health`. Does **not** touch `state_flags`;
  callers (`ObjectRegistry.accumulate_damage`)decide when to flip
  `damaged` and trigger `destroy_part`.
  """
  @spec apply_damage(t(), non_neg_integer()) :: t()
  def apply_damage(%__MODULE__{} = ps, damage) when is_integer(damage) and damage >= 0 do
    %{ps | health: ps.health - damage}
  end

  @doc "Asserts the `damaged` bit (idempotent)."
  @spec mark_damaged(t()) :: t()
  def mark_damaged(%__MODULE__{} = ps) do
    %{ps | state_flags: bor(ps.state_flags, @flag_damaged)}
  end

  @doc "Clamps `health` to 0 and asserts `damaged | destroyed` bits (idempotent)."
  @spec mark_destroyed(t()) :: t()
  def mark_destroyed(%__MODULE__{} = ps) do
    %{ps | health: 0, state_flags: bor(ps.state_flags, bor(@flag_damaged, @flag_destroyed))}
  end

  @doc "Plain-map view (used when persisting to `voxel_scene_objects.part_states`)."
  @spec to_map(t()) :: %{
          part_id: non_neg_integer(),
          health: integer(),
          state_flags: non_neg_integer()
        }
  def to_map(%__MODULE__{} = ps) do
    %{part_id: ps.part_id, health: ps.health, state_flags: ps.state_flags}
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint!(value, max, _label) when is_integer(value) and value >= 0 and value <= max,
    do: value

  defp uint!(value, max, label),
    do: raise(ArgumentError, "#{label} value #{inspect(value)} outside 0..#{max}")

  defp int!(value, _label) when is_integer(value), do: value

  defp int!(value, label),
    do: raise(ArgumentError, "#{label} must be integer, got: #{inspect(value)}")
end
