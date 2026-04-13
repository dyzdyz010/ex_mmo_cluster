defmodule SceneServer.Npc.State do
  alias SceneServer.Npc.Profile

  @enforce_keys [:npc_id, :position, :intent, :alive]
  defstruct [
    :npc_id,
    :position,
    :intent,
    :alive,
    :current_target_cid,
    :last_decision_at_ms
  ]

  @type vector :: {float(), float(), float()}
  @type intent :: :idle | :chase | :attack | :return_home | :dead
  @type t :: %__MODULE__{
          npc_id: pos_integer(),
          position: vector(),
          intent: intent(),
          alive: boolean(),
          current_target_cid: integer() | nil,
          last_decision_at_ms: integer() | nil
        }

  @spec idle(Profile.t()) :: t()
  def idle(%Profile{} = profile) do
    %__MODULE__{
      npc_id: profile.npc_id,
      position: profile.spawn_position,
      intent: :idle,
      alive: true,
      current_target_cid: nil,
      last_decision_at_ms: nil
    }
  end
end
