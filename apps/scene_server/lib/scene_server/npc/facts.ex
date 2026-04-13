defmodule SceneServer.Npc.Facts do
  @enforce_keys [:alive, :position, :spawn_position]
  defstruct [
    :alive,
    :position,
    :spawn_position,
    :target_cid,
    :target_distance,
    :distance_from_spawn
  ]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          alive: boolean(),
          position: vector(),
          spawn_position: vector(),
          target_cid: integer() | nil,
          target_distance: float() | nil,
          distance_from_spawn: float() | nil
        }
end
