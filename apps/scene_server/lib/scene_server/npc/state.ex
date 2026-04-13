defmodule SceneServer.Npc.State do
  alias SceneServer.Npc.Profile

  @enforce_keys [:npc_id, :intent]
  defstruct [
    :npc_id,
    :intent,
    :current_target_cid,
    :last_decision_at_ms
  ]

  @type intent :: :idle | :chase | :attack | :return_home | :dead
  @type t :: %__MODULE__{
          npc_id: pos_integer(),
          intent: intent(),
          current_target_cid: integer() | nil,
          last_decision_at_ms: integer() | nil
        }

  @spec idle(Profile.t()) :: t()
  def idle(%Profile{} = profile) do
    %__MODULE__{
      npc_id: profile.npc_id,
      intent: :idle,
      current_target_cid: nil,
      last_decision_at_ms: nil
    }
  end
end
