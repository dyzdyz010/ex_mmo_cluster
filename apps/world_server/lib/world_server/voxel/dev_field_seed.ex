defmodule WorldServer.Voxel.DevFieldSeed do
  @moduledoc """
  Dev-only cross-node helper: submits heat actions to the scene-side field
  runtime so voxel attribute anomaly detection and the field debug overlay can
  be smoke-tested.

  ## Why this lives here

  The HTTP entry point (`AuthServerWeb.IngameController`) runs on the **app
  node**, while `SceneServer.Voxel.ChunkDirectory` only registers locally on
  each **scene node**. A `GenServer.call/2` with just the module atom only
  looks up the local node, so a scene-server module invoked directly from the
  controller cannot reach `ChunkDirectory` — it fails with
  `"no process: ... possibly because its application isn't started"`.

  This module mirrors the layering used by `WorldServer.Voxel.DevSeed`:

    * `world_server` is the cross-node coordinator that the controller talks to.
    * It locates the scene node owning the request and uses `:rpc.call/5` so
      the actual `ChunkDirectory` / `ChunkProcess` work happens *on the scene
      node*, where those processes are alive.

  Electric conduction must route by `MapLedger.route_chunk_with_lease/3` before
  dispatch so the created field region lands on the source chunk's current
  scene owner under that owner's active lease.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger

  @rpc_timeout_ms 5_000
  @default_logical_scene_id 1
  @default_scene_module SceneServer.Voxel.Field.DevFieldCreate
  @chunk_size_in_macro 16

  @doc """
  Applies a finite target-temperature heat action at an exact world-macro voxel.

  Legacy alias for `ensure_set_temperature/1` unless `:heat_energy_joules` is
  explicitly supplied for old heat-energy smoke calls.

  Options:
    * `:logical_scene_id` (default 1)
    * `:world_macro`      `{x, y, z}`
    * `:target_temperature_celsius` target voxel temperature (default 800)
    * `:max_ticks`        (default 600 = 60 s at 10 Hz)
    * `:radius`           local FieldRegion radius around the source voxel
  """
  @spec ensure_heat_voxel(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_heat_voxel(opts \\ []) when is_list(opts) do
    with {:ok, target_node} <- locate_target_node(),
         {:ok, summary} <- invoke(target_node, :heat_voxel, opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(target_node))
      emit("voxel_dev_heat_voxel_ready", enriched)
      {:ok, enriched}
    end
  end

  @doc """
  Sets an exact world-macro voxel temperature through the formal Phase 7.D1
  SetTemperature/Cool path.
  """
  @spec ensure_set_temperature(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_set_temperature(opts \\ []) when is_list(opts) do
    with {:ok, target_node} <- locate_target_node(),
         {:ok, summary} <- invoke(target_node, :set_temperature, opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(target_node))
      emit("voxel_set_temperature_ready", enriched)
      {:ok, enriched}
    end
  end

  @doc """
  Creates a chunk-local electric conduction field through the scene node.

  The helper deliberately coordinates only the cross-node dispatch. The scene
  chunk process remains the authority that owns the `FieldRegion` and emits
  field snapshots to subscribed clients.
  """
  @spec ensure_conduction_path(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_conduction_path(opts \\ []) when is_list(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, @default_logical_scene_id)
    source_world_macro = Keyword.get(opts, :source_world_macro, {0, 0, 0})

    with {:ok, route} <- route_source_chunk(logical_scene_id, source_world_macro, opts),
         {:ok, target_node} <- target_node_from_route(route),
         invoke_opts = Keyword.put_new(opts, :lease, route.lease),
         {:ok, summary} <- invoke(target_node, :conduct_path, invoke_opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(target_node))
      emit("voxel_conduction_path_ready", enriched)
      {:ok, enriched}
    end
  end

  @doc """
  Creates or refreshes a target-free automatic circuit field on the chunk that
  contains `:world_macro`.
  """
  @spec ensure_auto_circuit(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_auto_circuit(opts \\ []) when is_list(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, @default_logical_scene_id)
    world_macro = Keyword.get(opts, :world_macro, {0, 0, 0})

    with {:ok, route} <- route_source_chunk(logical_scene_id, world_macro, opts),
         {:ok, target_node} <- target_node_from_route(route),
         invoke_opts = Keyword.put_new(opts, :lease, route.lease),
         {:ok, summary} <- invoke(target_node, :auto_circuit, invoke_opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(target_node))
      emit("voxel_auto_circuit_ready", enriched)
      {:ok, enriched}
    end
  end

  @doc """
  Reads a voxel's combustion truth from the scene node that owns its chunk.

  This is a dev/debug observation path. WorldServer only routes the request;
  the scene-side chunk remains the authority for material and dynamic
  combustion attributes.
  """
  @spec ensure_combustion_probe(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_combustion_probe(opts \\ []) when is_list(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, @default_logical_scene_id)
    world_macro = Keyword.get(opts, :world_macro, {0, 0, 0})

    with {:ok, route} <- route_source_chunk(logical_scene_id, world_macro, opts),
         {:ok, target_node} <- target_node_from_route(route),
         invoke_opts = Keyword.put_new(opts, :lease, route.lease),
         {:ok, summary} <- invoke(target_node, :combustion_probe, invoke_opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(target_node))
      emit("voxel_combustion_probe_ready", enriched)
      {:ok, enriched}
    end
  end

  # Mirrors WorldServer.Voxel.DevSeed.chunk_directory_target/2: in single-node
  # dev (Node.list/0 == []) the scene_server runs in the same BEAM as the
  # controller, so we invoke the scene module locally. In multi-node deploys
  # we look for a node whose name starts with "scene_" (the convention set
  # by deploy/docker-compose.yml) and dispatch via :rpc.call.
  defp locate_target_node do
    case Node.list() do
      [] ->
        {:ok, node()}

      peers ->
        case Enum.find(peers, &scene_node?/1) do
          nil -> {:error, :no_scene_node_available}
          scene_node -> {:ok, scene_node}
        end
    end
  end

  defp scene_node?(node) do
    node |> Atom.to_string() |> String.starts_with?("scene_")
  end

  defp invoke(target_node, function, opts) do
    if target_node == node() do
      invoke_local(function, opts)
    else
      invoke_remote(target_node, function, opts)
    end
  end

  defp invoke_local(function, opts) do
    scene_module = scene_module(opts)

    case Code.ensure_loaded(scene_module) do
      {:module, _} ->
        case apply(scene_module, function, [opts]) do
          {:ok, summary} -> {:ok, summary}
          {:error, _} = err -> err
          other -> {:error, {:unexpected_response, other}}
        end

      _other ->
        {:error, {:scene_module_unavailable, scene_module}}
    end
  rescue
    error -> {:error, {:scene_module_raised, error}}
  catch
    kind, reason -> {:error, {:scene_module_threw, kind, reason}}
  end

  defp invoke_remote(scene_node, function, opts) do
    scene_module = scene_module(opts)

    case :rpc.call(scene_node, scene_module, function, [opts], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, {:rpc_failed, scene_node, reason}}
      {:ok, summary} -> {:ok, summary}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp scene_module(opts), do: Keyword.get(opts, :scene_module, @default_scene_module)

  defp route_source_chunk(logical_scene_id, source_world_macro, opts) do
    ledger = Keyword.get(opts, :ledger, MapLedger)
    chunk_coord = source_world_macro |> world_macro_coord!() |> chunk_coord_for_world_macro()

    case safe_call(fn ->
           MapLedger.route_chunk_with_lease(ledger, logical_scene_id, chunk_coord)
         end) do
      {:ok, {:ok, route}} -> {:ok, route}
      {:ok, {:error, reason}} -> {:error, {:source_chunk_route_unavailable, reason}}
      {:error, reason} -> {:error, {:source_chunk_route_unavailable, reason}}
    end
  end

  defp target_node_from_route(%{assignment: assignment}) do
    case Map.get(assignment, :assigned_scene_node) do
      nil -> {:ok, node()}
      scene_node -> {:ok, scene_node}
    end
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp world_macro_coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp world_macro_coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp world_macro_coord!(%{x: x, y: y, z: z})
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {x, y, z}

  defp world_macro_coord!(%{"x" => x, "y" => y, "z" => z})
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {x, y, z}

  defp world_macro_coord!(_other), do: {0, 0, 0}

  defp chunk_coord_for_world_macro({x, y, z}) do
    {floor_div(x, @chunk_size_in_macro), floor_div(y, @chunk_size_in_macro),
     floor_div(z, @chunk_size_in_macro)}
  end

  defp floor_div(dividend, divisor) do
    quotient = div(dividend, divisor)
    remainder = rem(dividend, divisor)

    if remainder != 0 and remainder < 0 do
      quotient - 1
    else
      quotient
    end
  end

  defp emit(event, summary) do
    CliObserve.emit(event, summary)
  end
end
