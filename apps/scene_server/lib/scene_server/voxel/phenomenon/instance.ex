defmodule SceneServer.Voxel.Phenomenon.Instance do
  @moduledoc """
  Authority-owned lifecycle record for a physical phenomenon instance.

  Field kernels decide whether a phenomenon should advance. `ChunkProcess`
  owns these records so lifecycle state stays beside the authoritative voxel
  truth instead of living inside a transient field worker.
  """

  @enforce_keys [:id, :kind, :macro_index, :status, :started_at_ms, :updated_at_ms]
  defstruct [
    :id,
    :kind,
    :macro_index,
    :material_id,
    :status,
    :stage,
    :previous_stage,
    :reason,
    :started_at_ms,
    :updated_at_ms,
    :completed_at_ms,
    :started_chunk_version,
    :updated_chunk_version,
    metadata: %{}
  ]

  @type id :: {term(), non_neg_integer(), {integer(), integer(), integer()}, non_neg_integer()}

  @type t :: %__MODULE__{
          id: id(),
          kind: atom() | String.t(),
          macro_index: non_neg_integer(),
          material_id: non_neg_integer() | nil,
          status: :active | :completed,
          stage: atom() | String.t() | nil,
          previous_stage: atom() | String.t() | nil,
          reason: atom() | String.t() | nil,
          started_at_ms: integer(),
          updated_at_ms: integer(),
          completed_at_ms: integer() | nil,
          started_chunk_version: non_neg_integer() | nil,
          updated_chunk_version: non_neg_integer() | nil,
          metadata: map()
        }

  @doc "Builds the chunk-authority key for one phenomenon instance."
  @spec key(
          non_neg_integer(),
          {integer(), integer(), integer()},
          atom() | String.t(),
          non_neg_integer()
        ) ::
          id()
  def key(logical_scene_id, chunk_coord, kind, macro_index) do
    {kind, logical_scene_id, chunk_coord, macro_index}
  end

  @doc "Creates or refreshes an active instance while preserving first-seen data."
  @spec upsert(t() | nil, map()) :: t()
  def upsert(existing, attrs) when is_map(attrs) do
    now_ms = Map.fetch!(attrs, :now_ms)
    chunk_version = Map.get(attrs, :chunk_version)

    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      kind: Map.fetch!(attrs, :kind),
      macro_index: Map.fetch!(attrs, :macro_index),
      material_id: Map.get(attrs, :material_id) || field(existing, :material_id),
      status: :active,
      stage: Map.get(attrs, :stage) || field(existing, :stage),
      previous_stage: Map.get(attrs, :previous_stage),
      reason: Map.get(attrs, :reason),
      started_at_ms: field(existing, :started_at_ms) || now_ms,
      updated_at_ms: now_ms,
      completed_at_ms: nil,
      started_chunk_version: field(existing, :started_chunk_version) || chunk_version,
      updated_chunk_version: chunk_version,
      metadata: Map.merge(field(existing, :metadata) || %{}, Map.get(attrs, :metadata, %{}))
    }
  end

  @doc "Marks an instance completed for observe/reporting before active cleanup."
  @spec complete(t() | nil, map()) :: t()
  def complete(existing, attrs) when is_map(attrs) do
    now_ms = Map.fetch!(attrs, :now_ms)
    chunk_version = Map.get(attrs, :chunk_version)

    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      kind: Map.fetch!(attrs, :kind),
      macro_index: Map.fetch!(attrs, :macro_index),
      material_id: Map.get(attrs, :material_id) || field(existing, :material_id),
      status: :completed,
      stage: Map.get(attrs, :stage) || field(existing, :stage),
      previous_stage: Map.get(attrs, :previous_stage),
      reason: Map.get(attrs, :reason),
      started_at_ms: field(existing, :started_at_ms) || now_ms,
      updated_at_ms: now_ms,
      completed_at_ms: now_ms,
      started_chunk_version: field(existing, :started_chunk_version) || chunk_version,
      updated_chunk_version: chunk_version,
      metadata: Map.merge(field(existing, :metadata) || %{}, Map.get(attrs, :metadata, %{}))
    }
  end

  @doc "Returns a compact map for debug state and observe payloads."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = instance) do
    %{
      id: inspect(instance.id),
      kind: instance.kind,
      macro_index: instance.macro_index,
      material_id: instance.material_id,
      status: instance.status,
      stage: instance.stage,
      previous_stage: instance.previous_stage,
      reason: instance.reason,
      started_at_ms: instance.started_at_ms,
      updated_at_ms: instance.updated_at_ms,
      completed_at_ms: instance.completed_at_ms,
      started_chunk_version: instance.started_chunk_version,
      updated_chunk_version: instance.updated_chunk_version,
      metadata: json_safe(instance.metadata)
    }
  end

  defp field(nil, _field), do: nil
  defp field(%__MODULE__{} = instance, field), do: Map.get(instance, field)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value
end
