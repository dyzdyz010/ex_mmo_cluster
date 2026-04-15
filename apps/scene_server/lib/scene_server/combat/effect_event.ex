defmodule SceneServer.Combat.EffectEvent do
  @moduledoc """
  Authoritative gameplay-cue payload broadcast for client-side visuals.

  Best-practice-wise this sits between pure gameplay state replication and
  purely local visuals: damage/HP remain authoritative server state, while
  clients receive explicit, stateless effect cues so local and remote observers
  can render the same cast/impact sequence naturally.
  """

  @type vector :: {float(), float(), float()}
  @type cue_kind :: :melee_arc | :projectile | :aoe_ring | :chain_arc | :impact_pulse

  @enforce_keys [
    :source_cid,
    :skill_id,
    :cue_kind,
    :origin,
    :target_position,
    :radius,
    :duration_ms
  ]
  defstruct [
    :source_cid,
    :skill_id,
    :cue_kind,
    :origin,
    :target_cid,
    :target_position,
    :radius,
    :duration_ms
  ]

  @type t :: %__MODULE__{
          source_cid: integer(),
          skill_id: pos_integer(),
          cue_kind: cue_kind(),
          origin: vector(),
          target_cid: integer() | nil,
          target_position: vector(),
          radius: float(),
          duration_ms: non_neg_integer()
        }
end
