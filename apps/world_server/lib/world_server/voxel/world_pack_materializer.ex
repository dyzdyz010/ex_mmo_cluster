defmodule WorldServer.Voxel.WorldPackMaterializer do
  @moduledoc """
  Deployment-time WorldGen world-pack materialization.

  This module is the production-named entry point for a new server bootstrap:
  route the target chunk range through `MapLedger`, obtain the normal World
  lease fence for each chunk, and ask Scene's WorldGen materializer to write
  canonical chunk snapshots and derived LOD rows. It is not called from Scene
  runtime, Gate subscription, or client repair paths.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc """
  Materializes selected chunks into the canonical store.

  Required options:

    * `:logical_scene_id`
    * `:chunk_coords`

  Optional options:

    * `:ledger` - defaults to `MapLedger`
    * `:materializer` - defaults to
      `{SceneServer.Voxel.WorldGenMaterializer, :put_snapshot}`
    * `:materializer_opts` - forwarded only to materializers that expose an
      arity-four call shape `(logical_scene_id, chunk_coord, lease, opts)`.
      Supplying options to an arity-three materializer fails visibly.

  Full-world deployment tooling should call this in bounded batches and publish
  a world-pack `content_version` only after every planned chunk and LOD
  projection row has been materialized and verified.
  """
  @spec materialize_chunks(keyword()) :: {:ok, map()} | {:error, term()}
  def materialize_chunks(opts) when is_list(opts) do
    with {:ok, logical_scene_id} <- fetch_required_option(opts, :logical_scene_id),
         {:ok, raw_chunk_coords} <- fetch_required_option(opts, :chunk_coords),
         ledger <- Keyword.get(opts, :ledger, MapLedger),
         materializer <- Keyword.get(opts, :materializer, default_materializer()),
         {:ok, materializer_opts} <- materializer_opts(opts),
         :ok <- validate_logical_scene_id(logical_scene_id),
         :ok <- validate_chunk_coords(raw_chunk_coords),
         chunk_coords <- Enum.uniq(raw_chunk_coords),
         {:ok, routes} <- route_chunks(ledger, logical_scene_id, chunk_coords) do
      summary =
        routes
        |> Enum.sort_by(fn {chunk_coord, _route} -> chunk_coord end)
        |> Enum.map(fn {chunk_coord, %{lease: lease}} ->
          {chunk_coord,
           call_materializer(
             materializer,
             logical_scene_id,
             chunk_coord,
             lease,
             materializer_opts
           )}
        end)
        |> summarize(logical_scene_id)

      emit_summary(summary)

      if summary.errors == 0 do
        {:ok, summary}
      else
        {:error, {:world_pack_materialization_failed, summary}}
      end
    end
  end

  def materialize_chunks(_opts), do: {:error, :invalid_materialization_options}

  defp fetch_required_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_option, key}}
    end
  end

  @doc """
  Builds an inclusive chunk coordinate range.
  """
  @spec chunk_range(chunk_coord(), chunk_coord()) :: [chunk_coord()]
  def chunk_range({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    for cx <- min_x..max_x, cy <- min_y..max_y, cz <- min_z..max_z do
      {cx, cy, cz}
    end
  end

  defp default_materializer do
    {Module.concat([SceneServer, Voxel, WorldGenMaterializer]), :put_snapshot}
  end

  defp materializer_opts(opts) do
    case Keyword.get(opts, :materializer_opts, []) do
      materializer_opts when is_list(materializer_opts) -> {:ok, materializer_opts}
      _other -> {:error, :invalid_materializer_opts}
    end
  end

  defp route_chunks(ledger, logical_scene_id, chunk_coords) do
    case MapLedger.route_chunks_with_leases_ensuring(ledger, logical_scene_id, chunk_coords) do
      {:ok, routes} when is_map(routes) -> {:ok, routes}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_ledger_result, other}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp call_materializer(fun, logical_scene_id, chunk_coord, lease, [])
       when is_function(fun, 3) do
    fun.(logical_scene_id, chunk_coord, lease)
  rescue
    exception -> {:error, {:materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:materializer_exit, reason}}
    kind, reason -> {:error, {:materializer_catch, kind, reason}}
  end

  defp call_materializer(fun, _logical_scene_id, _chunk_coord, _lease, materializer_opts)
       when is_function(fun, 3) and materializer_opts != [] do
    {:error, {:materializer_options_not_supported, 3}}
  end

  defp call_materializer(fun, logical_scene_id, chunk_coord, lease, materializer_opts)
       when is_function(fun, 4) do
    fun.(logical_scene_id, chunk_coord, lease, materializer_opts)
  rescue
    exception -> {:error, {:materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:materializer_exit, reason}}
    kind, reason -> {:error, {:materializer_catch, kind, reason}}
  end

  defp call_materializer(
         {module, function},
         logical_scene_id,
         chunk_coord,
         lease,
         materializer_opts
       )
       when is_atom(module) and is_atom(function) do
    if materializer_opts == [] do
      apply(module, function, [logical_scene_id, chunk_coord, lease])
    else
      apply_materializer_with_opts(
        module,
        function,
        logical_scene_id,
        chunk_coord,
        lease,
        materializer_opts
      )
    end
  rescue
    exception -> {:error, {:materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:materializer_exit, reason}}
    kind, reason -> {:error, {:materializer_catch, kind, reason}}
  end

  defp call_materializer(_other, _logical_scene_id, _chunk_coord, _lease, _materializer_opts) do
    {:error, :invalid_materializer}
  end

  defp apply_materializer_with_opts(
         module,
         function,
         logical_scene_id,
         chunk_coord,
         lease,
         materializer_opts
       ) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, 4) do
      apply(module, function, [logical_scene_id, chunk_coord, lease, materializer_opts])
    else
      false -> {:error, {:materializer_options_not_supported, 3}}
      _other -> {:error, :invalid_materializer}
    end
  end

  defp summarize(results, logical_scene_id) do
    base = %{
      logical_scene_id: logical_scene_id,
      chunk_count: length(results),
      inserted: 0,
      updated: 0,
      unchanged: 0,
      errors: 0,
      chunk_errors: []
    }

    Enum.reduce(results, base, fn
      {_chunk_coord, {:ok, :inserted}}, acc ->
        %{acc | inserted: acc.inserted + 1}

      {_chunk_coord, {:ok, :updated}}, acc ->
        %{acc | updated: acc.updated + 1}

      {_chunk_coord, {:ok, :unchanged}}, acc ->
        %{acc | unchanged: acc.unchanged + 1}

      {chunk_coord, {:error, reason}}, acc ->
        %{
          acc
          | errors: acc.errors + 1,
            chunk_errors: [
              %{chunk_coord: Tuple.to_list(chunk_coord), error: inspect(reason)}
              | acc.chunk_errors
            ]
        }

      {chunk_coord, other}, acc ->
        %{
          acc
          | errors: acc.errors + 1,
            chunk_errors: [
              %{
                chunk_coord: Tuple.to_list(chunk_coord),
                error: inspect({:unexpected_result, other})
              }
              | acc.chunk_errors
            ]
        }
    end)
    |> Map.update!(:chunk_errors, &Enum.reverse/1)
  end

  defp emit_summary(summary) do
    CliObserve.emit("voxel_world_pack_materialization", %{
      logical_scene_id: summary.logical_scene_id,
      chunk_count: summary.chunk_count,
      inserted: summary.inserted,
      updated: summary.updated,
      unchanged: summary.unchanged,
      errors: summary.errors
    })
  end

  defp validate_logical_scene_id(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_logical_scene_id(_value), do: {:error, :invalid_logical_scene_id}

  defp validate_chunk_coords([]), do: {:error, :empty_chunk_coords}

  defp validate_chunk_coords(chunk_coords) when not is_list(chunk_coords),
    do: {:error, :invalid_chunk_coords}

  defp validate_chunk_coords(chunk_coords) do
    if Enum.all?(chunk_coords, &valid_chunk_coord?/1) do
      :ok
    else
      {:error, :invalid_chunk_coords}
    end
  end

  defp valid_chunk_coord?({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: true

  defp valid_chunk_coord?(_other), do: false
end
