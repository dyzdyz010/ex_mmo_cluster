defmodule GateServer.VoxelSmoke do
  @moduledoc """
  CLI-shaped E2E smoke runner for the server-authoritative voxel path.

  The runner drives a real `GateServer.WsConnection` with binary protocol frames
  and observes the resulting Gate -> World -> Scene -> DataService flow through
  structured observe logs plus `server_stdio`-formatted state snapshots. It is
  intentionally non-GUI so local automation can validate the runtime even when a
  browser or visual client is unavailable.

  The smoke owns its minimum runtime prerequisites: it starts `:data_service`
  so `DataService.Repo` is available, then starts or reuses the local World,
  Scene chunk directory, and Gate interface processes. After mutating a hot
  chunk it calls `SceneServer.Voxel.ChunkProcess.flush_persistence/2` before
  reading PostgreSQL, which keeps the CLI assertion aligned with the runtime's
  async persistence cold path.
  """

  alias GateServer.WsConnection
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types
  alias WorldServer.Voxel.MapLedger

  @default_observe_dir ".demo/observe"
  @lease_ttl_ms 60_000
  @owner_scene_instance_ref 7_001
  @owner_epoch 1
  @started_key {__MODULE__, :started}
  @ws_pid_key {__MODULE__, :ws_pid}
  @deferred_chunk_updates_key {__MODULE__, :deferred_chunk_updates}

  @doc """
  Runs the voxel protocol smoke scenario.

  Options:

    * `:logical_scene_id` - logical scene id to exercise. A unique id is used by default.
    * `:region_id` - world region id. A unique id is used by default.
    * `:observe_dir` - directory for default logs, defaults to `.demo/observe`.
    * `:gate_observe_log`, `:scene_observe_log`, `:world_observe_log` - explicit observe logs.
    * `:stdio_log` - file receiving `server_stdio`-formatted snapshots.
    * `:summary_path` - file receiving the final inspected summary.
    * `:cid` - connection character id, defaults to `42`.
  """
  def run(opts \\ []) when is_list(opts) do
    logical_scene_id =
      Keyword.get_lazy(opts, :logical_scene_id, fn ->
        90_000 + System.unique_integer([:positive, :monotonic])
      end)

    region_id =
      Keyword.get_lazy(opts, :region_id, fn ->
        190_000 + System.unique_integer([:positive, :monotonic])
      end)

    paths = resolve_paths(opts, logical_scene_id)
    reset_log_files(paths)

    with_observe_logs(paths, logical_scene_id, fn ->
      Process.put(@started_key, [])
      Process.put(@ws_pid_key, nil)
      Process.put(@deferred_chunk_updates_key, [])

      try do
        append_stdio(paths.stdio_log, "voxel_smoke_started", %{
          logical_scene_id: logical_scene_id,
          region_id: region_id
        })

        :ok = ensure_runtime()
        {:ok, lease} = put_world_region(logical_scene_id, region_id)
        {:ok, ws_pid} = WsConnection.start_link(self())
        Process.put(@ws_pid_key, ws_pid)
        put_connection_in_scene(ws_pid, Keyword.get(opts, :cid, 42))

        summary =
          run_protocol!(
            ws_pid,
            logical_scene_id,
            region_id,
            lease,
            paths,
            Keyword.get(opts, :cid, 42)
          )

        flush_observe_logs(paths)
        write_summary(paths.summary_path, summary)
        append_stdio(paths.stdio_log, "voxel_smoke_completed", summary_for_stdio(summary))

        {:ok, summary}
      rescue
        exception ->
          failure = %{
            reason: Exception.message(exception),
            stacktrace: Exception.format_stacktrace(__STACKTRACE__)
          }

          append_stdio(paths.stdio_log, "voxel_smoke_failed", failure)
          flush_observe_logs(paths)
          {:error, failure}
      after
        stop_ws(Process.get(@ws_pid_key))
        flush_observe_logs(paths)
        cleanup_started(Process.get(@started_key, []))
        Process.delete(@started_key)
        Process.delete(@ws_pid_key)
        Process.delete(@deferred_chunk_updates_key)
        restore_self_mailbox()
      end
    end)
  end

  @doc "Returns the default log paths for one logical scene id."
  def default_paths(logical_scene_id, observe_dir \\ @default_observe_dir) do
    observe_dir = Path.expand(observe_dir)

    %{
      gate_observe_log: Path.join(observe_dir, "gate-voxel-e2e-smoke-#{logical_scene_id}.log"),
      scene_observe_log: Path.join(observe_dir, "scene-voxel-e2e-smoke-#{logical_scene_id}.log"),
      world_observe_log: Path.join(observe_dir, "world-voxel-e2e-smoke-#{logical_scene_id}.log"),
      stdio_log: Path.join(observe_dir, "gate-stdio-voxel-e2e-smoke-#{logical_scene_id}.log"),
      summary_path: Path.join(observe_dir, "gate-voxel-e2e-smoke-#{logical_scene_id}.summary")
    }
  end

  defp run_protocol!(ws_pid, logical_scene_id, region_id, lease, paths, cid) do
    GateServer.CliObserve.emit("voxel_e2e_smoke_protocol_started", %{
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      cid: cid
    })

    debug = send_debug_probe!(ws_pid, 1, "voxel_transport")
    assert_contains!(debug, "voxel_sync=server-authoritative", :missing_authority_debug)
    assert_contains!(debug, "connection_status=in_scene", :missing_scene_status_debug)

    initial = subscribe_chunk!(ws_pid, 2, logical_scene_id, {0, 0, 0})
    assert_equal!(initial.storage.chunk_version, 0, :initial_snapshot_not_zero)

    result_v1 = impact_chunk!(ws_pid, 3, 1, logical_scene_id, {8, 16, 24})
    assert_equal!(result_v1.result_code, :accepted, :impact_v1_rejected)

    updated = receive_chunk_update!(2)
    assert_equal!(chunk_update_version(updated), 1, :updated_chunk_not_version_one)
    assert_chunk_update_applied!(updated, logical_scene_id, {0, 0, 0}, {1, 2, 3})

    flush_chunk_persistence!(logical_scene_id, {0, 0, 0})
    stored_v1 = stored_snapshot!(logical_scene_id, {0, 0, 0})
    assert_equal!(stored_v1.chunk_version, 1, :stored_snapshot_not_version_one)

    unsubscribe_chunk!(ws_pid, 4, logical_scene_id, [{0, 0, 0}])

    result_v2 = impact_chunk!(ws_pid, 5, 2, logical_scene_id, {16, 16, 24})
    assert_equal!(result_v2.result_code, :accepted, :impact_v2_rejected)
    refute_chunk_push!(150)

    flush_chunk_persistence!(logical_scene_id, {0, 0, 0})
    stored_v2 = stored_snapshot!(logical_scene_id, {0, 0, 0})
    assert_equal!(stored_v2.chunk_version, 2, :stored_snapshot_not_version_two)

    stdio_snapshot = GateServer.StdioInterface.voxel_snapshot()
    append_stdio(paths.stdio_log, "voxel", stdio_snapshot)

    summary = %{
      status: :ok,
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      cid: cid,
      lease: lease_summary(lease),
      debug: debug,
      protocol: %{
        initial_snapshot_version: initial.storage.chunk_version,
        impact_v1_result_ref: result_v1.result_ref,
        updated_frame_type: chunk_update_type(updated),
        updated_chunk_version: chunk_update_version(updated),
        # Backward-compatible field for older CLI consumers. Check
        # `updated_frame_type` before assuming the wire frame was a snapshot.
        updated_snapshot_version: chunk_update_version(updated),
        impact_v2_result_ref: result_v2.result_ref,
        stored_snapshot_version: stored_v2.chunk_version,
        unsubscribe_stopped_push?: true
      },
      logs: Map.from_struct(paths)
    }

    GateServer.CliObserve.emit("voxel_e2e_smoke_protocol_completed", summary_for_stdio(summary))
    summary
  end

  defp resolve_paths(opts, logical_scene_id) do
    defaults =
      opts
      |> Keyword.get(:observe_dir, @default_observe_dir)
      |> then(&default_paths(logical_scene_id, &1))

    struct!(
      __MODULE__.Paths,
      %{
        gate_observe_log:
          Path.expand(Keyword.get(opts, :gate_observe_log, defaults.gate_observe_log)),
        scene_observe_log:
          Path.expand(Keyword.get(opts, :scene_observe_log, defaults.scene_observe_log)),
        world_observe_log:
          Path.expand(Keyword.get(opts, :world_observe_log, defaults.world_observe_log)),
        stdio_log: Path.expand(Keyword.get(opts, :stdio_log, defaults.stdio_log)),
        summary_path: Path.expand(Keyword.get(opts, :summary_path, defaults.summary_path))
      }
    )
  end

  defp reset_log_files(paths) do
    paths
    |> Map.from_struct()
    |> Map.values()
    |> Enum.each(fn path ->
      File.mkdir_p!(Path.dirname(path))
      File.rm(path)
    end)
  end

  defp with_observe_logs(paths, logical_scene_id, fun) do
    previous = %{
      gate: Application.fetch_env(:gate_server, :cli_observe_log),
      scene: Application.fetch_env(:scene_server, :cli_observe_log),
      world: Application.fetch_env(:world_server, :cli_observe_log)
    }

    try do
      Application.delete_env(:gate_server, :cli_observe_log)
      Application.delete_env(:scene_server, :cli_observe_log)
      Application.delete_env(:world_server, :cli_observe_log)

      routes = register_observe_routes(paths, logical_scene_id)

      try do
        fun.()
      after
        unregister_observe_routes(routes, logical_scene_id)
      end
    after
      restore_env(:gate_server, :cli_observe_log, previous.gate)
      restore_env(:scene_server, :cli_observe_log, previous.scene)
      restore_env(:world_server, :cli_observe_log, previous.world)
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp ensure_runtime do
    token_store = data_module(:WriteTokenStore)
    snapshot_store = data_module(:ChunkSnapshotStore)

    with :ok <- ensure_application_started(:data_service),
         :ok <- ensure_loaded(token_store, :data_write_token_store_unavailable),
         :ok <- ensure_loaded(snapshot_store, :data_chunk_snapshot_store_unavailable),
         :ok <-
           ensure_named(token_store, fn ->
             apply(token_store, :start_link, [[name: token_store]])
           end),
         # Phase 1d: ChunkSnapshotStore is a stateless module backed by
         # `DataService.Repo`. The Repo lives in `DataService.Application`'s
         # supervision tree, so smoke runs only need to verify the module
         # loaded — there is no GenServer to spin up here.
         :ok <-
           ensure_named(MapLedger, fn ->
             MapLedger.start_link(name: MapLedger, write_token_store: token_store)
           end),
         # 阶段3.1：chunk 进程身份注册表必须早于 VoxelChunkSup / ChunkDirectory。
         :ok <-
           ensure_named(SceneServer.Voxel.ChunkRegistry, fn ->
             Registry.start_link(keys: :unique, name: SceneServer.Voxel.ChunkRegistry)
           end),
         :ok <-
           ensure_named(SceneServer.VoxelChunkSup, fn ->
             SceneServer.VoxelChunkSup.start_link(name: SceneServer.VoxelChunkSup)
           end),
         :ok <-
           ensure_named(SceneServer.Voxel.ChunkDirectory, fn ->
             SceneServer.Voxel.ChunkDirectory.start_link(
               name: SceneServer.Voxel.ChunkDirectory,
               chunk_sup: SceneServer.VoxelChunkSup
             )
           end),
         # Scene-side observe events are written by the supervised
         # `SceneServer.CliObserve.Manager`. Without it the scene observe log is
         # never created and the E2E smoke's `scene_observe_log` read fails.
         :ok <-
           ensure_named(SceneServer.CliObserve.Manager, fn ->
             SceneServer.CliObserve.Manager.start_link([])
           end),
         :ok <-
           ensure_named(GateServer.Interface, fn ->
             GateServer.VoxelSmokeLocalInterface.start_link(
               name: GateServer.Interface,
               scene_server: node(),
               world_server: node()
             )
           end) do
      :ok
    end
  end

  defp ensure_application_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {app, reason}}
    end
  end

  defp ensure_loaded(module, reason) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      _other -> {:error, reason}
    end
  end

  defp ensure_named(name, start_fun) do
    case Process.whereis(name) do
      nil ->
        case start_fun.() do
          {:ok, pid} ->
            record_started(name, pid)
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          {:error, reason} ->
            {:error, {name, reason}}
        end

      _pid ->
        :ok
    end
  end

  defp record_started(name, pid) when is_pid(pid) do
    started = Process.get(@started_key, [])
    Process.put(@started_key, [{name, pid} | started])
    :ok
  end

  defp put_world_region(logical_scene_id, region_id) do
    now_ms = System.system_time(:millisecond)
    lease_id = 290_000 + System.unique_integer([:positive, :monotonic])
    token_version = 390_000 + System.unique_integer([:positive, :monotonic])

    with {:ok, _assignment} <-
           MapLedger.put_region(MapLedger, %{
             region_id: region_id,
             logical_scene_id: logical_scene_id,
             bounds_chunk_min: {0, 0, 0},
             bounds_chunk_max: {1, 1, 1},
             owner_scene_instance_ref: @owner_scene_instance_ref,
             owner_epoch: 0,
             assigned_scene_node: node()
           }),
         {:ok, lease} <-
           MapLedger.issue_lease(MapLedger, region_id, @owner_scene_instance_ref,
             lease_id: lease_id,
             owner_epoch: @owner_epoch,
             expires_at_ms: now_ms + @lease_ttl_ms,
             token_version: token_version
           ) do
      {:ok, lease}
    end
  end

  defp put_connection_in_scene(pid, cid) do
    :sys.replace_state(pid, fn state -> %{state | status: :in_scene, cid: cid} end)
    _state = :sys.get_state(pid)
    :ok
  end

  defp send_debug_probe!(pid, request_id, command) do
    WsConnection.receive_frame(
      pid,
      <<0x6F, request_id::64-big, byte_size(command)::16-big, command::binary>>
    )

    receive do
      {:gate_ws_send, <<0x6F, ^request_id::64-big, len::16-big, result::binary-size(len)>>} ->
        result

      {:gate_ws_send, other} ->
        raise "unexpected debug probe response: #{inspect(IO.iodata_to_binary(other))}"
    after
      2_000 -> raise "timed out waiting for voxel debug probe response"
    end
  end

  defp subscribe_chunk!(pid, request_id, logical_scene_id, {cx, cy, cz}) do
    WsConnection.receive_frame(
      pid,
      <<0x60, request_id::64-big, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed,
        cz::32-big-signed, 0::8, 1::8, 0::16-big>>
    )

    receive_snapshot!(request_id)
  end

  defp unsubscribe_chunk!(pid, request_id, logical_scene_id, chunks) do
    payload =
      IO.iodata_to_binary([
        <<0x61, request_id::64-big, logical_scene_id::64-big, length(chunks)::16-big>>,
        Enum.map(chunks, fn {cx, cy, cz} ->
          <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed>>
        end)
      ])

    WsConnection.receive_frame(pid, payload)

    receive do
      {:gate_ws_send, <<0x80, ^request_id::64-big, 0x00>>} ->
        :ok

      {:gate_ws_send, other} ->
        raise "unexpected unsubscribe response: #{inspect(IO.iodata_to_binary(other))}"
    after
      2_000 -> raise "timed out waiting for voxel unsubscribe response"
    end
  end

  defp impact_chunk!(pid, request_id, client_intent_seq, logical_scene_id, {x, y, z}) do
    WsConnection.receive_frame(
      pid,
      <<0x64, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big, 1::32-big,
        x::64-big-signed, y::64-big-signed, z::64-big-signed, 2::16-big, 0::64-big>>
    )

    receive_intent_result!(request_id, client_intent_seq)
  end

  defp receive_intent_result!(request_id, client_intent_seq) do
    receive do
      {:gate_ws_send, iodata} ->
        case IO.iodata_to_binary(iodata) do
          <<opcode, _payload::binary>> = chunk_update when opcode in [0x62, 0x63] ->
            defer_chunk_update(chunk_update)
            receive_intent_result!(request_id, client_intent_seq)

          other ->
            decode_intent_result!(other, request_id, client_intent_seq)
        end
    after
      2_000 -> raise "timed out waiting for voxel intent result"
    end
  end

  defp receive_snapshot!(request_id) do
    receive do
      {:gate_ws_send, iodata} ->
        IO.iodata_to_binary(iodata)
        |> decode_snapshot_frame!(request_id)
    after
      2_000 -> raise "timed out waiting for voxel snapshot"
    end
  end

  defp receive_chunk_update!(subscription_request_id) do
    case pop_deferred_chunk_update() do
      nil ->
        receive do
          {:gate_ws_send, iodata} ->
            IO.iodata_to_binary(iodata)
            |> decode_chunk_update_frame!(subscription_request_id)
        after
          2_000 -> raise "timed out waiting for voxel chunk update"
        end

      deferred ->
        decode_chunk_update_frame!(deferred, subscription_request_id)
    end
  end

  defp decode_chunk_update_frame!(<<0x62, _payload::binary>> = frame, subscription_request_id) do
    {:snapshot, decode_snapshot_frame!(frame, subscription_request_id)}
  end

  defp decode_chunk_update_frame!(<<0x63, payload::binary>>, _subscription_request_id) do
    case SceneVoxelCodec.decode_chunk_delta_payload(payload) do
      {:ok, delta} ->
        {:delta, delta}

      {:error, reason} ->
        raise "invalid voxel delta payload: #{inspect(reason)}"
    end
  end

  defp decode_chunk_update_frame!(other, _subscription_request_id) do
    raise "unexpected chunk update response: #{inspect(other)}"
  end

  defp decode_snapshot_frame!(<<0x62, payload::binary>>, request_id) do
    case SceneVoxelCodec.decode_chunk_snapshot_payload(payload) do
      {:ok, snapshot} ->
        assert_equal!(snapshot.request_id, request_id, :snapshot_request_id_mismatch)
        snapshot

      {:error, reason} ->
        raise "invalid voxel snapshot payload: #{inspect(reason)}"
    end
  end

  defp decode_snapshot_frame!(other, _request_id) do
    raise "unexpected snapshot response: #{inspect(other)}"
  end

  defp refute_chunk_push!(timeout_ms) do
    receive do
      {:gate_ws_send, <<0x62, _payload::binary>>} ->
        raise "received voxel snapshot push after unsubscribe"

      {:gate_ws_send, <<0x63, _payload::binary>>} ->
        raise "received voxel delta push after unsubscribe"

      {:gate_ws_send, other} ->
        raise "unexpected post-unsubscribe frame: #{inspect(IO.iodata_to_binary(other))}"
    after
      timeout_ms -> :ok
    end
  end

  defp defer_chunk_update(chunk_update) do
    updates = Process.get(@deferred_chunk_updates_key, [])
    Process.put(@deferred_chunk_updates_key, updates ++ [chunk_update])
  end

  defp pop_deferred_chunk_update do
    case Process.get(@deferred_chunk_updates_key, []) do
      [] ->
        nil

      [head | tail] ->
        Process.put(@deferred_chunk_updates_key, tail)
        head
    end
  end

  defp chunk_update_type({type, _payload}), do: type
  defp chunk_update_version({:snapshot, snapshot}), do: snapshot.storage.chunk_version
  defp chunk_update_version({:delta, delta}), do: delta.new_chunk_version

  defp assert_chunk_update_applied!(
         {:snapshot, snapshot},
         logical_scene_id,
         chunk_coord,
         local_macro
       ) do
    assert_equal!(snapshot.storage.logical_scene_id, logical_scene_id, :snapshot_scene_mismatch)
    assert_equal!(snapshot.storage.chunk_coord, chunk_coord, :snapshot_chunk_mismatch)
    assert_solid_block!(snapshot.storage, local_macro)
  end

  defp assert_chunk_update_applied!({:delta, delta}, logical_scene_id, chunk_coord, local_macro) do
    expected_macro_index = Types.macro_index!(local_macro)

    assert_equal!(delta.logical_scene_id, logical_scene_id, :delta_scene_mismatch)
    assert_equal!(delta.chunk_coord, chunk_coord, :delta_chunk_mismatch)
    assert_equal!(delta.base_chunk_version, 0, :delta_base_version_mismatch)
    assert_equal!(delta.new_chunk_version, 1, :delta_new_version_mismatch)

    case Enum.find(delta.ops, &solid_delta_op?(&1, expected_macro_index)) do
      nil ->
        raise "missing CellSolid ChunkDelta op for macro #{inspect(local_macro)}"

      op ->
        assert_equal!(byte_size(op.payload), 20, :delta_cell_solid_payload_size_mismatch)
    end
  end

  defp solid_delta_op?(%{delta_kind: 1, macro_index: macro_index}, expected_macro_index) do
    macro_index == expected_macro_index
  end

  defp solid_delta_op?(_op, _expected_macro_index), do: false

  defp decode_intent_result!(
         <<0x68, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big,
           result_code::8, result_ref::64-big, authoritative_count::16-big,
           authoritative::binary>>,
         expected_request_id,
         expected_client_intent_seq
       ) do
    assert_equal!(request_id, expected_request_id, :intent_request_id_mismatch)
    assert_equal!(client_intent_seq, expected_client_intent_seq, :intent_seq_mismatch)

    {authoritative_entries, rest} =
      decode_authoritative_entries!(authoritative, authoritative_count)

    <<reason_len::16-big, reason::binary-size(reason_len)>> = rest

    %{
      request_id: request_id,
      client_intent_seq: client_intent_seq,
      logical_scene_id: logical_scene_id,
      result_code: decode_result_code(result_code),
      result_ref: result_ref,
      authoritative: authoritative_entries,
      reason: reason
    }
  rescue
    _exception -> raise "invalid voxel intent result frame"
  end

  defp decode_intent_result!(other, _request_id, _client_intent_seq) do
    raise "unexpected intent result response: #{inspect(other)}"
  end

  defp decode_authoritative_entries!(rest, 0), do: {[], rest}

  defp decode_authoritative_entries!(
         <<kind::8, x::64-big-signed, y::64-big-signed, z::64-big-signed, tail::binary>>,
         count
       )
       when count > 0 do
    {items, rest} = decode_authoritative_entries!(tail, count - 1)
    {[%{kind: kind, target_world_micro: {x, y, z}} | items], rest}
  end

  defp decode_result_code(0), do: :accepted
  defp decode_result_code(1), do: :conflict
  defp decode_result_code(2), do: :rejected
  defp decode_result_code(other), do: {:unknown, other}

  defp stored_snapshot!(logical_scene_id, chunk_coord) do
    snapshot_store = data_module(:ChunkSnapshotStore)

    case apply(snapshot_store, :get_snapshot, [logical_scene_id, chunk_coord]) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise "missing stored voxel snapshot: #{inspect(reason)}"
    end
  end

  defp flush_chunk_persistence!(logical_scene_id, chunk_coord) do
    case ChunkDirectory.lookup_chunk_pid(ChunkDirectory, logical_scene_id, chunk_coord) do
      {:ok, pid} ->
        case ChunkProcess.flush_persistence(pid) do
          :ok -> :ok
          other -> raise "failed to flush voxel chunk persistence: #{inspect(other)}"
        end

      other ->
        raise "could not lookup hot voxel chunk for persistence flush: #{inspect(other)}"
    end
  end

  defp assert_solid_block!(%Storage{} = storage, macro) do
    solid_block_mode = MacroCellHeader.cell_mode_solid_block()

    case Storage.macro_header_at(storage, macro) do
      %{mode: ^solid_block_mode} -> :ok
      other -> raise "expected solid voxel macro #{inspect(macro)}, got #{inspect(other)}"
    end
  end

  defp assert_equal!(left, right, _reason) when left == right, do: :ok

  defp assert_equal!(left, right, reason) do
    raise "#{reason}: expected #{inspect(right)}, got #{inspect(left)}"
  end

  defp assert_contains!(text, substring, _reason) when is_binary(text) and is_binary(substring) do
    if String.contains?(text, substring), do: :ok, else: raise("missing #{substring} in #{text}")
  end

  defp lease_summary(lease) do
    lease_map = Map.from_struct(lease)

    %{
      lease_id: Map.fetch!(lease_map, :lease_id),
      owner_scene_instance_ref: Map.fetch!(lease_map, :owner_scene_instance_ref),
      owner_epoch: Map.fetch!(lease_map, :owner_epoch),
      token_version: Map.get(lease_map, :token_version),
      expires_at_ms: Map.fetch!(lease_map, :expires_at_ms)
    }
  end

  defp summary_for_stdio(summary) do
    summary
    |> Map.take([:status, :logical_scene_id, :region_id, :cid, :lease, :protocol, :logs])
  end

  defp append_stdio(path, event, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, GateServer.StdioInterface.format_event(event, payload), [:append])
  end

  defp write_summary(path, summary) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      inspect(summary, pretty: true, limit: :infinity, printable_limit: :infinity)
    )

    File.write!(path, "\n", [:append])
  end

  defp register_observe_routes(paths, logical_scene_id) do
    [
      {GateServer.CliObserve, paths.gate_observe_log},
      {SceneServer.CliObserve, paths.scene_observe_log},
      {WorldServer.CliObserve, paths.world_observe_log}
    ]
    |> Enum.flat_map(fn {observe_module, path} ->
      case observe_module.register_route(logical_scene_id, path) do
        {:ok, token} -> [{observe_module, token}]
        {:error, _reason} -> []
      end
    end)
  end

  defp unregister_observe_routes(routes, logical_scene_id) do
    Enum.each(routes, fn {observe_module, token} ->
      observe_module.unregister_route(logical_scene_id, token)
    end)
  end

  defp flush_observe_logs(paths) do
    GateServer.CliObserve.flush()
    SceneServer.CliObserve.flush_path(paths.scene_observe_log)
    WorldServer.CliObserve.flush()
  end

  defp stop_ws(nil), do: :ok

  defp stop_ws(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    WsConnection.close(pid, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  defp cleanup_started(started) do
    started
    |> Enum.each(fn {_name, pid} ->
      if Process.alive?(pid) do
        stop_started(pid)
      end
    end)
  end

  defp stop_started(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
  end

  defp restore_self_mailbox do
    receive do
      {:gate_ws_send, _iodata} -> restore_self_mailbox()
    after
      0 -> :ok
    end
  end

  defp data_module(name), do: Module.concat([DataService, Voxel, name])
end
