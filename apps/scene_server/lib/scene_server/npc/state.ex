defmodule SceneServer.Npc.State do
  @moduledoc """
  Runtime AI/intent state for one NPC actor.

  This is intentionally separate from movement and combat state so the NPC actor
  can evolve intent (idle/chase/attack/return_home/dead) without conflating that
  with physical position or HP bookkeeping.
  """

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

  @doc """
  Builds the default idle intent state for a freshly spawned or respawned NPC.
  """
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
