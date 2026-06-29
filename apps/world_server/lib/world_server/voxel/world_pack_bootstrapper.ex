defmodule WorldServer.Voxel.WorldPackBootstrapper do
  @moduledoc """
  Supervised deployment-time world-pack generator.

  `WorldPackMaterializer` owns the per-batch write path. This process owns the
  boot-time orchestration around it: normalize a configured chunk range, enforce
  a generation budget, materialize the range in bounded batches, and publish the
  in-memory `:auth_server, :voxel_world_pack` manifest status only after the
  canonical snapshots have been written.

  It is disabled by default. Enabling it is an explicit server deployment step,
  not a Gate subscription fallback and not an HTTP request side effect.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.WorldPackMaterializer

  @default_retry_ms 1_000
  @default_batch_size 64
  @default_max_chunks 10_000
  @default_chunk_min {-3, -3, -3}
  @default_chunk_max {3, 3, 3}
  @default_world_macro_extent 32_768

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc "Starts the optional world-pack generator."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns the current generator state for CLI/tests."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Runs one materialization pass synchronously.

  This is the same implementation used by the supervised worker and by tests.
  It publishes `:materializing`, `:ready`, or `:failed` into
  `:auth_server, :voxel_world_pack` unless `:publish_auth_pack?` is false.
  """
  @spec materialize_once(keyword()) :: {:ok, map()} | {:error, term()}
  def materialize_once(opts) when is_list(opts) do
    case build_plan(opts) do
      {:ok, plan} ->
        publish_pack(plan, :materializing, nil)
        emit_started(plan)

        case run_plan(plan) do
          {:ok, summary} ->
            publish_pack(plan, :ready, summary)
            emit_ready(plan, summary)
            {:ok, summary}

          {:error, reason, summary} ->
            publish_pack(plan, :failed, Map.put(summary, :error, inspect(reason)))
            emit_failed(plan, reason, summary)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def materialize_once(_opts), do: {:error, :invalid_world_pack_bootstrap_options}

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, false)

    state = %{
      enabled?: enabled?,
      opts: opts,
      status: if(enabled?, do: :starting, else: :disabled),
      attempts: 0,
      last_error: nil,
      last_summary: nil
    }

    if enabled? do
      {:ok, state, {:continue, :materialize}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:materialize, state) do
    {:noreply, materialize_state(state)}
  end

  @impl true
  def handle_info(:materialize, state) do
    {:noreply, materialize_state(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.drop(state, [:opts]), state}
  end

  defp materialize_state(%{enabled?: false} = state), do: state

  defp materialize_state(state) do
    attempts = state.attempts + 1

    case materialize_once(state.opts) do
      {:ok, summary} ->
        %{state | status: :ready, attempts: attempts, last_error: nil, last_summary: summary}

      {:error, reason} ->
        if retryable_error?(reason) do
          retry_ms = Keyword.get(state.opts, :retry_ms, @default_retry_ms)
          Process.send_after(self(), :materialize, retry_ms)

          %{
            state
            | status: :retrying,
              attempts: attempts,
              last_error: inspect(reason)
          }
        else
          %{
            state
            | status: :failed,
              attempts: attempts,
              last_error: inspect(reason)
          }
        end
    end
  end

  defp retryable_error?({_chunk_coord, :scene_node_unassigned}), do: true
  defp retryable_error?(:scene_node_unassigned), do: true
  defp retryable_error?({:ledger_unavailable, _reason}), do: true
  defp retryable_error?(_reason), do: false

  defp build_plan(opts) do
    with {:ok, logical_scene_id} <-
           non_negative_integer(Keyword.get(opts, :logical_scene_id, 1), :invalid_logical_scene_id),
         {:ok, chunk_min} <- chunk_coord(Keyword.get(opts, :chunk_min, @default_chunk_min)),
         {:ok, chunk_max} <- chunk_coord(Keyword.get(opts, :chunk_max, @default_chunk_max)),
         :ok <- validate_bounds(chunk_min, chunk_max),
         {:ok, batch_size} <-
           positive_integer(Keyword.get(opts, :batch_size, @default_batch_size), :invalid_batch_size),
         {:ok, max_chunks} <- max_chunks(Keyword.get(opts, :max_chunks, @default_max_chunks)),
         chunk_count <- chunk_count(chunk_min, chunk_max),
         :ok <- validate_chunk_budget(chunk_count, max_chunks) do
      version = to_string(Keyword.get(opts, :version, "worldgen-v1"))
      content_version = to_string(Keyword.get(opts, :content_version, version))
      seed = Keyword.get(opts, :seed, nil)

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_min: chunk_min,
         chunk_max: chunk_max,
         chunk_count: chunk_count,
         batch_size: batch_size,
         max_chunks: max_chunks,
         ledger: Keyword.get(opts, :ledger, MapLedger),
         materializer: Keyword.get(opts, :materializer, materializer(seed)),
         version: version,
         content_version: content_version,
         world_macro_extent:
           Keyword.get(opts, :world_macro_extent, @default_world_macro_extent),
         publish_auth_pack?: Keyword.get(opts, :publish_auth_pack?, true)
       }}
    end
  end

  defp run_plan(plan) do
    initial = %{
      status: :ready,
      logical_scene_id: plan.logical_scene_id,
      chunk_min: Tuple.to_list(plan.chunk_min),
      chunk_max: Tuple.to_list(plan.chunk_max),
      chunk_count: plan.chunk_count,
      batch_size: plan.batch_size,
      batch_count: 0,
      inserted: 0,
      updated: 0,
      unchanged: 0,
      errors: 0,
      chunk_errors: []
    }

    result =
      plan.chunk_min
      |> chunk_stream(plan.chunk_max)
      |> Stream.chunk_every(plan.batch_size)
      |> Enum.reduce_while(initial, fn batch, acc ->
        case materialize_batch(plan, batch) do
          {:ok, batch_summary} ->
            merged = merge_summary(acc, batch_summary)
            emit_batch(plan, batch_summary, merged)
            {:cont, merged}

          {:error, reason, batch_summary} ->
            merged = merge_summary(acc, batch_summary)
            {:halt, {:error, reason, %{merged | status: :failed}}}
        end
      end)

    case result do
      {:error, _reason, _summary} = error -> error
      summary -> {:ok, summary}
    end
  end

  defp materialize_batch(plan, batch) do
    opts = [
      logical_scene_id: plan.logical_scene_id,
      chunk_coords: batch,
      ledger: plan.ledger,
      materializer: plan.materializer
    ]

    case WorldPackMaterializer.materialize_chunks(opts) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, {:world_pack_materialization_failed, summary}} ->
        {:error, {:world_pack_materialization_failed, summary}, summary}

      {:error, reason} ->
        {:error, reason, failed_batch_summary(plan.logical_scene_id, batch, reason)}
    end
  end

  defp materializer(nil), do: {Module.concat([SceneServer, Voxel, WorldGenMaterializer]), :put_snapshot}

  defp materializer(seed) when is_integer(seed) do
    module = Module.concat([SceneServer, Voxel, WorldGenMaterializer])

    fn logical_scene_id, chunk_coord, lease ->
      apply(module, :put_snapshot, [logical_scene_id, chunk_coord, lease, [seed: seed]])
    end
  end

  defp materializer(_seed), do: {Module.concat([SceneServer, Voxel, WorldGenMaterializer]), :put_snapshot}

  defp merge_summary(acc, batch_summary) do
    %{
      acc
      | batch_count: acc.batch_count + 1,
        inserted: acc.inserted + Map.get(batch_summary, :inserted, 0),
        updated: acc.updated + Map.get(batch_summary, :updated, 0),
        unchanged: acc.unchanged + Map.get(batch_summary, :unchanged, 0),
        errors: acc.errors + Map.get(batch_summary, :errors, 0),
        chunk_errors: acc.chunk_errors ++ Map.get(batch_summary, :chunk_errors, [])
    }
  end

  defp failed_batch_summary(logical_scene_id, batch, reason) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_count: length(batch),
      inserted: 0,
      updated: 0,
      unchanged: 0,
      errors: length(batch),
      chunk_errors:
        Enum.map(batch, fn chunk_coord ->
          %{chunk_coord: Tuple.to_list(chunk_coord), error: inspect(reason)}
        end)
    }
  end

  defp chunk_stream({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    min_x..max_x
    |> Stream.flat_map(fn cx ->
      min_y..max_y
      |> Stream.flat_map(fn cy ->
        min_z..max_z
        |> Stream.map(fn cz -> {cx, cy, cz} end)
      end)
    end)
  end

  defp chunk_count({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)
  end

  defp validate_bounds({min_x, min_y, min_z}, {max_x, max_y, max_z})
       when min_x <= max_x and min_y <= max_y and min_z <= max_z,
       do: :ok

  defp validate_bounds(_min, _max), do: {:error, :invalid_chunk_bounds}

  defp validate_chunk_budget(_chunk_count, :infinity), do: :ok

  defp validate_chunk_budget(chunk_count, max_chunks) when chunk_count <= max_chunks, do: :ok

  defp validate_chunk_budget(chunk_count, max_chunks),
    do: {:error, {:world_pack_chunk_count_exceeds_limit, chunk_count, max_chunks}}

  defp max_chunks(:infinity), do: {:ok, :infinity}
  defp max_chunks("infinity"), do: {:ok, :infinity}
  defp max_chunks(value), do: positive_integer(value, :invalid_max_chunks)

  defp positive_integer(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, reason) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, reason}
    end
  end

  defp positive_integer(_value, reason), do: {:error, reason}

  defp non_negative_integer(value, _reason) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp non_negative_integer(value, reason) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, reason}
    end
  end

  defp non_negative_integer(_value, reason), do: {:error, reason}

  defp chunk_coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp chunk_coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp chunk_coord(value) when is_binary(value) do
    parts =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    case parts do
      [x, y, z] ->
        with {cx, ""} <- Integer.parse(x),
             {cy, ""} <- Integer.parse(y),
             {cz, ""} <- Integer.parse(z) do
          {:ok, {cx, cy, cz}}
        else
          _other -> {:error, :invalid_chunk_coord}
        end

      _other ->
        {:error, :invalid_chunk_coord}
    end
  end

  defp chunk_coord(_value), do: {:error, :invalid_chunk_coord}

  defp publish_pack(%{publish_auth_pack?: false}, _status, _summary), do: :ok

  defp publish_pack(plan, status, summary) do
    current = auth_pack_config()

    generated =
      %{
        status: status,
        logical_scene_id: plan.logical_scene_id,
        chunk_min: Tuple.to_list(plan.chunk_min),
        chunk_max: Tuple.to_list(plan.chunk_max),
        chunk_count: plan.chunk_count,
        batch_size: plan.batch_size
      }
      |> maybe_put_summary(summary)

    updated =
      current
      |> Keyword.merge(
        status: status,
        version: plan.version,
        content_version: plan.content_version,
        world_macro_extent: plan.world_macro_extent,
        generated: generated
      )

    Application.put_env(:auth_server, :voxel_world_pack, updated)
    :ok
  end

  defp auth_pack_config do
    case Application.get_env(:auth_server, :voxel_world_pack, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _other -> []
    end
  end

  defp maybe_put_summary(generated, nil), do: generated
  defp maybe_put_summary(generated, summary), do: Map.put(generated, :summary, summary)

  defp emit_started(plan) do
    CliObserve.emit("voxel_world_pack_generation_started", %{
      logical_scene_id: plan.logical_scene_id,
      chunk_min: Tuple.to_list(plan.chunk_min),
      chunk_max: Tuple.to_list(plan.chunk_max),
      chunk_count: plan.chunk_count,
      batch_size: plan.batch_size,
      content_version: plan.content_version
    })
  end

  defp emit_batch(plan, batch_summary, merged) do
    CliObserve.emit("voxel_world_pack_generation_batch", %{
      logical_scene_id: plan.logical_scene_id,
      batch_count: merged.batch_count,
      batch_chunk_count: Map.get(batch_summary, :chunk_count, 0),
      inserted: Map.get(batch_summary, :inserted, 0),
      updated: Map.get(batch_summary, :updated, 0),
      unchanged: Map.get(batch_summary, :unchanged, 0),
      errors: Map.get(batch_summary, :errors, 0)
    })
  end

  defp emit_ready(plan, summary) do
    CliObserve.emit("voxel_world_pack_generation_ready", %{
      logical_scene_id: plan.logical_scene_id,
      chunk_count: summary.chunk_count,
      batch_count: summary.batch_count,
      inserted: summary.inserted,
      updated: summary.updated,
      unchanged: summary.unchanged,
      content_version: plan.content_version
    })
  end

  defp emit_failed(plan, reason, summary) do
    CliObserve.emit("voxel_world_pack_generation_failed", %{
      logical_scene_id: plan.logical_scene_id,
      chunk_count: summary.chunk_count,
      batch_count: summary.batch_count,
      errors: summary.errors,
      reason: inspect(reason)
    })
  end
end
