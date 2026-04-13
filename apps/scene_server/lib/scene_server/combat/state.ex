defmodule SceneServer.Combat.State do
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

  @spec new(Profile.t()) :: t()
  def new(%Profile{} = profile) do
    %__MODULE__{
      hp: profile.max_hp,
      max_hp: profile.max_hp,
      alive: true,
      deaths: 0
    }
  end

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

  @spec respawn(t()) :: t()
  def respawn(%__MODULE__{} = state) do
    %{state | hp: state.max_hp, alive: true}
  end
end
