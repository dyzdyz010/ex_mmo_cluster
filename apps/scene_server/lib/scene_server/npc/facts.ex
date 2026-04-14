defmodule SceneServer.Npc.Facts do
  @moduledoc """
  Read-only perception snapshot consumed by `SceneServer.Npc.Brain`.

  `Npc.Actor` gathers these facts from authoritative AOI/combat state and then
  passes them to the pure brain layer so decision logic stays deterministic and
  testable.
  """

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
