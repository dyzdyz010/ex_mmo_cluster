defmodule SceneServer.Combat.Skill do
  @moduledoc """
  Canonical skill definition used by the authoritative combat loop.

  Player casts currently resolve through `Skill.fetch/1`. NPCs can reuse the
  same struct shape, but may build it from NPC-specific profile data so their
  tuning does not leak back into player defaults.
  """

  @enforce_keys [:id, :damage, :radius, :cooldown_ms]
  defstruct [:id, :damage, :radius, :cooldown_ms]

  @type t :: %__MODULE__{
          id: pos_integer(),
          damage: pos_integer(),
          radius: float(),
          cooldown_ms: pos_integer()
        }

  @doc """
  Looks up a player-facing skill definition by ID.
  """
  @spec fetch(pos_integer()) :: {:ok, t()} | {:error, :invalid_skill}
  def fetch(1) do
    {:ok,
     %__MODULE__{
       id: 1,
       damage: 25,
       radius: 96.0,
       cooldown_ms: 750
     }}
  end

  def fetch(_skill_id), do: {:error, :invalid_skill}
end
