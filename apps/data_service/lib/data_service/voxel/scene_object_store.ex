defmodule DataService.Voxel.SceneObjectStore do
  # PERS-5:durable_authoritative(prefab/object 资产)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  Stateless persistence wrapper around `voxel_scene_objects` and
  `voxel_scene_object_id_seq`.

  Phase 4 (D1/D2):每个被放置的 `SceneObjectInstance` 落一行,Scene 端
  `SceneServer.Voxel.ObjectRegistry` 启动时用 `list_in_scene/2` LOAD 该
  scene 的所有活跃对象;World coordinator `begin_transaction` 路径用
  `next_object_id/1` 从 Postgres sequence 取下一个 `object_id`。

  与 `DataService.Voxel.ChunkSnapshotStore` 一样是 stateless module,直走
  `DataService.Repo`。`put_object/2` 是**幂等 upsert**:同一 `object_id`
  重复写入会更新行(用于 part_states / covered_chunks / state_flags 等
  状态在对象生命周期中演进)。

  `covered_chunks` 与 `part_states` 都是 `:erlang.term_to_binary/1` 编码:

  * `covered_chunks` ~ `[{cx, cy, cz}, ...]`,只含整数,反序列化用 `[:safe]`
    无 atom 风险。
  * `part_states` ~ `[%{part_id: ..., health: ..., state_flags: ...}, ...]`,
    含 atom 键,反序列化用 `[:safe]` 模式;atom 表会在 SceneServer 启动
    `SceneServer.Voxel.PartState` 时统一注册(Step 4-3)。

  失败语义:任意 Postgrex 异常都包成 `{:error, :object_persist_failed}`,
  方便调用方做兜底。`next_object_id/1` 失败包成
  `{:error, :sequence_unavailable}` —— coordinator 见此立即拒绝
  `begin_transaction`(`:object_id_unavailable`)。
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Repo
  alias DataService.Schema.VoxelSceneObject

  @type chunk_coord :: {integer(), integer(), integer()}

  @type part_state :: %{
          required(:part_id) => non_neg_integer(),
          required(:health) => integer(),
          required(:state_flags) => non_neg_integer()
        }

  @type object :: %{
          required(:object_id) => non_neg_integer(),
          required(:logical_scene_id) => non_neg_integer(),
          required(:parcel_id) => non_neg_integer(),
          required(:blueprint_id) => non_neg_integer(),
          required(:blueprint_version) => non_neg_integer(),
          required(:anchor_world_micro) => {integer(), integer(), integer()},
          required(:rotation) => non_neg_integer(),
          required(:owner_actor_id) => non_neg_integer(),
          required(:state_flags) => non_neg_integer(),
          required(:object_attribute_ref) => non_neg_integer(),
          required(:object_tag_set_ref) => non_neg_integer(),
          required(:covered_chunks) => [chunk_coord()],
          required(:part_states) => [part_state()],
          required(:object_version) => non_neg_integer(),
          # Phase A4-3:owner participant 元数据(D6 字典序选)。
          required(:owner_region_id) => non_neg_integer(),
          required(:owner_lease_id) => non_neg_integer()
        }

  @type put_result :: {:ok, :upserted} | {:error, atom()}
  @type get_result :: {:ok, object()} | {:error, atom()}
  @type delete_result :: {:ok, :deleted | :not_found} | {:error, atom()}
  @type next_id_result :: {:ok, non_neg_integer()} | {:error, atom()}

  @doc """
  Inserts or updates a scene object row (idempotent upsert by `object_id`).

  `attrs` carries the full instance shape (see `t:object/0`). Any Postgrex
  exception surfaces as `{:error, :object_persist_failed}`.

  `opts[:repo]` overrides the default repo (test-only).
  """
  @spec put_object(map(), keyword()) :: put_result()
  def put_object(attrs, opts \\ [])

  def put_object(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, normalized} <- normalize_object(attrs) do
      repo = repo(opts)

      changeset = VoxelSceneObject.changeset(%VoxelSceneObject{}, normalized)

      case repo.insert(changeset,
             on_conflict: {:replace_all_except, [:object_id, :inserted_at]},
             conflict_target: :object_id
           ) do
        {:ok, _row} ->
          {:ok, :upserted}

        {:error, %Ecto.Changeset{}} ->
          {:error, :invalid_object_attrs}
      end
    end
  rescue
    _exception in Postgrex.Error -> {:error, :object_persist_failed}
  end

  def put_object(_attrs, _opts), do: {:error, :invalid_object_attrs}

  @doc """
  Reads the persisted scene object by `object_id`.

  Returns `{:error, :object_not_found}` when no row exists.
  """
  @spec get_object(non_neg_integer(), keyword()) :: get_result()
  def get_object(object_id, opts \\ []) do
    with :ok <- validate_non_neg_integer(object_id, :invalid_object_id) do
      repo = repo(opts)

      case repo.get(VoxelSceneObject, object_id) do
        nil -> {:error, :object_not_found}
        row -> to_object(row)
      end
    end
  end

  @doc """
  Deletes the persisted scene object by `object_id`.

  Idempotent: deleting a missing row returns `{:ok, :not_found}`.
  """
  @spec delete_object(non_neg_integer(), keyword()) :: delete_result()
  def delete_object(object_id, opts \\ []) do
    with :ok <- validate_non_neg_integer(object_id, :invalid_object_id) do
      repo = repo(opts)

      case repo.get(VoxelSceneObject, object_id) do
        nil ->
          {:ok, :not_found}

        row ->
          case repo.delete(row) do
            {:ok, _row} -> {:ok, :deleted}
            {:error, %Ecto.Changeset{}} -> {:error, :object_delete_failed}
          end
      end
    end
  end

  @doc """
  Returns every persisted scene object for a given logical scene.

  Used by `SceneServer.Voxel.ObjectRegistry` on startup to LOAD active
  objects into memory.
  """
  @spec list_in_scene(non_neg_integer(), keyword()) :: [object()]
  def list_in_scene(logical_scene_id, opts \\ []) do
    with :ok <- validate_non_neg_integer(logical_scene_id, :invalid_logical_scene_id) do
      repo = repo(opts)

      query =
        from(o in VoxelSceneObject,
          where: o.logical_scene_id == ^logical_scene_id,
          order_by: [asc: o.object_id]
        )

      repo.all(query)
      |> Enum.flat_map(fn row ->
        case to_object(row) do
          {:ok, obj} -> [obj]
          _ -> []
        end
      end)
    else
      {:error, _reason} -> []
    end
  end

  @doc """
  Returns the next `object_id` from `voxel_scene_object_id_seq`.

  Failure (DB unreachable / sequence missing) surfaces as
  `{:error, :sequence_unavailable}`. Caller (`TransactionCoordinator`)
  then rejects `begin_transaction` with `:object_id_unavailable`.
  """
  @spec next_object_id(keyword()) :: next_id_result()
  def next_object_id(opts \\ []) do
    repo = repo(opts)

    case repo.query("SELECT nextval('voxel_scene_object_id_seq')") do
      {:ok, %{rows: [[id]]}} when is_integer(id) and id >= 0 ->
        {:ok, id}

      _ ->
        {:error, :sequence_unavailable}
    end
  rescue
    _exception in Postgrex.Error -> {:error, :sequence_unavailable}
  end

  @doc """
  Test-only hatch:删除全部对象行 + 重置 sequence 到 1。生产路径不应调用。
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    repo = repo(opts)
    repo.delete_all(VoxelSceneObject)
    repo.query!("ALTER SEQUENCE voxel_scene_object_id_seq RESTART WITH 1")
    :ok
  end

  defp to_object(%VoxelSceneObject{} = row) do
    with {:ok, covered_chunks} <- decode_term(row.covered_chunks),
         :ok <- validate_covered_chunks(covered_chunks),
         {:ok, part_states} <- decode_term(row.part_states),
         :ok <- validate_part_states(part_states) do
      {:ok,
       %{
         object_id: row.object_id,
         logical_scene_id: row.logical_scene_id,
         parcel_id: row.parcel_id,
         blueprint_id: row.blueprint_id,
         blueprint_version: row.blueprint_version,
         anchor_world_micro:
           {row.anchor_world_micro_x, row.anchor_world_micro_y, row.anchor_world_micro_z},
         rotation: row.rotation,
         owner_actor_id: row.owner_actor_id,
         state_flags: row.state_flags,
         object_attribute_ref: row.object_attribute_ref,
         object_tag_set_ref: row.object_tag_set_ref,
         covered_chunks: covered_chunks,
         part_states: part_states,
         object_version: row.object_version,
         owner_region_id: row.owner_region_id,
         owner_lease_id: row.owner_lease_id
       }}
    end
  end

  defp decode_term(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception in [ArgumentError] -> {:error, :invalid_object_payload}
  end

  defp decode_term(_payload), do: {:error, :invalid_object_payload}

  defp validate_covered_chunks(list) when is_list(list) do
    if Enum.all?(list, fn
         {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) -> true
         _ -> false
       end),
       do: :ok,
       else: {:error, :invalid_object_payload}
  end

  defp validate_covered_chunks(_), do: {:error, :invalid_object_payload}

  defp validate_part_states(list) when is_list(list) do
    if Enum.all?(list, &part_state_shape?/1),
      do: :ok,
      else: {:error, :invalid_object_payload}
  end

  defp validate_part_states(_), do: {:error, :invalid_object_payload}

  defp part_state_shape?(%{part_id: pid, health: h, state_flags: f})
       when is_integer(pid) and pid >= 0 and is_integer(h) and is_integer(f) and f >= 0,
       do: true

  defp part_state_shape?(_), do: false

  defp normalize_object(%struct{} = attrs) when is_atom(struct) do
    attrs |> Map.from_struct() |> normalize_object()
  end

  defp normalize_object(attrs) when is_map(attrs) do
    with {:ok, object_id} <- fetch_non_neg_integer(attrs, :object_id),
         {:ok, logical_scene_id} <- fetch_non_neg_integer(attrs, :logical_scene_id),
         {:ok, parcel_id} <- fetch_non_neg_integer(attrs, :parcel_id),
         {:ok, blueprint_id} <- fetch_non_neg_integer(attrs, :blueprint_id),
         {:ok, blueprint_version} <- fetch_non_neg_integer(attrs, :blueprint_version),
         {:ok, {ax, ay, az}} <- fetch_anchor(attrs),
         {:ok, rotation} <- fetch_non_neg_integer(attrs, :rotation),
         {:ok, owner_actor_id} <- fetch_non_neg_integer(attrs, :owner_actor_id),
         {:ok, state_flags} <- fetch_non_neg_integer_default(attrs, :state_flags, 0),
         {:ok, object_attribute_ref} <-
           fetch_non_neg_integer_default(attrs, :object_attribute_ref, 0),
         {:ok, object_tag_set_ref} <-
           fetch_non_neg_integer_default(attrs, :object_tag_set_ref, 0),
         {:ok, covered_chunks} <- fetch_covered_chunks(attrs),
         {:ok, part_states} <- fetch_part_states(attrs),
         {:ok, object_version} <- fetch_non_neg_integer(attrs, :object_version),
         {:ok, owner_region_id} <- fetch_non_neg_integer(attrs, :owner_region_id),
         {:ok, owner_lease_id} <- fetch_non_neg_integer(attrs, :owner_lease_id) do
      {:ok,
       %{
         object_id: object_id,
         logical_scene_id: logical_scene_id,
         parcel_id: parcel_id,
         blueprint_id: blueprint_id,
         blueprint_version: blueprint_version,
         anchor_world_micro_x: ax,
         anchor_world_micro_y: ay,
         anchor_world_micro_z: az,
         rotation: rotation,
         owner_actor_id: owner_actor_id,
         state_flags: state_flags,
         object_attribute_ref: object_attribute_ref,
         object_tag_set_ref: object_tag_set_ref,
         covered_chunks: :erlang.term_to_binary(covered_chunks),
         part_states: :erlang.term_to_binary(part_states),
         object_version: object_version,
         owner_region_id: owner_region_id,
         owner_lease_id: owner_lease_id
       }}
    end
  end

  defp normalize_object(_attrs), do: {:error, :invalid_object_attrs}

  defp fetch_anchor(attrs) do
    case fetch_required(attrs, :anchor_world_micro) do
      {:ok, {x, y, z}} when is_integer(x) and is_integer(y) and is_integer(z) ->
        {:ok, {x, y, z}}

      {:ok, [x, y, z]} when is_integer(x) and is_integer(y) and is_integer(z) ->
        {:ok, {x, y, z}}

      {:ok, _other} ->
        {:error, :invalid_anchor_world_micro}

      error ->
        error
    end
  end

  defp fetch_covered_chunks(attrs) do
    case fetch_required(attrs, :covered_chunks) do
      {:ok, list} when is_list(list) and list != [] ->
        if Enum.all?(list, fn
             {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) -> true
             _ -> false
           end) do
          {:ok, list}
        else
          {:error, :invalid_covered_chunks}
        end

      {:ok, _other} ->
        {:error, :invalid_covered_chunks}

      error ->
        error
    end
  end

  defp fetch_part_states(attrs) do
    case fetch_required(attrs, :part_states) do
      {:ok, list} when is_list(list) and list != [] ->
        if Enum.all?(list, &part_state_shape?/1) do
          {:ok, list}
        else
          {:error, :invalid_part_states}
        end

      {:ok, _other} ->
        {:error, :invalid_part_states}

      error ->
        error
    end
  end

  defp fetch_non_neg_integer(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key),
         :ok <- validate_non_neg_integer(value, invalid_reason(key)) do
      {:ok, value}
    end
  end

  defp fetch_non_neg_integer_default(attrs, key, default) do
    case fetch_required(attrs, key) do
      {:ok, value} ->
        case validate_non_neg_integer(value, invalid_reason(key)) do
          :ok -> {:ok, value}
          error -> error
        end

      {:error, _missing} ->
        {:ok, default}
    end
  end

  defp fetch_required(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> {:error, missing_reason(key)}
    end
  end

  defp validate_non_neg_integer(value, _reason) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_neg_integer(_value, reason), do: {:error, reason}

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp missing_reason(:object_id), do: :missing_object_id
  defp missing_reason(:logical_scene_id), do: :missing_logical_scene_id
  defp missing_reason(:parcel_id), do: :missing_parcel_id
  defp missing_reason(:blueprint_id), do: :missing_blueprint_id
  defp missing_reason(:blueprint_version), do: :missing_blueprint_version
  defp missing_reason(:anchor_world_micro), do: :missing_anchor_world_micro
  defp missing_reason(:rotation), do: :missing_rotation
  defp missing_reason(:owner_actor_id), do: :missing_owner_actor_id
  defp missing_reason(:state_flags), do: :missing_state_flags
  defp missing_reason(:object_attribute_ref), do: :missing_object_attribute_ref
  defp missing_reason(:object_tag_set_ref), do: :missing_object_tag_set_ref
  defp missing_reason(:covered_chunks), do: :missing_covered_chunks
  defp missing_reason(:part_states), do: :missing_part_states
  defp missing_reason(:object_version), do: :missing_object_version
  defp missing_reason(:owner_region_id), do: :missing_owner_region_id
  defp missing_reason(:owner_lease_id), do: :missing_owner_lease_id

  defp invalid_reason(:object_id), do: :invalid_object_id
  defp invalid_reason(:logical_scene_id), do: :invalid_logical_scene_id
  defp invalid_reason(:parcel_id), do: :invalid_parcel_id
  defp invalid_reason(:blueprint_id), do: :invalid_blueprint_id
  defp invalid_reason(:blueprint_version), do: :invalid_blueprint_version
  defp invalid_reason(:anchor_world_micro), do: :invalid_anchor_world_micro
  defp invalid_reason(:rotation), do: :invalid_rotation
  defp invalid_reason(:owner_actor_id), do: :invalid_owner_actor_id
  defp invalid_reason(:state_flags), do: :invalid_state_flags
  defp invalid_reason(:object_attribute_ref), do: :invalid_object_attribute_ref
  defp invalid_reason(:object_tag_set_ref), do: :invalid_object_tag_set_ref
  defp invalid_reason(:covered_chunks), do: :invalid_covered_chunks
  defp invalid_reason(:part_states), do: :invalid_part_states
  defp invalid_reason(:object_version), do: :invalid_object_version
  defp invalid_reason(:owner_region_id), do: :invalid_owner_region_id
  defp invalid_reason(:owner_lease_id), do: :invalid_owner_lease_id
end
