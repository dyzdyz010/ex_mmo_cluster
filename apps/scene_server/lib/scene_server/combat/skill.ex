defmodule SceneServer.Combat.Skill do
  @enforce_keys [:id, :damage, :radius, :cooldown_ms]
  defstruct [:id, :damage, :radius, :cooldown_ms]

  @type t :: %__MODULE__{
          id: pos_integer(),
          damage: pos_integer(),
          radius: float(),
          cooldown_ms: pos_integer()
        }

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
