defmodule SceneServer.Combat.Executor do
  @moduledoc """
  Generic authoritative skill execution engine.

  Best-practice-wise this module separates:

  - authoritative gameplay outcomes (`CombatHit`, HP changes)
  - stateless replicated gameplay cues (`EffectEvent`)

  The server resolves the cast and schedules impact timing. Clients only render
  the cues they receive; they do not authoritatively decide hits.
  """

  alias SceneServer.Combat.{CastRequest, EffectEvent, EffectSpec, Skill, Targeting}

  @type vector :: {float(), float(), float()}

  @type resolved_cast :: %{
          source_cid: integer(),
          source_position: vector(),
          skill: Skill.t(),
          target_cid: integer() | nil,
          target_position: vector(),
          travel_ms: non_neg_integer(),
          effects: [EffectSpec.t()]
        }

  @type execution_result :: %{
          initial_cues: [EffectEvent.t()],
          delayed_cast: resolved_cast()
        }

  @type resolution_result :: %{
          cues: [EffectEvent.t()]
        }

  @doc """
  Resolves a cast request into authoritative target data plus the initial visual cues.
  """
  @spec prepare_cast(map(), CastRequest.t(), Skill.t()) ::
          {:ok, execution_result()} | {:error, atom()}
  def prepare_cast(
        %{cid: source_cid, position: source_position} = source_summary,
        %CastRequest{} = request,
        %Skill{} = skill
      ) do
    with :ok <- validate_target_mode(skill, request),
         {:ok, primary_target} <- resolve_primary_target(source_summary, request, skill),
         {:ok, target_position} <-
           resolve_target_position(source_summary, request, skill, primary_target) do
      travel_ms = travel_ms(skill, source_position, target_position)

      initial_cues =
        case skill.cast_cue_kind do
          nil ->
            []

          cue_kind ->
            [
              %EffectEvent{
                source_cid: source_cid,
                skill_id: skill.id,
                cue_kind: cue_kind,
                origin: source_position,
                target_cid: primary_target && primary_target.cid,
                target_position: target_position,
                radius: default_radius(skill),
                duration_ms: max(skill.cast_cue_duration_ms || travel_ms, travel_ms)
              }
            ]
        end

      {:ok,
       %{
         initial_cues: initial_cues,
         delayed_cast: %{
           source_cid: source_cid,
           source_position: source_position,
           skill: skill,
           target_cid: primary_target && primary_target.cid,
           target_position: target_position,
           travel_ms: travel_ms,
           effects: skill.effects
         }
       }}
    end
  end

  @doc """
  Resolves the delayed impact of a previously prepared cast.
  """
  @spec resolve_cast(resolved_cast()) :: resolution_result()
  def resolve_cast(%{effects: effects} = cast) when is_list(effects) do
    %{cues: resolve_effects(cast, effects, MapSet.new())}
  end

  defp resolve_effects(_cast, [], _visited_targets), do: []

  defp resolve_effects(cast, [effect | rest], visited_targets) do
    {effect_cues, next_visited} = resolve_effect(cast, effect, visited_targets)
    effect_cues ++ resolve_effects(cast, rest, next_visited)
  end

  defp resolve_effect(cast, %EffectSpec{} = effect, visited_targets) do
    anchor_position = anchor_position(cast, effect)
    targets = resolve_targets(cast, effect, anchor_position, visited_targets)

    {cues, next_visited} =
      Enum.reduce(targets, {[], visited_targets}, fn target, {acc, seen} ->
        hit_cues = apply_damage_and_collect_cues(cast, effect, anchor_position, target)
        follow_up_cues = resolve_follow_ups(cast, effect, target, seen)
        {acc ++ hit_cues ++ follow_up_cues, MapSet.put(seen, target.cid)}
      end)

    aoe_cue =
      if effect.pattern_kind == :circle and effect.cue_kind do
        [
          %EffectEvent{
            source_cid: cast.source_cid,
            skill_id: cast.skill.id,
            cue_kind: effect.cue_kind,
            origin: cast.source_position,
            target_cid: nil,
            target_position: anchor_position,
            radius: effect.radius || default_radius(cast.skill),
            duration_ms: effect.cue_duration_ms || 300
          }
        ]
      else
        []
      end

    {aoe_cue ++ cues, next_visited}
  end

  defp resolve_follow_ups(_cast, %EffectSpec{follow_ups: []}, _target, _seen), do: []

  defp resolve_follow_ups(cast, %EffectSpec{follow_ups: follow_ups}, target, seen) do
    followup_cast = %{
      cast
      | target_cid: target.cid,
        target_position: target.position
    }

    follow_ups
    |> Enum.reduce([], fn followup, acc ->
      {cues, _next_seen} = resolve_effect(followup_cast, followup, seen)
      acc ++ cues
    end)
  end

  defp apply_damage_and_collect_cues(cast, effect, anchor_position, target) do
    result =
      safe_actor_call(
        target.pid,
        {:apply_damage_effect, cast.source_cid, cast.skill.id, effect.damage, anchor_position}
      )

    impact_cues =
      case effect.cue_kind do
        cue_kind when cue_kind in [:impact_pulse, :chain_arc] ->
          [
            %EffectEvent{
              source_cid: cast.source_cid,
              skill_id: cast.skill.id,
              cue_kind: cue_kind,
              origin: anchor_origin_for_cue(cast, effect, anchor_position),
              target_cid: target.cid,
              target_position: target.position,
              radius: effect.radius || 0.0,
              duration_ms: effect.cue_duration_ms || 220
            }
          ]

        _ ->
          []
      end

    case result do
      {:ok, _hp_after} -> impact_cues
      _ -> []
    end
  end

  defp resolve_targets(cast, effect, anchor_position, visited_targets) do
    case effect.pattern_kind do
      :primary ->
        case target_summary(cast.target_cid) do
          {:ok, target} -> [target]
          _ -> []
        end

      :circle ->
        cast.source_cid
        |> Targeting.nearby_combatant_pids(anchor_position, effect.radius || 0.0)
        |> summaries_from_pids()
        |> maybe_limit(effect.max_targets)

      :chain ->
        cast.source_cid
        |> Targeting.nearby_combatant_pids(anchor_position, effect.radius || 0.0)
        |> summaries_from_pids()
        |> Enum.reject(fn target -> MapSet.member?(visited_targets, target.cid) end)
        |> Enum.sort_by(fn target -> distance(anchor_position, target.position) end)
        |> maybe_limit(effect.max_targets || 1)
    end
  end

  defp summaries_from_pids(pids) do
    Enum.flat_map(pids, fn pid ->
      case Targeting.safe_summary(pid) do
        {:ok, %{cid: cid, position: position, alive: true}} ->
          [%{pid: pid, cid: cid, position: position}]

        _ ->
          []
      end
    end)
  end

  defp target_summary(nil), do: {:error, :no_target}

  defp target_summary(target_cid) do
    with {:ok, summary} <- Targeting.safe_summary_by_cid(target_cid) do
      {:ok,
       %{
         cid: summary.cid,
         position: summary.position,
         pid: SceneServer.AoiManager.get_actor_pid(summary.cid)
       }}
    end
  end

  defp anchor_position(cast, effect) do
    case effect.anchor_kind do
      :source -> cast.source_position
      :target -> cast.target_position
      :point -> cast.target_position
    end
  end

  defp anchor_origin_for_cue(cast, effect, anchor_position) do
    case effect.pattern_kind do
      :chain -> anchor_position
      _ -> cast.source_position
    end
  end

  defp validate_target_mode(%Skill{target_mode: :point}, %CastRequest{target_mode: :point}),
    do: :ok

  defp validate_target_mode(%Skill{target_mode: :point}, %CastRequest{target_mode: :actor}),
    do: :ok

  defp validate_target_mode(%Skill{target_mode: :point}, %CastRequest{target_mode: :auto}),
    do: :ok

  defp validate_target_mode(%Skill{target_mode: :actor}, %CastRequest{target_mode: mode})
       when mode in [:auto, :actor],
       do: :ok

  defp validate_target_mode(%Skill{target_mode: :self}, %CastRequest{}), do: :ok
  defp validate_target_mode(%Skill{target_mode: mode}, %CastRequest{target_mode: mode}), do: :ok
  defp validate_target_mode(_skill, _request), do: {:error, :invalid_target_mode}

  defp resolve_primary_target(
         %{position: source_position},
         %CastRequest{target_mode: :actor, target_cid: target_cid},
         %Skill{range: range}
       ) do
    with {:ok, summary} <- Targeting.safe_summary_by_cid(target_cid),
         true <- summary.alive,
         true <- distance(source_position, summary.position) <= range do
      {:ok, summary}
    else
      _ -> {:error, :invalid_target}
    end
  end

  defp resolve_primary_target(%{cid: source_cid, position: source_position}, _request, %Skill{
         target_mode: :actor,
         range: range
       }) do
    case source_cid
         |> Targeting.nearby_combatant_pids(source_position, range)
         |> summaries_from_pids()
         |> Enum.sort_by(fn target -> distance(source_position, target.position) end)
         |> List.first() do
      nil -> {:error, :no_target}
      target -> {:ok, target}
    end
  end

  defp resolve_primary_target(
         %{position: source_position},
         %CastRequest{target_mode: :actor, target_cid: target_cid},
         %Skill{target_mode: :point, range: range}
       ) do
    with {:ok, summary} <- Targeting.safe_summary_by_cid(target_cid),
         true <- summary.alive,
         true <- distance(source_position, summary.position) <= range do
      {:ok, summary}
    else
      _ -> {:error, :invalid_target}
    end
  end

  defp resolve_primary_target(_source, _request, %Skill{target_mode: :point}), do: {:ok, nil}

  defp resolve_primary_target(%{cid: cid, position: position}, _request, %Skill{
         target_mode: :self
       }),
       do: {:ok, %{cid: cid, position: position}}

  defp resolve_primary_target(_source, _request, _skill), do: {:ok, nil}

  defp resolve_target_position(
         %{position: source_position},
         %CastRequest{target_mode: :point, target_position: target_position},
         %Skill{range: range},
         _primary_target
       )
       when is_tuple(target_position) do
    if distance(source_position, target_position) <= range do
      {:ok, target_position}
    else
      {:error, :out_of_range}
    end
  end

  defp resolve_target_position(_source, _request, _skill, %{position: position})
       when is_tuple(position),
       do: {:ok, position}

  defp resolve_target_position(
         %{position: source_position},
         _request,
         %Skill{target_mode: :self},
         _primary_target
       ),
       do: {:ok, source_position}

  defp resolve_target_position(
         %{cid: source_cid, position: source_position},
         _request,
         %Skill{target_mode: :point, range: range},
         _primary_target
       ) do
    case source_cid
         |> Targeting.nearby_combatant_pids(source_position, range)
         |> summaries_from_pids()
         |> Enum.sort_by(fn target -> distance(source_position, target.position) end)
         |> List.first() do
      nil -> {:error, :no_target}
      target -> {:ok, target.position}
    end
  end

  defp resolve_target_position(_source, _request, _skill, _primary_target),
    do: {:error, :no_target}

  defp maybe_limit(targets, nil), do: targets
  defp maybe_limit(targets, max_targets), do: Enum.take(targets, max_targets)

  defp travel_ms(%Skill{delivery_kind: :instant}, _origin, _target), do: 0

  defp travel_ms(%Skill{delivery_kind: :projectile, projectile_speed: speed}, origin, target)
       when is_number(speed) and speed > 0.0 do
    max(trunc(distance(origin, target) / speed * 1_000), 120)
  end

  defp default_radius(%Skill{effects: [effect | _]}) do
    effect.radius || 0.0
  end

  defp safe_actor_call(nil, _message), do: {:error, :missing_actor}

  defp safe_actor_call(pid, message) do
    try do
      GenServer.call(pid, message, 10_000)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp distance({ax, ay, az}, {bx, by, bz}) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end
end
