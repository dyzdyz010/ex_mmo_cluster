defmodule SceneServer.Combat.Skill do
  @moduledoc """
  Canonical data-driven skill catalog for the demo combat runtime.

  Skills are assembled from declarative targeting, delivery, and effect data so
  new skills can be introduced by composing data instead of writing one module
  per skill.
  """

  alias SceneServer.Combat.EffectSpec

  @type vector :: {float(), float(), float()}
  @type target_mode :: :auto | :actor | :point | :self
  @type delivery_kind :: :instant | :projectile

  @enforce_keys [:id, :name, :cooldown_ms, :target_mode, :range, :delivery_kind, :effects]
  defstruct [
    :id,
    :name,
    :cooldown_ms,
    :target_mode,
    :range,
    :delivery_kind,
    :projectile_speed,
    :cast_cue_kind,
    :cast_cue_duration_ms,
    :effects
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          name: String.t(),
          cooldown_ms: pos_integer(),
          target_mode: target_mode(),
          range: float(),
          delivery_kind: delivery_kind(),
          projectile_speed: float() | nil,
          cast_cue_kind: atom() | nil,
          cast_cue_duration_ms: non_neg_integer() | nil,
          effects: [EffectSpec.t()]
        }

  @doc """
  Looks up a skill definition by ID.
  """
  @spec fetch(pos_integer()) :: {:ok, t()} | {:error, :invalid_skill}
  def fetch(1), do: {:ok, melee_demo_skill()}
  def fetch(2), do: {:ok, projectile_demo_skill()}
  def fetch(3), do: {:ok, aoe_demo_skill()}
  def fetch(4), do: {:ok, trigger_demo_skill()}
  def fetch(101), do: {:ok, npc_spit_skill()}
  def fetch(_skill_id), do: {:error, :invalid_skill}

  defp melee_demo_skill do
    %__MODULE__{
      id: 1,
      name: "Arc Slash",
      cooldown_ms: 650,
      target_mode: :actor,
      range: 96.0,
      delivery_kind: :instant,
      cast_cue_kind: :melee_arc,
      cast_cue_duration_ms: 250,
      effects: [
        EffectSpec.primary(25, cue_kind: :impact_pulse, cue_duration_ms: 180)
      ]
    }
  end

  defp projectile_demo_skill do
    %__MODULE__{
      id: 2,
      name: "Arc Bolt",
      cooldown_ms: 850,
      target_mode: :actor,
      range: 360.0,
      delivery_kind: :projectile,
      projectile_speed: 520.0,
      cast_cue_kind: :projectile,
      cast_cue_duration_ms: 500,
      effects: [
        EffectSpec.primary(18, cue_kind: :impact_pulse, cue_duration_ms: 200)
      ]
    }
  end

  defp aoe_demo_skill do
    %__MODULE__{
      id: 3,
      name: "Target Ring",
      cooldown_ms: 1_400,
      target_mode: :point,
      range: 420.0,
      delivery_kind: :instant,
      cast_cue_kind: :aoe_ring,
      cast_cue_duration_ms: 450,
      effects: [
        EffectSpec.circle(16, 120.0,
          anchor_kind: :point,
          cue_kind: :aoe_ring,
          cue_duration_ms: 450,
          max_targets: 6
        )
      ]
    }
  end

  defp trigger_demo_skill do
    %__MODULE__{
      id: 4,
      name: "Cascade Sigil",
      cooldown_ms: 1_600,
      target_mode: :actor,
      range: 380.0,
      delivery_kind: :projectile,
      projectile_speed: 460.0,
      cast_cue_kind: :projectile,
      cast_cue_duration_ms: 550,
      effects: [
        EffectSpec.primary(12,
          cue_kind: :impact_pulse,
          cue_duration_ms: 220,
          follow_ups: [
            EffectSpec.circle(10, 90.0,
              anchor_kind: :target,
              cue_kind: :aoe_ring,
              cue_duration_ms: 420,
              max_targets: 6
            ),
            EffectSpec.chain(8, 180.0, 2,
              anchor_kind: :target,
              cue_kind: :chain_arc,
              cue_duration_ms: 260
            )
          ]
        )
      ]
    }
  end

  defp npc_spit_skill do
    %__MODULE__{
      id: 101,
      name: "Slime Spit",
      cooldown_ms: 1_250,
      target_mode: :actor,
      range: 220.0,
      delivery_kind: :projectile,
      projectile_speed: 320.0,
      cast_cue_kind: :projectile,
      cast_cue_duration_ms: 700,
      effects: [
        EffectSpec.primary(10, cue_kind: :impact_pulse, cue_duration_ms: 180)
      ]
    }
  end
end
