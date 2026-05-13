defmodule WorldServer.Voxel.DevFieldSeed do
  @moduledoc """
  Dev-only cross-node helper: creates a temperature FieldRegion on a chunk so
  the field debug overlay can be smoke-tested.

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
  field creation is independent of the lease/region machinery used by voxel
  edits.
  """

  alias WorldServer.CliObserve

  @rpc_timeout_ms 5_000
  @scene_module SceneServer.Voxel.Field.DevFieldCreate

  @doc """
  Creates a temperature FieldRegion on the requested chunk.

  Options (all optional):
    * `:logical_scene_id` (default 1)
    * `:chunk_coord`      `{cx, cy, cz}` (default `{0, 0, 0}`)
    * `:max_ticks`        (default 600 = 60 s at 10 Hz)
    * `:source_value`     heat-source temperature in °C (default 100.0)
  """
  @spec ensure_default_field(keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_default_field(opts \\ []) when is_list(opts) do
    with {:ok, scene_node} <- locate_scene_node(),
         {:ok, summary} <- invoke_remote(scene_node, opts) do
      enriched = Map.put(summary, :scene_node, Atom.to_string(scene_node))
      emit(enriched)
      {:ok, enriched}
    end
  end

  defp locate_scene_node do
    case Enum.find(Node.list(), &scene_node?/1) do
      nil -> {:error, :no_scene_node_available}
      scene_node -> {:ok, scene_node}
    end
  end

  defp scene_node?(node) do
    node |> Atom.to_string() |> String.starts_with?("scene_")
  end

  defp invoke_remote(scene_node, opts) do
    case :rpc.call(scene_node, @scene_module, :create_dev_region, [opts], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, {:rpc_failed, scene_node, reason}}
      {:ok, summary} -> {:ok, summary}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp emit(summary) do
    CliObserve.emit("voxel_dev_field_create_ready", summary)
  end
end
