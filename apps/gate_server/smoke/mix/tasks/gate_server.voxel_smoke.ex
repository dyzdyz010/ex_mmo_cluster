defmodule Mix.Tasks.GateServer.VoxelSmoke do
  @moduledoc """
  只测试：运行旧 voxel 协议 smoke，使用已有账户 token 和该账户拥有的角色。

      mix gate_server.voxel_smoke --username tester --cid 42

  会话 token 从环境变量 MMO_SMOKE_TOKEN 读取。未提供凭证会显式失败；不生成账户或绕过鉴权。

  The task writes Gate/Scene/World observe logs and `server_stdio`-formatted
  snapshots under `.demo/observe/` by default, then prints a compact CLI summary.
  Initial chunk state is expected as `ChunkSnapshot`; later subscribed updates
  may be `ChunkDelta` and are reported with `updated_frame_type`.
  """

  use Mix.Task

  @shortdoc "Runs Gate voxel E2E smoke through CLI/stdio logs"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    region_id: :integer,
    observe_dir: :string,
    gate_observe_log: :string,
    scene_observe_log: :string,
    world_observe_log: :string,
    stdio_log: :string,
    summary_path: :string,
    cid: :integer,
    username: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, o: :observe_dir]

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
        run_smoke(opts)
    end
  end

  defp run_smoke(opts) do
    opts = Keyword.put(opts, :token, System.fetch_env!("MMO_SMOKE_TOKEN"))

    case GateServer.VoxelSmoke.run(opts) do
      {:ok, result} ->
        Mix.shell().info(summary(result))

      {:error, reason} ->
        Mix.raise("gate voxel e2e smoke failed: #{inspect(reason)}")
    end
  end

  defp summary(result) do
    logs = result.logs

    [
      "gate_voxel_e2e_smoke=ok",
      "logical_scene_id=#{result.logical_scene_id}",
      "region_id=#{result.region_id}",
      "cid=#{result.cid}",
      "initial_snapshot_version=#{result.protocol.initial_snapshot_version}",
      "updated_frame_type=#{result.protocol.updated_frame_type}",
      "updated_chunk_version=#{result.protocol.updated_chunk_version}",
      "updated_snapshot_version=#{result.protocol.updated_snapshot_version}",
      "stored_snapshot_version=#{result.protocol.stored_snapshot_version}",
      "unsubscribe_stopped_push=#{result.protocol.unsubscribe_stopped_push?}",
      "gate_observe_log=#{logs.gate_observe_log}",
      "scene_observe_log=#{logs.scene_observe_log}",
      "world_observe_log=#{logs.world_observe_log}",
      "stdio_log=#{logs.stdio_log}",
      "summary_path=#{logs.summary_path}"
    ]
    |> Enum.join(" ")
  end
end
