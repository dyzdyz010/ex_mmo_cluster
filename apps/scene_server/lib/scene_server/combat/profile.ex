defmodule SceneServer.Combat.Profile do
  @moduledoc """
  Static combat lifecycle parameters shared by player and NPC combat actors.

  `Combat.Profile` answers questions such as:

  - how much HP a combatant starts with
  - how long it takes to respawn after death

  The profile is intentionally small; skill-specific damage/range/cooldowns live
  elsewhere so combat lifecycle and skill definitions stay decoupled.
  """

  @enforce_keys [:max_hp, :respawn_ms]
  defstruct [:max_hp, :respawn_ms]

  @type t :: %__MODULE__{
          max_hp: pos_integer(),
          respawn_ms: pos_integer()
        }

  @doc """
  Returns the default combat profile used by training players/NPCs.
  """
  def default do
    %__MODULE__{
      max_hp: 100,
      respawn_ms: 3_000
    }
  end
end
