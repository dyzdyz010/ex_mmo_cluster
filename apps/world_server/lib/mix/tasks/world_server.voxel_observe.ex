defmodule Mix.Tasks.WorldServer.VoxelObserve do
  @moduledoc """
  Runs the world-side server-authoritative voxel observe acceptance scenario.

      mix world_server.voxel_observe --logical-scene-id 1

  The task writes structured observe logs to
  `.demo/observe/world-voxel-authority-<logical_scene_id>.log` by default. Use
  `--observe-dir` or `--observe-log` to choose another destination.
  """

  use Mix.Task

  alias WorldServer.Voxel.AuthorityObserve

  @shortdoc "Runs world voxel authority CLI observe acceptance"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, o: :observe_dir, l: :observe_log]

  @doc false
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        run_acceptance(opts)
    end
  end

  defp run_acceptance(opts) do
    case AuthorityObserve.run(opts) do
      {:ok, result} ->
        Mix.shell().info(summary(result))

      {:error, reason} ->
        Mix.raise("world voxel observe acceptance failed: #{inspect(reason)}")
    end
  end

  defp summary(result) do
    [
      "world_voxel_authority_e2e=ok",
      "logical_scene_id=#{result.logical_scene_id}",
      "region_id=#{result.region_id}",
      "chunk=#{Enum.join(result.chunk_coord, ",")}",
      "lease_before=#{result.leases.before_migration.lease_id}",
      "lease_after=#{result.leases.after_migration.lease_id}",
      "route_before_owner=#{result.routes.before_migration.owner_scene_instance_ref}",
      "route_before_scene_node=#{inspect(result.routes.before_migration.assigned_scene_node)}",
      "route_after_owner=#{result.routes.after_migration.owner_scene_instance_ref}",
      "route_after_scene_node=#{inspect(result.routes.after_migration.assigned_scene_node)}",
      "stale_world_status=#{status(result.validations.stale_after_migration.world)}",
      "stale_data_service_status=#{status(result.validations.stale_after_migration.data_service)}",
      "observe_log=#{result.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp status(:ok), do: "ok"
  defp status({:error, reason}), do: "error:#{reason}"
  defp status(other), do: inspect(other)
end
