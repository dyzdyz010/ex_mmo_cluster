defmodule DualSceneDemoSetup do
  @moduledoc false

  @default_logical_scene_id 1
  @scene2_region_id 1_000_002
  @scene2_owner_ref 2
  @scene1_region_id 1_000_001
  @scene1_owner_ref 1
  @scene1_center_chunk {0, 0, 0}
  @scene2_center_chunk {1, 0, 0}
  @scene1_chunks [@scene1_center_chunk]
  @scene2_chunks [@scene2_center_chunk]
  @platform_y_macro 0
  @platform_macro_min 0
  @platform_macro_max 15
  @scene1_material_id 1
  @scene2_material_id 2

  def run(argv) do
    opts = parse!(argv)
    target = connect_target!(opts)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    lease_ttl_ms = Keyword.fetch!(opts, :lease_ttl_ms)
    future_ms = System.system_time(:millisecond) + lease_ttl_ms
    ledger = WorldServer.Voxel.MapLedger

    {:ok, scene1_assignment, scene1_lease} =
      ensure_scene1_region!(target, ledger, logical_scene_id, future_ms)

    {:ok, scene2_assignment, scene2_lease} =
      ensure_scene2_region!(target, ledger, logical_scene_id, future_ms)

    {:ok, routes} =
      rpc!(target, WorldServer.Voxel.MapLedger, :route_chunks_with_leases, [
        ledger,
        logical_scene_id,
        @scene1_chunks ++ @scene2_chunks
      ])

    validate_routes!(routes)
    terrain = seed_demo_platforms!(target, routes)

    result = %{
      status: :ok,
      target_node: target,
      logical_scene_id: logical_scene_id,
      scene1_assignment: summarize_assignment(scene1_assignment),
      scene1_lease: summarize_lease(scene1_lease),
      scene2_assignment: summarize_assignment(scene2_assignment),
      scene2_lease: summarize_lease(scene2_lease),
      routes: summarize_routes(routes),
      terrain: terrain,
      browser_overlay: %{
        scene1: %{color: "#25a8ff", chunks: %{x: [0, 0], z: [0, 0]}},
        scene2: %{color: "#ffa726", chunks: %{x: [1, 1], z: [0, 0]}},
        boundary: %{chunk_x: 1}
      }
    }

    IO.puts(summary_text(result))
    IO.puts("dual_scene_demo_json=#{JasonLike.encode!(result)}")
  end

  defp parse!(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        switches: [
          target_node: :string,
          logical_scene_id: :integer,
          lease_ttl_ms: :integer
        ]
      )

    if invalid != [] do
      raise "invalid options: #{inspect(invalid)}"
    end

    [
      target_node: Keyword.get(opts, :target_node, default_target_node()),
      logical_scene_id: Keyword.get(opts, :logical_scene_id, @default_logical_scene_id),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, :timer.hours(6))
    ]
  end

  defp default_target_node do
    node_name = System.get_env("NODE_NAME") || "cluster"

    if String.contains?(node_name, "@") do
      node_name
    else
      host = System.get_env("COMPUTERNAME") || "localhost"
      "#{node_name}@#{host}"
    end
  end

  defp connect_target!(opts) do
    target_name = Keyword.fetch!(opts, :target_node)
    validate_target_name!(target_name)
    target = :erlang.binary_to_atom(target_name, :utf8)

    if Node.connect(target) do
      target
    else
      raise "cannot connect to #{inspect(target)}; confirm scripts/start-server.ps1 is running with the same ERLANG_COOKIE and ERL_EPMD_PORT"
    end
  end

  defp validate_target_name!(target_name) do
    expected = default_target_node()

    unless target_name == expected do
      raise "refusing target node #{inspect(target_name)}; expected #{inspect(expected)} from NODE_NAME/COMPUTERNAME"
    end
  end

  defp rpc!(target, module, function, args) do
    case :rpc.call(target, module, function, args, 15_000) do
      {:badrpc, reason} ->
        raise "rpc #{inspect(module)}.#{function}/#{length(args)} failed: #{inspect(reason)}"

      other ->
        other
    end
  end

  defp ensure_scene1_region!(target, ledger, logical_scene_id, future_ms) do
    existing =
      rpc!(target, WorldServer.Voxel.MapLedger, :route_chunk_with_lease, [
        ledger,
        logical_scene_id,
        @scene1_center_chunk
      ])

    owner_epoch = next_owner_epoch(existing, 1)

    {:ok, assignment} =
      rpc!(target, WorldServer.Voxel.MapLedger, :put_region, [
        ledger,
        %{
          logical_scene_id: logical_scene_id,
          region_id: @scene1_region_id,
          bounds_chunk_min: {0, -1, 0},
          bounds_chunk_max: {1, 1, 1},
          owner_scene_instance_ref: @scene1_owner_ref,
          owner_epoch: owner_epoch,
          assigned_scene_node: target
        }
      ])

    {:ok, lease} =
      rpc!(target, WorldServer.Voxel.MapLedger, :issue_lease, [
        ledger,
        @scene1_region_id,
        @scene1_owner_ref,
        [owner_epoch: owner_epoch, expires_at_ms: future_ms, token_version: owner_epoch]
      ])

    {:ok, assignment, lease}
  end

  defp ensure_scene2_region!(target, ledger, logical_scene_id, future_ms) do
    existing =
      rpc!(target, WorldServer.Voxel.MapLedger, :route_chunk_with_lease, [
        ledger,
        logical_scene_id,
        @scene2_center_chunk
      ])

    owner_epoch = next_owner_epoch(existing, 1)

    {:ok, assignment} =
      rpc!(target, WorldServer.Voxel.MapLedger, :put_region, [
        ledger,
        %{
          logical_scene_id: logical_scene_id,
          region_id: @scene2_region_id,
          bounds_chunk_min: {1, -1, 0},
          bounds_chunk_max: {2, 1, 1},
          owner_scene_instance_ref: @scene2_owner_ref,
          owner_epoch: owner_epoch,
          assigned_scene_node: target
        }
      ])

    {:ok, lease} =
      rpc!(target, WorldServer.Voxel.MapLedger, :issue_lease, [
        ledger,
        @scene2_region_id,
        @scene2_owner_ref,
        [owner_epoch: owner_epoch, expires_at_ms: future_ms, token_version: owner_epoch]
      ])

    {:ok, assignment, lease}
  end

  defp next_owner_epoch({:ok, %{lease: lease}}, _fallback) do
    max(lease.owner_epoch + 1, max(lease.expires_at_ms + 1, System.system_time(:millisecond)))
  end

  defp next_owner_epoch(_missing, fallback), do: max(fallback, System.system_time(:millisecond))

  defp validate_routes!(routes) do
    scene1 = Map.fetch!(routes, @scene1_center_chunk)
    scene2 = Map.fetch!(routes, @scene2_center_chunk)

    unless scene1.assignment.region_id == @scene1_region_id and
             scene1.lease.owner_scene_instance_ref == @scene1_owner_ref do
      raise "scene1 route owner mismatch: #{inspect(scene1)}"
    end

    unless scene2.assignment.region_id == @scene2_region_id and
             scene2.lease.owner_scene_instance_ref == @scene2_owner_ref do
      raise "scene2 route owner mismatch: #{inspect(scene2)}"
    end
  end

  defp seed_demo_platforms!(target, routes) do
    scene1 =
      Enum.map(@scene1_chunks, fn chunk_coord ->
        seed_demo_platform!(
          target,
          chunk_coord,
          Map.fetch!(routes, chunk_coord),
          @scene1_material_id
        )
      end)

    scene2 =
      Enum.map(@scene2_chunks, fn chunk_coord ->
        seed_demo_platform!(
          target,
          chunk_coord,
          Map.fetch!(routes, chunk_coord),
          @scene2_material_id
        )
      end)

    scene1 ++ scene2
  end

  defp seed_demo_platform!(
         target,
         chunk_coord,
         %{assignment: assignment, lease: lease},
         material_id
       ) do
    block = %{material_id: material_id, health: 100}

    intents =
      for mx <- @platform_macro_min..@platform_macro_max,
          mz <- @platform_macro_min..@platform_macro_max do
        %{
          logical_scene_id: assignment.logical_scene_id,
          chunk_coord: chunk_coord,
          lease: lease,
          operation: :put_solid_block,
          macro: {mx, @platform_y_macro, mz},
          block: block
        }
      end

    reply =
      rpc!(target, GenServer, :call, [
        SceneServer.Voxel.ChunkDirectory,
        {:apply_intents, intents},
        30_000
      ])

    case reply do
      {:ok, applied} ->
        %{
          chunk: Tuple.to_list(chunk_coord),
          region_id: assignment.region_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          material_id: material_id,
          macro_range: [@platform_macro_min, @platform_macro_max],
          attempted: length(intents),
          changed_count: Map.get(applied, :changed_count, 0),
          skipped_count: Map.get(applied, :skipped_count, 0),
          chunk_version: Map.get(applied, :chunk_version, 0)
        }

      {:error, reason} ->
        raise "failed to seed demo terrain for #{inspect(chunk_coord)}: #{inspect(reason)}"
    end
  end

  defp summarize_routes(routes) when is_map(routes) do
    routes
    |> Enum.map(fn {coord, %{assignment: assignment, lease: lease}} ->
      %{
        chunk: Tuple.to_list(coord),
        region_id: assignment.region_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        lease_id: lease.lease_id,
        assigned_scene_node: assignment.assigned_scene_node,
        bounds_chunk_min: Tuple.to_list(assignment.bounds_chunk_min),
        bounds_chunk_max: Tuple.to_list(assignment.bounds_chunk_max)
      }
    end)
    |> Enum.sort_by(& &1.chunk)
  end

  defp summarize_assignment(assignment) do
    %{
      region_id: assignment.region_id,
      owner_scene_instance_ref: assignment.owner_scene_instance_ref,
      owner_epoch: assignment.owner_epoch,
      bounds_chunk_min: Tuple.to_list(assignment.bounds_chunk_min),
      bounds_chunk_max: Tuple.to_list(assignment.bounds_chunk_max),
      assigned_scene_node: assignment.assigned_scene_node
    }
  end

  defp summarize_lease(lease) do
    %{
      region_id: lease.region_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      lease_id: lease.lease_id,
      expires_at_ms: lease.expires_at_ms
    }
  end

  defp summary_text(result) do
    route_text =
      result.routes
      |> Enum.map(fn route ->
        "chunk=#{Enum.join(route.chunk, ",")} region=#{route.region_id} owner=#{route.owner_scene_instance_ref} lease=#{route.lease_id}"
      end)
      |> Enum.join(" ")

    "dual_scene_demo=ok target=#{result.target_node} boundary_chunk_x=1 #{route_text}"
  end
end

defmodule JasonLike do
  @moduledoc false

  def encode!(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> encode_key(key) <> ":" <> encode!(item) end)
      |> Enum.join(",")

    "{" <> entries <> "}"
  end

  def encode!(value) when is_list(value) do
    "[" <> (value |> Enum.map(&encode!/1) |> Enum.join(",")) <> "]"
  end

  def encode!(value) when is_tuple(value), do: value |> Tuple.to_list() |> encode!()
  def encode!(value) when is_atom(value), do: encode!(Atom.to_string(value))
  def encode!(value) when is_binary(value), do: inspect(value)
  def encode!(value) when is_integer(value), do: Integer.to_string(value)
  def encode!(value) when is_float(value), do: Float.to_string(value)
  def encode!(true), do: "true"
  def encode!(false), do: "false"
  def encode!(nil), do: "null"

  defp encode_key(key) when is_atom(key), do: encode!(Atom.to_string(key))
  defp encode_key(key), do: encode!(to_string(key))
end

DualSceneDemoSetup.run(System.argv())
