defmodule WorldServer.Voxel.MigrationPlan do
  @moduledoc """
  World-owned **cell_migration** plan for handing one voxel region (Cell) to another Scene.

  规范术语对齐(梯队1 step1.6,CELL-10/11):本结构即 **cell_migration**——*Cell 本身*迁移到新
  CellServer/Scene 实例,**唯一递增 Cell `owner_epoch` 的地方**(经 `new_lease` 的 owner_epoch)。
  与 **entity_handoff**(实体跨 Cell,不递增 owner_epoch,见 `WorldServer.Entity.HandoffPlan` /
  `MmoContracts.Envelope.EntityHandoff`)严格区分。

  cutover 在 `cutover/2` 写入 `migration_tick`/`commit_watermark`(取 final-catchup-ack 的
  `max_chunk_version` 前沿——v2.0.2 承认 chunk_version 作 cell_seq 聚合等价,该前沿即所有权切换的
  版本边界,旧 owner `migration_tick` 之后禁写,CELL-20/TIME-6),并可经 `cell_migration_envelope/1`
  构 `MmoContracts.Envelope.CellMigration` 信封(FROZEN-5)。

  The plan is a control-plane record only. World owns the state machine and lease
  handoff metadata; Scene adapters can read the handoff payload and prewarm
  chunks, but the current write lease is not changed until the ledger performs
  cutover.
  """

  alias MmoContracts.Envelope.CellMigration

  @enforce_keys [
    :migration_id,
    :logical_scene_id,
    :region_id,
    :source_scene_instance_ref,
    :target_scene_instance_ref,
    :new_lease,
    :affected_chunk_min,
    :affected_chunk_max,
    :token_version,
    :inserted_at_ms,
    :updated_at_ms
  ]
  defstruct [
    :migration_id,
    :logical_scene_id,
    :region_id,
    :source_scene_instance_ref,
    :target_scene_instance_ref,
    :old_lease,
    :new_lease,
    :affected_chunk_min,
    :affected_chunk_max,
    :token_version,
    :inserted_at_ms,
    :updated_at_ms,
    :prewarmed_at_ms,
    :cutover_at_ms,
    :completed_at_ms,
    # 梯队1 step1.6(cell_migration 正名,CELL-10/20/TIME-6):cutover 时由 final-catchup-ack 的
    # max_chunk_version 前沿写入。旧 owner 在 migration_tick 之后禁止再产生该 Cell 的权威写入。
    :migration_tick,
    :commit_watermark,
    state: :prewarming,
    slice_axis: :x,
    slice_width: 1,
    next_slice_index: 0,
    total_slices: 0,
    planned_slices: [],
    prewarm_acks: %{},
    final_catchup_acks: %{}
  ]

  @type chunk_coord :: {integer(), integer(), integer()}
  @type state :: :prewarming | :prewarmed | :cutover | :completed
  @type slice :: %{
          required(:slice_id) => binary(),
          required(:index) => non_neg_integer(),
          required(:bounds_chunk_min) => chunk_coord(),
          required(:bounds_chunk_max) => chunk_coord(),
          required(:state) => :planned | :prewarmed,
          optional(:prewarm_ack) => map(),
          optional(:final_catchup_ack) => map()
        }

  @type t :: %__MODULE__{
          migration_id: binary(),
          logical_scene_id: non_neg_integer(),
          region_id: non_neg_integer(),
          state: state(),
          source_scene_instance_ref: non_neg_integer(),
          target_scene_instance_ref: non_neg_integer(),
          old_lease: struct() | nil,
          new_lease: struct(),
          affected_chunk_min: chunk_coord(),
          affected_chunk_max: chunk_coord(),
          token_version: non_neg_integer(),
          inserted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          prewarmed_at_ms: non_neg_integer() | nil,
          cutover_at_ms: non_neg_integer() | nil,
          completed_at_ms: non_neg_integer() | nil,
          migration_tick: non_neg_integer() | nil,
          commit_watermark: non_neg_integer() | nil,
          slice_axis: :x | :y | :z,
          slice_width: pos_integer(),
          next_slice_index: non_neg_integer(),
          total_slices: non_neg_integer(),
          planned_slices: [slice()],
          prewarm_acks: %{optional(binary()) => map()},
          final_catchup_acks: %{optional(binary()) => map()}
        }

  @doc "Builds a normalized migration plan."
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    affected_chunk_min = coord!(fetch!(attrs, :affected_chunk_min))
    affected_chunk_max = coord!(fetch!(attrs, :affected_chunk_max))
    slice_axis = Map.get(attrs, :slice_axis, :x)
    slice_width = Map.get(attrs, :slice_width, 1)

    validate_bounds!(affected_chunk_min, affected_chunk_max)
    validate_slice_axis!(slice_axis)
    validate_slice_width!(slice_width)

    %__MODULE__{
      migration_id: fetch!(attrs, :migration_id),
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      region_id: fetch!(attrs, :region_id),
      source_scene_instance_ref: fetch!(attrs, :source_scene_instance_ref),
      target_scene_instance_ref: fetch!(attrs, :target_scene_instance_ref),
      old_lease: Map.get(attrs, :old_lease),
      new_lease: fetch!(attrs, :new_lease),
      affected_chunk_min: affected_chunk_min,
      affected_chunk_max: affected_chunk_max,
      token_version: fetch!(attrs, :token_version),
      inserted_at_ms: fetch!(attrs, :inserted_at_ms),
      updated_at_ms: fetch!(attrs, :updated_at_ms),
      slice_axis: slice_axis,
      slice_width: slice_width,
      total_slices: total_slices(affected_chunk_min, affected_chunk_max, slice_axis, slice_width)
    }
  end

  @doc "Plans the next prewarm slice and advances the plan cursor."
  def plan_next_slice(%__MODULE__{state: :prewarming} = plan, now_ms) do
    if plan.next_slice_index < plan.total_slices do
      slice = build_slice(plan, plan.next_slice_index)

      next_plan = %{
        plan
        | planned_slices: plan.planned_slices ++ [slice],
          next_slice_index: plan.next_slice_index + 1,
          updated_at_ms: now_ms
      }

      {:ok, slice, next_plan}
    else
      {:error, :migration_slices_exhausted}
    end
  end

  def plan_next_slice(%__MODULE__{}, _now_ms), do: {:error, :migration_not_prewarming}

  @doc "Records one target Scene prewarm ACK for a planned slice."
  def mark_slice_prewarmed(%__MODULE__{state: :prewarming} = plan, attrs, now_ms) do
    with {:ok, ack} <- normalize_slice_ack(plan, attrs),
         {:ok, slice} <- fetch_planned_slice(plan, ack.slice_id) do
      next_slice = Map.merge(slice, %{state: :prewarmed, prewarm_ack: ack})

      next_plan = %{
        plan
        | planned_slices: replace_slice(plan.planned_slices, next_slice),
          prewarm_acks: Map.put(plan.prewarm_acks, ack.slice_id, ack),
          updated_at_ms: now_ms
      }

      {:ok, next_plan, next_slice}
    end
  end

  def mark_slice_prewarmed(%__MODULE__{}, _attrs, _now_ms),
    do: {:error, :migration_not_prewarming}

  @doc """
  Records one final catch-up ACK for a prewarmed slice.

  A final catch-up ACK means the source Scene has drained its latest hot chunk
  state into DataService and the target Scene has loaded that latest persisted
  snapshot for this slice. World requires one ACK per planned slice before
  cutover can publish the new write lease.
  """
  def mark_slice_final_caught_up(%__MODULE__{state: :prewarmed} = plan, attrs, now_ms) do
    with {:ok, ack} <- normalize_slice_final_catchup_ack(plan, attrs),
         {:ok, slice} <- fetch_planned_slice(plan, ack.slice_id) do
      next_slice = Map.merge(slice, %{final_catchup_ack: ack})

      next_plan = %{
        plan
        | planned_slices: replace_slice(plan.planned_slices, next_slice),
          final_catchup_acks: Map.put(plan.final_catchup_acks, ack.slice_id, ack),
          updated_at_ms: now_ms
      }

      {:ok, next_plan, next_slice}
    end
  end

  def mark_slice_final_caught_up(%__MODULE__{}, _attrs, _now_ms),
    do: {:error, :migration_not_prewarmed}

  @doc "Marks the migration as prewarmed after Scene reports readiness."
  def mark_prewarmed(%__MODULE__{state: :prewarming} = plan, now_ms) do
    cond do
      not all_slices_planned?(plan) ->
        {:error, :migration_prewarm_incomplete}

      not all_slices_prewarmed?(plan) ->
        {:error, :migration_prewarm_ack_incomplete}

      true ->
        {:ok, %{plan | state: :prewarmed, prewarmed_at_ms: now_ms, updated_at_ms: now_ms}}
    end
  end

  def mark_prewarmed(%__MODULE__{state: :prewarmed} = plan, _now_ms), do: {:ok, plan}
  def mark_prewarmed(%__MODULE__{}, _now_ms), do: {:error, :migration_not_prewarming}

  @doc """
  Marks the plan as cut over after World has published the new write lease.

  cell_migration(梯队1 step1.6):cutover 写入 `migration_tick`/`commit_watermark`,取 final-catchup-ack
  的 `max_chunk_version` 前沿(所有权切换的版本边界,旧 owner 之后禁写)。
  """
  def cutover(%__MODULE__{state: :prewarmed} = plan, now_ms) do
    if all_slices_final_caught_up?(plan) do
      frontier = commit_frontier(plan)

      {:ok,
       %{
         plan
         | state: :cutover,
           cutover_at_ms: now_ms,
           updated_at_ms: now_ms,
           migration_tick: frontier,
           commit_watermark: frontier
       }}
    else
      {:error, :migration_final_catchup_ack_incomplete}
    end
  end

  def cutover(%__MODULE__{state: :cutover} = plan, _now_ms), do: {:ok, plan}
  def cutover(%__MODULE__{}, _now_ms), do: {:error, :migration_not_prewarmed}

  @doc """
  Builds the `MmoContracts.Envelope.CellMigration` envelope for a cut-over plan
  (cell_migration 正名,FROZEN-5)。

  仅当 `new_owner_epoch > old_owner_epoch`(真实 epoch 抬升)时返回 `{:ok, envelope}`;
  退化迁移(无 old_lease 或 new == old,信封强制 new>old)返回 `{:error, :owner_epoch_not_monotonic}`。
  尚未 cutover(无 migration_tick)返回 `{:error, :migration_not_cutover}`。
  """
  @spec cell_migration_envelope(t()) :: {:ok, CellMigration.t()} | {:error, term()}
  def cell_migration_envelope(%__MODULE__{migration_tick: nil}),
    do: {:error, :migration_not_cutover}

  def cell_migration_envelope(%__MODULE__{} = plan) do
    CellMigration.new(
      cell_id: plan.region_id,
      old_owner_epoch: old_owner_epoch(plan),
      new_owner_epoch: plan.new_lease.owner_epoch,
      migration_tick: plan.migration_tick,
      commit_watermark: plan.commit_watermark,
      snapshot_ref: plan.migration_id
    )
  end

  defp old_owner_epoch(%__MODULE__{old_lease: nil}), do: 0
  defp old_owner_epoch(%__MODULE__{old_lease: old_lease}), do: old_lease.owner_epoch

  # 所有权切换的版本前沿 = final-catchup-ack 的 max max_chunk_version(无 ack 则 0)。
  defp commit_frontier(%__MODULE__{final_catchup_acks: acks}) when map_size(acks) == 0, do: 0

  defp commit_frontier(%__MODULE__{final_catchup_acks: acks}) do
    acks
    |> Map.values()
    |> Enum.map(&Map.get(&1, :max_chunk_version, 0))
    |> Enum.max()
  end

  @doc "Marks a cutover migration as complete."
  def complete(%__MODULE__{state: :cutover} = plan, now_ms) do
    {:ok, %{plan | state: :completed, completed_at_ms: now_ms, updated_at_ms: now_ms}}
  end

  def complete(%__MODULE__{state: :completed} = plan, _now_ms), do: {:ok, plan}
  def complete(%__MODULE__{}, _now_ms), do: {:error, :migration_not_cutover}

  @doc "Returns the handoff payload a Scene adapter can consume without mutating state."
  def handoff(%__MODULE__{} = plan) do
    %{
      migration_id: plan.migration_id,
      logical_scene_id: plan.logical_scene_id,
      region_id: plan.region_id,
      state: plan.state,
      source_scene_instance_ref: plan.source_scene_instance_ref,
      target_scene_instance_ref: plan.target_scene_instance_ref,
      old_lease: plan.old_lease,
      new_lease: plan.new_lease,
      token_version: plan.token_version,
      affected_chunk_bounds: %{
        min: plan.affected_chunk_min,
        max: plan.affected_chunk_max
      },
      planned_slices: plan.planned_slices,
      prewarm_acks: plan.prewarm_acks,
      final_catchup_acks: plan.final_catchup_acks,
      next_slice_index: plan.next_slice_index,
      total_slices: plan.total_slices
    }
  end

  @doc "Returns a small map suitable for CLI observe logs and test snapshots."
  def summary(%__MODULE__{} = plan) do
    %{
      migration_id: plan.migration_id,
      logical_scene_id: plan.logical_scene_id,
      region_id: plan.region_id,
      state: plan.state,
      source_scene_instance_ref: plan.source_scene_instance_ref,
      target_scene_instance_ref: plan.target_scene_instance_ref,
      old_lease: lease_summary(plan.old_lease),
      new_lease: lease_summary(plan.new_lease),
      affected_chunk_bounds: %{
        min: coord_list(plan.affected_chunk_min),
        max: coord_list(plan.affected_chunk_max)
      },
      token_version: plan.token_version,
      slice_axis: plan.slice_axis,
      slice_width: plan.slice_width,
      next_slice_index: plan.next_slice_index,
      total_slices: plan.total_slices,
      migration_tick: plan.migration_tick,
      commit_watermark: plan.commit_watermark,
      planned_slices: Enum.map(plan.planned_slices, &slice_summary/1),
      prewarm_ack_count: map_size(plan.prewarm_acks),
      final_catchup_ack_count: map_size(plan.final_catchup_acks)
    }
  end

  @doc "Returns a compact summary for a planned prewarm slice."
  def slice_summary(slice) when is_map(slice) do
    summary = %{
      slice_id: Map.fetch!(slice, :slice_id),
      index: Map.fetch!(slice, :index),
      state: Map.fetch!(slice, :state),
      bounds_chunk_min: coord_list(Map.fetch!(slice, :bounds_chunk_min)),
      bounds_chunk_max: coord_list(Map.fetch!(slice, :bounds_chunk_max))
    }

    summary
    |> maybe_put_ack(:prewarm_ack, Map.get(slice, :prewarm_ack))
    |> maybe_put_ack(:final_catchup_ack, Map.get(slice, :final_catchup_ack))
  end

  defp build_slice(plan, index) do
    {min_coord, max_coord} =
      slice_bounds(
        plan.affected_chunk_min,
        plan.affected_chunk_max,
        plan.slice_axis,
        plan.slice_width,
        index
      )

    %{
      slice_id: "#{plan.migration_id}:slice:#{index}",
      index: index,
      bounds_chunk_min: min_coord,
      bounds_chunk_max: max_coord,
      state: :planned
    }
  end

  defp slice_bounds({min_x, min_y, min_z}, {max_x, max_y, max_z}, :x, width, index) do
    start_x = min_x + index * width
    end_x = min(start_x + width, max_x)
    {{start_x, min_y, min_z}, {end_x, max_y, max_z}}
  end

  defp slice_bounds({min_x, min_y, min_z}, {max_x, max_y, max_z}, :y, width, index) do
    start_y = min_y + index * width
    end_y = min(start_y + width, max_y)
    {{min_x, start_y, min_z}, {max_x, end_y, max_z}}
  end

  defp slice_bounds({min_x, min_y, min_z}, {max_x, max_y, max_z}, :z, width, index) do
    start_z = min_z + index * width
    end_z = min(start_z + width, max_z)
    {{min_x, min_y, start_z}, {max_x, max_y, end_z}}
  end

  defp total_slices(min_coord, max_coord, axis, width) do
    min_value = axis_value(min_coord, axis)
    max_value = axis_value(max_coord, axis)
    ceil_div(max_value - min_value, width)
  end

  defp all_slices_planned?(plan) do
    plan.next_slice_index >= plan.total_slices and
      length(plan.planned_slices) >= plan.total_slices
  end

  defp all_slices_prewarmed?(plan) do
    length(plan.planned_slices) == plan.total_slices and
      Enum.all?(plan.planned_slices, &(&1.state == :prewarmed))
  end

  defp all_slices_final_caught_up?(plan) do
    length(plan.planned_slices) == plan.total_slices and
      Enum.all?(plan.planned_slices, &Map.has_key?(&1, :final_catchup_ack))
  end

  defp normalize_slice_ack(plan, attrs) when is_map(attrs) do
    slice_id = Map.get(attrs, :slice_id)
    scene_ref = Map.get(attrs, :scene_ref, plan.target_scene_instance_ref)

    cond do
      not is_binary(slice_id) ->
        {:error, :invalid_migration_slice_ack}

      scene_ref != plan.target_scene_instance_ref ->
        {:error, :migration_slice_ack_scene_mismatch}

      true ->
        {:ok,
         %{
           slice_id: slice_id,
           scene_ref: scene_ref,
           loaded_count: non_negative_int(Map.get(attrs, :loaded_count, 0)),
           empty_count: non_negative_int(Map.get(attrs, :empty_count, 0)),
           max_chunk_version: non_negative_int(Map.get(attrs, :max_chunk_version, 0)),
           acked_at_ms: Map.get(attrs, :acked_at_ms)
         }}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_migration_slice_ack}
  end

  defp normalize_slice_ack(_plan, _attrs), do: {:error, :invalid_migration_slice_ack}

  defp normalize_slice_final_catchup_ack(plan, attrs) when is_map(attrs) do
    slice_id = Map.get(attrs, :slice_id)
    scene_ref = Map.get(attrs, :scene_ref, plan.target_scene_instance_ref)

    cond do
      not is_binary(slice_id) ->
        {:error, :invalid_migration_final_catchup_ack}

      scene_ref != plan.target_scene_instance_ref ->
        {:error, :migration_final_catchup_ack_scene_mismatch}

      true ->
        {:ok,
         %{
           slice_id: slice_id,
           scene_ref: scene_ref,
           loaded_count: non_negative_int(Map.get(attrs, :loaded_count, 0)),
           empty_count: non_negative_int(Map.get(attrs, :empty_count, 0)),
           max_chunk_version: non_negative_int(Map.get(attrs, :max_chunk_version, 0)),
           source_persisted_count: non_negative_int(Map.get(attrs, :source_persisted_count, 0)),
           source_missing_count: non_negative_int(Map.get(attrs, :source_missing_count, 0)),
           source_error_count: non_negative_int(Map.get(attrs, :source_error_count, 0)),
           acked_at_ms: Map.get(attrs, :acked_at_ms)
         }}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_migration_final_catchup_ack}
  end

  defp normalize_slice_final_catchup_ack(_plan, _attrs),
    do: {:error, :invalid_migration_final_catchup_ack}

  defp fetch_planned_slice(plan, slice_id) do
    case Enum.find(plan.planned_slices, &(&1.slice_id == slice_id)) do
      nil -> {:error, :unknown_migration_slice}
      slice -> {:ok, slice}
    end
  end

  defp replace_slice(slices, next_slice) do
    Enum.map(slices, fn
      %{slice_id: slice_id} when slice_id == next_slice.slice_id -> next_slice
      slice -> slice
    end)
  end

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: raise(ArgumentError, "expected non-negative integer")

  defp ack_summary(ack) do
    Map.take(ack, [
      :scene_ref,
      :loaded_count,
      :empty_count,
      :max_chunk_version,
      :source_persisted_count,
      :source_missing_count,
      :source_error_count,
      :acked_at_ms
    ])
  end

  defp maybe_put_ack(summary, _key, nil), do: summary
  defp maybe_put_ack(summary, key, ack), do: Map.put(summary, key, ack_summary(ack))

  defp axis_value({x, _y, _z}, :x), do: x
  defp axis_value({_x, y, _z}, :y), do: y
  defp axis_value({_x, _y, z}, :z), do: z

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp lease_summary(nil), do: nil

  defp lease_summary(lease) do
    %{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      bounds_chunk_min: coord_list(lease.bounds_chunk_min),
      bounds_chunk_max: coord_list(lease.bounds_chunk_max)
    }
  end

  defp validate_bounds!({min_x, min_y, min_z}, {max_x, max_y, max_z})
       when min_x < max_x and min_y < max_y and min_z < max_z do
    :ok
  end

  defp validate_bounds!(min_coord, max_coord) do
    raise ArgumentError,
          "expected half-open affected chunk bounds with min < max, got: #{inspect({min_coord, max_coord})}"
  end

  defp validate_slice_axis!(axis) when axis in [:x, :y, :z], do: :ok

  defp validate_slice_axis!(axis) do
    raise ArgumentError, "expected slice axis :x, :y, or :z, got: #{inspect(axis)}"
  end

  defp validate_slice_width!(width) when is_integer(width) and width > 0, do: :ok

  defp validate_slice_width!(width) do
    raise ArgumentError, "expected positive integer slice width, got: #{inspect(width)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp coord_list({x, y, z}), do: [x, y, z]

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  rescue
    KeyError ->
      raise ArgumentError, "missing required #{inspect(key)}"
  end
end
