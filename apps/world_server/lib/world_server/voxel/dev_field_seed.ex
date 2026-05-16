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

  Scene-node discovery uses the `scene_*` naming convention set by the
  scene container's release entrypoint (see `deploy/docker-compose.yml`).
  This deliberately avoids requiring a `MapLedger` route to exist, because
  heat field creation starts from a scene-side voxel attribute write and is
  independent of the lease/region machinery used by normal voxel edits.
  """

  alias WorldServer.CliObserve

  @rpc_timeout_ms 5_000
  @scene_module SceneServer.Voxel.Field.DevFieldCreate

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
    case Code.ensure_loaded(@scene_module) do
      {:module, _} ->
        case apply(@scene_module, function, [opts]) do
          {:ok, summary} -> {:ok, summary}
          {:error, _} = err -> err
          other -> {:error, {:unexpected_response, other}}
        end

      _other ->
        {:error, {:scene_module_unavailable, @scene_module}}
    end
  rescue
    error -> {:error, {:scene_module_raised, error}}
  catch
    kind, reason -> {:error, {:scene_module_threw, kind, reason}}
  end

  defp invoke_remote(scene_node, function, opts) do
    case :rpc.call(scene_node, @scene_module, function, [opts], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, {:rpc_failed, scene_node, reason}}
      {:ok, summary} -> {:ok, summary}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp emit(event, summary) do
    CliObserve.emit(event, summary)
  end
end
