defmodule SceneServer.Combat.EffectSpec do
  @moduledoc """
  Declarative combat effect definition used by the generic skill executor.

  Effects are data, not per-skill modules. Different skills are produced by
  combining delivery + targeting + one or more effect specs.
  """

  alias SceneServer.Combat.EffectEvent

  @type cue_kind :: EffectEvent.cue_kind()
  @type pattern_kind :: :primary | :circle | :chain
  @type anchor_kind :: :source | :target | :point

  @enforce_keys [:pattern_kind, :anchor_kind, :damage]
  defstruct [
    :pattern_kind,
    :anchor_kind,
    :damage,
    :radius,
    :max_targets,
    :cue_kind,
    :cue_duration_ms,
    :follow_ups
  ]

  @type t :: %__MODULE__{
          pattern_kind: pattern_kind(),
          anchor_kind: anchor_kind(),
          damage: non_neg_integer(),
          radius: float() | nil,
          max_targets: pos_integer() | nil,
          cue_kind: cue_kind() | nil,
          cue_duration_ms: non_neg_integer() | nil,
          follow_ups: [t()] | nil
        }

  @doc """
  Builds a primary-target damage effect.
  """
  @spec primary(non_neg_integer(), keyword()) :: t()
  def primary(damage, opts \\ []) do
    %__MODULE__{
      pattern_kind: :primary,
      anchor_kind: Keyword.get(opts, :anchor_kind, :target),
      damage: damage,
      cue_kind: Keyword.get(opts, :cue_kind),
      cue_duration_ms: Keyword.get(opts, :cue_duration_ms, 250),
      follow_ups: Keyword.get(opts, :follow_ups, [])
    }
  end

  @doc """
  Builds a circle-AOE damage effect around the chosen anchor.
  """
  @spec circle(non_neg_integer(), float(), keyword()) :: t()
  def circle(damage, radius, opts \\ []) do
    %__MODULE__{
      pattern_kind: :circle,
      anchor_kind: Keyword.get(opts, :anchor_kind, :point),
      damage: damage,
      radius: radius,
      max_targets: Keyword.get(opts, :max_targets),
      cue_kind: Keyword.get(opts, :cue_kind, :aoe_ring),
      cue_duration_ms: Keyword.get(opts, :cue_duration_ms, 450),
      follow_ups: Keyword.get(opts, :follow_ups, [])
    }
  end

  @doc """
  Builds a multi-target single-hit chain effect around the chosen anchor.
  """
  @spec chain(non_neg_integer(), float(), pos_integer(), keyword()) :: t()
  def chain(damage, radius, max_targets, opts \\ []) do
    %__MODULE__{
      pattern_kind: :chain,
      anchor_kind: Keyword.get(opts, :anchor_kind, :target),
      damage: damage,
      radius: radius,
      max_targets: max_targets,
      cue_kind: Keyword.get(opts, :cue_kind, :chain_arc),
      cue_duration_ms: Keyword.get(opts, :cue_duration_ms, 280),
      follow_ups: Keyword.get(opts, :follow_ups, [])
    }
  end
end
