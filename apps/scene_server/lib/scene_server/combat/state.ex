defmodule SceneServer.Combat.State do
  @moduledoc """
  Mutable authoritative combat state for one combat actor.

  This struct is embedded inside both `SceneServer.PlayerCharacter` and
  `SceneServer.Npc.Actor`, which lets both actor types share the same HP/death
  state transitions without sharing higher-level process logic.
  """

  alias SceneServer.Combat.Profile

  @enforce_keys [:hp, :max_hp, :alive, :deaths]
  defstruct [:hp, :max_hp, :alive, :deaths]

  @type result ::
          {:ignored, t()}
          | {:damaged, t(), non_neg_integer()}
          | {:killed, t(), non_neg_integer()}

  @type t :: %__MODULE__{
          hp: non_neg_integer(),
          max_hp: pos_integer(),
          alive: boolean(),
          deaths: non_neg_integer()
        }

  @doc """
  Builds an initial alive combat state from a combat profile.
  """
  @spec new(Profile.t()) :: t()
  def new(%Profile{} = profile) do
    %__MODULE__{
      hp: profile.max_hp,
      max_hp: profile.max_hp,
      alive: true,
      deaths: 0
    }
  end

  @doc """
  Applies damage and returns whether the hit was ignored, damaging, or killing.
  """
  @spec apply_damage(t(), non_neg_integer()) :: result()
  def apply_damage(%__MODULE__{alive: false} = state, _damage), do: {:ignored, state}
  def apply_damage(%__MODULE__{} = state, damage) when damage <= 0, do: {:ignored, state}

  def apply_damage(%__MODULE__{} = state, damage) do
    hp_after = max(state.hp - damage, 0)

    if hp_after == 0 do
      next_state = %{state | hp: 0, alive: false, deaths: state.deaths + 1}
      {:killed, next_state, damage}
    else
      next_state = %{state | hp: hp_after}
      {:damaged, next_state, damage}
    end
  end

  @doc """
  Restores the actor to a full-HP alive state while preserving death count.
  """
  @spec respawn(t()) :: t()
  def respawn(%__MODULE__{} = state) do
    %{state | hp: state.max_hp, alive: true}
  end
end
