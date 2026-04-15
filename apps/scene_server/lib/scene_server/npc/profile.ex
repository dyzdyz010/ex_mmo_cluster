defmodule SceneServer.Npc.Profile do
  @moduledoc """
  Static NPC template data for one spawned actor.

  `NpcProfile` describes the server-side identity, perception ranges, movement
  tuning overrides, and attack parameters for a concrete NPC instance. Runtime
  mutable data lives in `Npc.State`, `Movement.State`, and `Combat.State`.
  """

  @enforce_keys [
    :npc_id,
    :name,
    :spawn_position,
    :aggro_radius,
    :attack_range,
    :leash_radius,
    :brain_tick_ms,
    :movement_tick_ms,
    :movement_speed_scale,
    :max_hp,
    :respawn_ms,
    :skill_id,
    :skill_damage,
    :skill_radius,
    :skill_cooldown_ms
  ]
  defstruct [
    :npc_id,
    :name,
    :spawn_position,
    :aggro_radius,
    :attack_range,
    :leash_radius,
    :brain_tick_ms,
    :movement_tick_ms,
    :movement_speed_scale,
    :max_hp,
    :respawn_ms,
    :skill_id,
    :skill_damage,
    :skill_radius,
    :skill_cooldown_ms
  ]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          npc_id: pos_integer(),
          name: String.t(),
          spawn_position: vector(),
          aggro_radius: float(),
          attack_range: float(),
          leash_radius: float(),
          brain_tick_ms: pos_integer(),
          movement_tick_ms: pos_integer(),
          movement_speed_scale: float(),
          max_hp: pos_integer(),
          respawn_ms: pos_integer(),
          skill_id: pos_integer(),
          skill_damage: pos_integer(),
          skill_radius: float(),
          skill_cooldown_ms: pos_integer()
        }

  @doc """
  Builds a default NPC profile, allowing targeted overrides for demo/runtime use.
  """
  def default(npc_id, opts \\ []) do
    %__MODULE__{
      npc_id: npc_id,
      name: Keyword.get(opts, :name, "npc-#{npc_id}"),
      spawn_position: Keyword.get(opts, :spawn_position, {1_020.0, 1_020.0, 90.0}),
      aggro_radius: Keyword.get(opts, :aggro_radius, 180.0),
      attack_range: Keyword.get(opts, :attack_range, 96.0),
      leash_radius: Keyword.get(opts, :leash_radius, 320.0),
      brain_tick_ms: Keyword.get(opts, :brain_tick_ms, 250),
      movement_tick_ms: Keyword.get(opts, :movement_tick_ms, 100),
      movement_speed_scale: Keyword.get(opts, :movement_speed_scale, 0.8),
      max_hp: Keyword.get(opts, :max_hp, 100),
      respawn_ms: Keyword.get(opts, :respawn_ms, 3_000),
      skill_id: Keyword.get(opts, :skill_id, 101),
      skill_damage: Keyword.get(opts, :skill_damage, 25),
      skill_radius: Keyword.get(opts, :skill_radius, 96.0),
      skill_cooldown_ms: Keyword.get(opts, :skill_cooldown_ms, 750)
    }
  end
end
