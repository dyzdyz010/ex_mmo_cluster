defmodule SceneServer.Npc.Profile do
  @enforce_keys [
    :npc_id,
    :name,
    :spawn_position,
    :aggro_radius,
    :attack_range,
    :leash_radius,
    :brain_tick_ms
  ]
  defstruct [
    :npc_id,
    :name,
    :spawn_position,
    :aggro_radius,
    :attack_range,
    :leash_radius,
    :brain_tick_ms
  ]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          npc_id: pos_integer(),
          name: String.t(),
          spawn_position: vector(),
          aggro_radius: float(),
          attack_range: float(),
          leash_radius: float(),
          brain_tick_ms: pos_integer()
        }

  def default(npc_id, opts \\ []) do
    %__MODULE__{
      npc_id: npc_id,
      name: Keyword.get(opts, :name, "npc-#{npc_id}"),
      spawn_position: Keyword.get(opts, :spawn_position, {1_020.0, 1_020.0, 90.0}),
      aggro_radius: Keyword.get(opts, :aggro_radius, 180.0),
      attack_range: Keyword.get(opts, :attack_range, 96.0),
      leash_radius: Keyword.get(opts, :leash_radius, 320.0),
      brain_tick_ms: Keyword.get(opts, :brain_tick_ms, 250)
    }
  end
end
