defmodule VoxiaServerStdioCli do
  @moduledoc """
  Stdio/RPC debug CLI for a running ex_mmo_cluster dev node.

  This script does not start a second server. It connects to the live BEAM node
  and reads Gate/Scene/DataService state through RPC while accepting commands on
  stdin. On Windows, start it with the same EPMD port as the server, for example:

      $env:ERL_EPMD_PORT="43690"
      elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs

  One-shot mode:

      elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "connections; chunk 1 -12 8 -10"

  旧 `lod_status` / `lod_sample` / `lod_rebuild` XZ 命令只返回
  `unsupported_legacy_contract`，不会再对在线节点读取或写入 projection。
  """

  @commands [
    "help",
    "connect",
    "snapshot",
    "connections",
    "voxel",
    "chunk <scene_id> <cx> <cy> <cz>",
    "observe [dir]",
    "logs [gate|scene|world] [pattern] [n]",
    "flush",
    "quit"
  ]

  def main(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv,
        switches: [node: :string, cmd: :string],
        aliases: [n: :node, c: :cmd]
      )

    node = node_from(opts)
    connected? = Node.connect(node)

    emit("ready", %{
      node: node,
      connected?: connected?,
      epmd_port: System.get_env("ERL_EPMD_PORT"),
      commands: @commands
    })

    case Keyword.get(opts, :cmd) do
      nil ->
        IO.stream(:stdio, :line)
        |> Enum.each(fn line ->
          case handle(node, String.trim(line)) do
            :quit -> System.halt(0)
            _ -> :ok
          end
        end)

      command_string ->
        command_string
        |> String.split(";", trim: true)
        |> Enum.each(fn command -> handle(node, String.trim(command)) end)
    end
  end

  defp node_from(opts) do
    value =
      Keyword.get(opts, :node) ||
        System.get_env("VOXIA_SERVER_NODE") ||
        "dev@#{hostname()}"

    String.to_atom(value)
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "localhost"
    end
  end

  defp handle(_node, ""), do: :ok

  defp handle(_node, "help") do
    emit("help", %{commands: @commands})
  end

  defp handle(node, "connect") do
    emit("connect", %{node: node, connected?: Node.connect(node)})
  end

  defp handle(node, "snapshot") do
    emit("snapshot", %{
      node: node,
      connected?: Node.connect(node),
      gate: app_env(node, :gate_server, :cli_observe_log),
      scene: app_env(node, :scene_server, :cli_observe_log),
      world: app_env(node, :world_server, :cli_observe_log),
      connections: connection_summaries(node, :summary)
    })
  end

  defp handle(node, "connections") do
    emit("connections", %{connections: connection_summaries(node, :summary)})
  end

  defp handle(node, "voxel") do
    emit("voxel", safe_rpc(node, GateServer.StdioInterface, :voxel_snapshot, []))
  end

  defp handle(node, "flush") do
    gate = safe_rpc(node, GateServer.CliObserve, :flush, [])
    scene = safe_rpc(node, SceneServer.CliObserve, :flush, [])
    world = safe_rpc(node, WorldServer.CliObserve, :flush, [])
    emit("flush", %{gate: gate, scene: scene, world: world})
  end

  defp handle(node, "observe" <> rest) do
    dir =
      case String.trim(rest) do
        "" -> Path.expand(".demo/observe", File.cwd!())
        value -> Path.expand(value, File.cwd!())
      end

    File.mkdir_p!(dir)
    gate_path = Path.join(dir, "voxia-server-gate.observe.log")
    scene_path = Path.join(dir, "voxia-server-scene.observe.log")
    world_path = Path.join(dir, "voxia-server-world.observe.log")

    gate =
      safe_rpc(node, Application, :put_env, [
        :gate_server,
        :cli_observe_log,
        normalize_path(gate_path)
      ])

    scene =
      safe_rpc(node, Application, :put_env, [
        :scene_server,
        :cli_observe_log,
        normalize_path(scene_path)
      ])

    world =
      safe_rpc(node, Application, :put_env, [
        :world_server,
        :cli_observe_log,
        normalize_path(world_path)
      ])

    emit("observe", %{
      gate: gate_path,
      scene: scene_path,
      world: world_path,
      gate_result: gate,
      scene_result: scene,
      world_result: world
    })
  end

  defp handle(node, "logs" <> rest) do
    args = split_args(rest)
    {path, pattern, count} = log_args(node, args)

    emit("logs", %{
      path: path,
      pattern: pattern,
      count: count,
      exists?: is_binary(path) and File.exists?(path),
      lines: tail_lines(path, pattern, count)
    })
  end

  defp handle(node, "chunk " <> rest) do
    case split_args(rest) do
      [scene, cx, cy, cz] ->
        with {:ok, logical_scene_id} <- parse_int(scene),
             {:ok, x} <- parse_int(cx),
             {:ok, y} <- parse_int(cy),
             {:ok, z} <- parse_int(cz) do
          emit("chunk", chunk_probe(node, logical_scene_id, {x, y, z}))
        else
          _ -> emit("error", %{reason: "invalid chunk arguments", command: "chunk #{rest}"})
        end

      _ ->
        emit("error", %{reason: "usage: chunk <scene_id> <cx> <cy> <cz>"})
    end
  end

  defp handle(_node, "lod_status" <> _rest), do: reject_legacy_xz_command("lod_status")
  defp handle(_node, "lod_sample" <> _rest), do: reject_legacy_xz_command("lod_sample")
  defp handle(_node, "lod_rebuild" <> _rest), do: reject_legacy_xz_command("lod_rebuild")

  defp handle(_node, "quit") do
    emit("quit", %{})
    :quit
  end

  defp handle(_node, other) do
    emit("error", %{reason: "unknown command", command: other, commands: @commands})
  end

  defp reject_legacy_xz_command(command) do
    emit("error", %{
      command: command,
      reason: "unsupported_legacy_contract",
      replacement: "scripts/legacy/ requires explicit --allow-legacy-xz offline mode"
    })
  end

  defp chunk_probe(node, logical_scene_id, coord) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: coord,
      gate_subscribers: gate_subscribers_for(node, logical_scene_id, coord),
      world_route: world_route(node, logical_scene_id, coord),
      scene_chunk: scene_chunk(node, logical_scene_id, coord),
      data_snapshot: data_snapshot(node, logical_scene_id, coord)
    }
  end

  defp gate_subscribers_for(node, logical_scene_id, coord) do
    connection_summaries(node, :full)
    |> Enum.flat_map(fn conn ->
      Enum.filter(conn.subscriptions, fn sub ->
        sub.logical_scene_id == logical_scene_id and sub.chunk_coord == coord
      end)
      |> Enum.map(fn sub ->
        Map.merge(sub, %{
          connection_pid: conn.pid,
          transport: conn.transport,
          cid: conn.cid,
          worker_pid: conn.worker.pid,
          worker_pending: conn.worker.pending_reconcile,
          worker_job: conn.worker.reconcile_job
        })
      end)
    end)
  end

  defp world_route(node, logical_scene_id, coord) do
    case safe_rpc(node, WorldServer.Voxel.MapLedger, :route_chunk_with_lease, [
           WorldServer.Voxel.MapLedger,
           logical_scene_id,
           coord
         ]) do
      {:ok, %{assignment: assignment, lease: lease}} ->
        %{
          status: :ok,
          region_id: Map.get(assignment, :region_id),
          bounds_chunk_min: Map.get(assignment, :bounds_chunk_min),
          bounds_chunk_max: Map.get(assignment, :bounds_chunk_max),
          scene_node: Map.get(assignment, :assigned_scene_node),
          lease_id: Map.get(lease, :lease_id),
          owner_scene_instance_ref: Map.get(lease, :owner_scene_instance_ref),
          owner_epoch: Map.get(lease, :owner_epoch),
          expires_at_ms: Map.get(lease, :expires_at_ms)
        }

      other ->
        other
    end
  end

  defp scene_chunk(node, logical_scene_id, coord) do
    case safe_rpc(node, SceneServer.Voxel.ChunkDirectory, :lookup_chunk_pid, [
           SceneServer.Voxel.ChunkDirectory,
           logical_scene_id,
           coord
         ]) do
      {:ok, pid} when is_pid(pid) ->
        case safe_rpc(node, SceneServer.Voxel.ChunkProcess, :debug_state, [pid]) do
          %{} = state ->
            storage = Map.get(state, :storage)

            %{
              status: :hot,
              pid: inspect(pid),
              chunk_version: Map.get(state, :chunk_version),
              has_lease?: Map.get(state, :has_lease?),
              lease: summarize_lease(Map.get(state, :lease)),
              subscriber_count: Map.get(state, :subscriber_count),
              subscribers: Enum.map(Map.get(state, :subscribers, []), &inspect/1),
              macro_headers: count_list(storage, :macro_headers),
              normal_blocks: count_list(storage, :normal_blocks),
              refined_cells: count_list(storage, :refined_cells)
            }

          other ->
            %{status: :debug_failed, result: other}
        end

      :not_started ->
        %{status: :not_started}

      other ->
        %{status: :lookup_failed, result: other}
    end
  end

  defp data_snapshot(node, logical_scene_id, coord) do
    case safe_rpc(node, DataService.Voxel.ChunkSnapshotStore, :get_snapshot, [
           logical_scene_id,
           coord
         ]) do
      {:ok, snapshot} ->
        %{
          status: :ok,
          chunk_version: Map.get(snapshot, :chunk_version),
          lease_id: Map.get(snapshot, :lease_id),
          owner_scene_instance_ref: Map.get(snapshot, :owner_scene_instance_ref),
          owner_epoch: Map.get(snapshot, :owner_epoch),
          bytes: snapshot |> Map.get(:data) |> byte_size_or_zero()
        }

      other ->
        other
    end
  end

  defp connection_summaries(node, mode) do
    tcp =
      case safe_rpc(node, DynamicSupervisor, :which_children, [GateServer.TcpConnectionSup]) do
        list when is_list(list) -> Enum.map(list, fn {_id, pid, _type, _mods} -> {:tcp, pid} end)
        _ -> []
      end

    ws =
      case safe_rpc(node, :pg, :get_members, [:connection, {:gate, GateServer.WsConnection}]) do
        list when is_list(list) -> Enum.map(list, fn pid -> {:ws, pid} end)
        _ -> []
      end

    (tcp ++ ws)
    |> Enum.map(fn {transport, pid} -> connection_summary(node, transport, pid, mode) end)
    |> Enum.reject(&is_nil/1)
  end

  defp connection_summary(node, transport, pid, mode) do
    case safe_rpc(node, :sys, :get_state, [pid, 5_000]) do
      %{} = state ->
        worker = worker_summary(node, Map.get(state, :voxel_worker))
        subscriptions = subscriptions_for_mode(worker.subscriptions, mode)

        %{
          transport: transport,
          pid: inspect(pid),
          status: Map.get(state, :status),
          cid: Map.get(state, :cid),
          auth_username: Map.get(state, :auth_username),
          scene_ref: inspect(Map.get(state, :scene_ref)),
          worker: worker,
          subscription_count: worker.subscription_count,
          subscriptions_truncated?:
            mode != :full and worker.subscription_count > length(subscriptions),
          subscriptions: subscriptions
        }

      _other ->
        nil
    end
  end

  defp worker_summary(node, pid) when is_pid(pid) do
    case safe_rpc(node, :sys, :get_state, [pid, 5_000]) do
      %{} = state ->
        %{
          pid: inspect(pid),
          reconcile_scheduled?: Map.get(state, :reconcile_scheduled?),
          pending_reconcile: summarize_ctx(Map.get(state, :pending_reconcile)),
          reconcile_job: summarize_job(Map.get(state, :reconcile_job)),
          route_cache_size: route_cache_size(Map.get(state, :route_cache)),
          subscriptions: summarize_subscriptions(Map.get(state, :subscriptions, %{})),
          subscription_count: state |> Map.get(:subscriptions, %{}) |> map_size_safe()
        }

      other ->
        %{
          pid: inspect(pid),
          error: other,
          subscriptions: [],
          subscription_count: 0,
          pending_reconcile: nil,
          reconcile_job: nil
        }
    end
  end

  defp worker_summary(_node, _pid),
    do: %{
      pid: nil,
      subscriptions: [],
      subscription_count: 0,
      pending_reconcile: nil,
      reconcile_job: nil
    }

  defp subscriptions_for_mode(subscriptions, :full), do: subscriptions
  defp subscriptions_for_mode(subscriptions, _mode), do: Enum.take(subscriptions, 16)

  defp summarize_subscriptions(subscriptions) when is_map(subscriptions) do
    subscriptions
    |> Map.values()
    |> Enum.map(fn sub ->
      %{
        logical_scene_id: Map.get(sub, :logical_scene_id),
        chunk_coord: Map.get(sub, :chunk_coord),
        request_id: Map.get(sub, :request_id),
        region_id: Map.get(sub, :region_id),
        lease_id: Map.get(sub, :lease_id),
        owner_scene_instance_ref: Map.get(sub, :owner_scene_instance_ref),
        owner_epoch: Map.get(sub, :owner_epoch),
        scene_node: Map.get(sub, :scene_node)
      }
    end)
    |> Enum.sort_by(fn sub -> {sub.logical_scene_id, sub.chunk_coord} end)
  end

  defp summarize_subscriptions(_), do: []

  defp summarize_ctx(nil), do: nil

  defp summarize_ctx(ctx) when is_map(ctx) do
    %{
      request_id: Map.get(ctx, :request_id),
      logical_scene_id: Map.get(ctx, :logical_scene_id),
      center_chunk: Map.get(ctx, :center_chunk),
      radius: Map.get(ctx, :radius),
      want_snapshot: Map.get(ctx, :want_snapshot),
      known_count: ctx |> Map.get(:known, %{}) |> map_size_safe()
    }
  end

  defp summarize_job(nil), do: nil

  defp summarize_job(job) when is_map(job) do
    coords = Map.get(job, :coords, [])

    %{
      ctx: summarize_ctx(Map.get(job, :ctx)),
      remaining_count: length(coords),
      next_coords: Enum.take(coords, 8),
      failed?: Map.get(job, :failed?)
    }
  end

  defp route_cache_size(%{entries: entries}) when is_list(entries), do: length(entries)
  defp route_cache_size(_), do: 0

  defp summarize_lease(nil), do: nil

  defp summarize_lease(lease) when is_map(lease) do
    Map.take(lease, [
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch,
      :expires_at_ms
    ])
  end

  defp count_list(nil, _field), do: 0
  defp count_list(storage, field), do: storage |> Map.get(field, []) |> length()

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_), do: 0

  defp app_env(node, app, key), do: safe_rpc(node, Application, :get_env, [app, key])

  defp safe_rpc(node, module, function, args, timeout \\ 15_000) do
    :rpc.call(node, module, function, args, timeout)
  catch
    :exit, reason -> {:rpc_exit, reason}
  end

  defp split_args(rest), do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  defp parse_int(text) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp log_args(node, []), do: {log_path(node, "gate"), nil, 80}
  defp log_args(node, [which]), do: {log_path(node, which), nil, 80}

  defp log_args(node, [which, pattern]) do
    case parse_int(pattern) do
      {:ok, count} -> {log_path(node, which), nil, count}
      _ -> {log_path(node, which), pattern, 80}
    end
  end

  defp log_args(node, [which, pattern, count_text | _]) do
    count =
      case parse_int(count_text) do
        {:ok, value} -> value
        _ -> 80
      end

    {log_path(node, which), pattern, count}
  end

  defp log_path(node, "gate"), do: app_env(node, :gate_server, :cli_observe_log)
  defp log_path(node, "scene"), do: app_env(node, :scene_server, :cli_observe_log)
  defp log_path(node, "world"), do: app_env(node, :world_server, :cli_observe_log)
  defp log_path(_node, path), do: path

  defp tail_lines(path, pattern, count) when is_binary(path) do
    if not File.exists?(path) do
      []
    else
      tail_existing_lines(path, pattern, count)
    end
  end

  defp tail_lines(path, _pattern, _count), do: [%{error: "invalid log path", path: path}]

  defp tail_existing_lines(path, pattern, count) do
    matcher =
      case pattern do
        nil -> fn _line -> true end
        value -> fn line -> String.contains?(line, value) end
      end

    path
    |> File.stream!([], :line)
    |> Enum.reduce([], fn line, acc ->
      if matcher.(line) do
        [String.trim_trailing(line) | acc] |> Enum.take(max(count, 1))
      else
        acc
      end
    end)
    |> Enum.reverse()
  rescue
    exception -> [%{error: Exception.message(exception), path: path}]
  end

  defp map_size_safe(map) when is_map(map), do: map_size(map)
  defp map_size_safe(_), do: 0

  defp normalize_path(path), do: String.replace(path, "\\", "/")

  defp emit(event, payload) do
    IO.puts(
      "server_cli event=#{inspect(event)} payload=#{inspect(payload, limit: :infinity, printable_limit: :infinity)}"
    )
  end
end

VoxiaServerStdioCli.main(System.argv())
