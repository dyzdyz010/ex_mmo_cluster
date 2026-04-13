defmodule SceneServer.Combat.Profile do
  @enforce_keys [:max_hp, :respawn_ms]
  defstruct [:max_hp, :respawn_ms]

  @type t :: %__MODULE__{
          max_hp: pos_integer(),
          respawn_ms: pos_integer()
        }

  def default do
    %__MODULE__{
      max_hp: 100,
      respawn_ms: 3_000
    }
  end
end
