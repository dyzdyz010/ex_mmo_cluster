defmodule FigureEightPowerCrossingProbe do
  @moduledoc false

  @logical_scene_id 1
  @chunk {-1, 0, 0}
  @region_id 1_000_001
  @owner_ref 1
  @bounds_min {-2, -2, -2}
  @bounds_max {3, 3, 3}
  @lease_ttl_ms :timer.hours(6)

  @iron 5
  @power 6
  @load 7
  @y 5
  @power_coord {8, @y, 8}
  @left_load {4, @y, 4}
  @right_load {12, @y, 12}
  @break_coord {4, @y, 6}
  @left_probe @left_load
  @right_probe @right_load

  def run(argv) do
    opts = parse!(argv)
    target = connect_target!(opts)
    lease = ensure_region_and_lease!(target)
    apply_lease!(target, lease)
    seed_figure_eight!(target, lease)

    before_summary = trigger_auto_circuit!(target, lease)
    Process.sleep(350)
    before_current = collect_current!(target)

    break_left_ring!(target, lease)
    after_summary = trigger_auto_circuit!(target, lease)
    Process.sleep(350)
    after_current = collect_current!(target)

    result = %{
      status: :ok,
      target_node: target,
      logical_scene_id: @logical_scene_id,
      chunk: coord_list(@chunk),
      layout: %{
        power_crossing: coord_list(world_coord(@power_coord)),
        left_load: coord_list(world_coord(@left_load)),
        right_load: coord_list(world_coord(@right_load)),
        broken_block: coord_list(world_coord(@break_coord))
      },
      expected: %{
        closed_component_count_note:
          "closed_circuit_count reports energized connected components, not independent graph cycles",
        before_closed_components: 1,
        after_closed_components: 1,
        before_active_current_cells: 31,
        after_active_current_cells: 16,
        after_left_ring_current: :off,
        after_right_ring_current: :on
      },
      before: %{
        auto_circuit: summarize_auto(before_summary),
        current: before_current
      },
      after: %{
        auto_circuit: summarize_auto(after_summary),
        current: after_current
      }
    }

    IO.puts(summary_text(result))
    IO.puts("before=#{probe_text(result.before)}")
    IO.puts("after=#{probe_text(result.after)}")
    IO.puts("figure_eight_power_crossing_json=#{JsonLike.encode!(result)}")
  end

  defp parse!(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, switches: [target_node: :string])

    if invalid != [] do
      raise "invalid options: #{inspect(invalid)}"
    end

    [target_node: Keyword.get(opts, :target_node, default_target_node())]
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
      raise "cannot connect to #{inspect(target)}"
    end
  end

  defp validate_target_name!(target_name) do
    expected = default_target_node()

    unless target_name == expected do
      raise "refusing target node #{inspect(target_name)}; expected #{inspect(expected)}"
    end
  end

  defp ensure_region_and_lease!(target) do
    existing =
      rpc!(target, WorldServer.Voxel.MapLedger, :route_chunk_with_lease, [
        WorldServer.Voxel.MapLedger,
        @logical_scene_id,
        @chunk
      ])

    owner_epoch =
      case existing do
        {:ok, %{lease: lease}} -> lease.owner_epoch + 1
        _missing -> 1
      end

    {:ok, assignment} =
      rpc!(target, WorldServer.Voxel.MapLedger, :put_region, [
        WorldServer.Voxel.MapLedger,
        %{
          logical_scene_id: @logical_scene_id,
          region_id: @region_id,
          bounds_chunk_min: @bounds_min,
          bounds_chunk_max: @bounds_max,
          owner_scene_instance_ref: @owner_ref,
          owner_epoch: owner_epoch,
          assigned_scene_node: target
        }
      ])

    {:ok, lease} =
      rpc!(target, WorldServer.Voxel.MapLedger, :issue_lease, [
        WorldServer.Voxel.MapLedger,
        assignment.region_id,
        @owner_ref,
        [owner_epoch: owner_epoch, ttl_ms: @lease_ttl_ms, token_version: owner_epoch]
      ])

    lease
  end

  defp apply_lease!(target, lease) do
    {:ok, _lease} = rpc!(target, SceneServer.Voxel.RegionRuntime, :apply_lease, [lease])
    :ok
  end

  defp seed_figure_eight!(target, lease) do
    clear =
      for x <- 0..15,
          z <- 0..15 do
        %{
          logical_scene_id: @logical_scene_id,
          chunk_coord: @chunk,
          lease: lease,
          operation: :break_block,
          macro: {x, @y, z}
        }
      end

    cells =
      figure_eight_cells()
      |> Enum.map(fn {coord, material_id} ->
        %{
          logical_scene_id: @logical_scene_id,
          chunk_coord: @chunk,
          lease: lease,
          operation: :put_solid_block,
          macro: coord,
          block: %{material_id: material_id, health: 100}
        }
      end)

    apply_intents!(target, clear ++ cells)
  end

  defp figure_eight_cells do
    left_loop =
      rect({8, @y, 8}, {4, @y, 4})

    right_loop =
      rect({8, @y, 8}, {12, @y, 12})

    (left_loop ++ right_loop)
    |> Enum.uniq()
    |> Map.new(fn coord -> {coord, @iron} end)
    |> Map.put(@power_coord, @power)
    |> Map.put(@left_load, @load)
    |> Map.put(@right_load, @load)
  end

  defp rect({x1, y, z1}, {x2, y, z2}) do
    (line({x1, y, z1}, {x2, y, z1}) ++
       line({x2, y, z1}, {x2, y, z2}) ++
       line({x2, y, z2}, {x1, y, z2}) ++
       line({x1, y, z2}, {x1, y, z1}))
    |> Enum.uniq()
  end

  defp line({x, y, z}, {x, y, z}), do: [{x, y, z}]
  defp line({x1, y, z}, {x2, y, z}), do: for(x <- axis_range(x1, x2), do: {x, y, z})
  defp line({x, y, z1}, {x, y, z2}), do: for(z <- axis_range(z1, z2), do: {x, y, z})
  defp axis_range(first, last) when first <= last, do: first..last
  defp axis_range(first, last), do: first..last//-1

  defp break_left_ring!(target, lease) do
    apply_intents!(target, [
      %{
        logical_scene_id: @logical_scene_id,
        chunk_coord: @chunk,
        lease: lease,
        operation: :break_block,
        macro: @break_coord
      }
    ])
  end

  defp apply_intents!(target, intents) do
    case rpc!(target, GenServer, :call, [
           SceneServer.Voxel.ChunkDirectory,
           {:apply_intents, intents},
           60_000
         ]) do
      {:ok, reply} -> reply
      {:error, reason} -> raise "apply_intents failed: #{inspect(reason)}"
    end
  end

  defp trigger_auto_circuit!(target, lease) do
    case rpc!(target, SceneServer.Voxel.Field.DevFieldCreate, :auto_circuit, [
           [
             logical_scene_id: @logical_scene_id,
             world_macro: world_coord(@power_coord),
             lease: lease,
             ttl_ticks: 12_000
           ]
         ]) do
      {:ok, summary} -> summary
      {:error, reason} -> raise "auto_circuit failed: #{inspect(reason)}"
    end
  end

  defp collect_current!(target) do
    {:ok, chunk_pid} =
      rpc!(target, SceneServer.Voxel.ChunkDirectory, :lookup_chunk_pid, [
        @logical_scene_id,
        @chunk
      ])

    debug = rpc!(target, :sys, :get_state, [chunk_pid])
    source_key = {:auto_circuit, @logical_scene_id, @chunk}
    region_id = Map.fetch!(debug.field_region_sources, source_key)
    worker_pid = Map.fetch!(debug.field_regions, region_id)
    worker_state = rpc!(target, :sys, :get_state, [worker_pid])
    region = worker_state.region

    current_layer =
      rpc!(target, SceneServer.Voxel.Field.FieldRegion, :get_layer, [region, :electric_current])

    active =
      rpc!(target, SceneServer.Voxel.Field.FieldLayer, :active_cells, [
        current_layer,
        region.aabb,
        0.001
      ])

    samples =
      Map.new([@power_coord, @left_probe, @right_probe, @break_coord], fn coord ->
        index = rpc!(target, SceneServer.Voxel.Types, :macro_index!, [coord])
        value = rpc!(target, SceneServer.Voxel.Field.FieldLayer, :get, [current_layer, index])
        {coord_name(coord), value}
      end)

    %{
      region_id: region_id,
      tick_count: region.tick_count,
      active_current_cells: length(active),
      sample_current_amps: samples
    }
  end

  defp coord_name(@power_coord), do: :power_crossing
  defp coord_name(@left_probe), do: :left_ring_load
  defp coord_name(@right_probe), do: :right_ring_load
  defp coord_name(@break_coord), do: :broken_block
  defp coord_name(coord), do: coord

  defp summarize_auto(summary) do
    %{
      created: Map.get(summary, :created),
      reason: Map.get(summary, :reason),
      closed_circuit_count: Map.get(summary, :closed_circuit_count),
      source_count: Map.get(summary, :source_count),
      load_count: Map.get(summary, :load_count),
      region_id: Map.get(summary, :region_id)
    }
  end

  defp summary_text(result) do
    "figure_eight_power_crossing=ok before_closed=#{result.before.auto_circuit.closed_circuit_count} after_closed=#{result.after.auto_circuit.closed_circuit_count} after_left_current=#{format_float(result.after.current.sample_current_amps.left_ring_load)} after_right_current=#{format_float(result.after.current.sample_current_amps.right_ring_load)}"
  end

  defp probe_text(probe) do
    auto = probe.auto_circuit
    current = probe.current

    "closed=#{auto.closed_circuit_count} active_current_cells=#{current.active_current_cells} power=#{format_float(current.sample_current_amps.power_crossing)} left=#{format_float(current.sample_current_amps.left_ring_load)} right=#{format_float(current.sample_current_amps.right_ring_load)} broken=#{format_float(current.sample_current_amps.broken_block)}"
  end

  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_float(value), do: inspect(value)
  defp coord_list({x, y, z}), do: [x, y, z]

  defp world_coord({x, y, z}) do
    {cx, cy, cz} = @chunk
    {cx * 16 + x, cy * 16 + y, cz * 16 + z}
  end

  defp rpc!(target, module, function, args) do
    case :rpc.call(target, module, function, args, 30_000) do
      {:badrpc, reason} ->
        raise "rpc #{inspect(module)}.#{function}/#{length(args)} failed: #{inspect(reason)}"

      other ->
        other
    end
  end
end

defmodule JsonLike do
  @moduledoc false

  def encode!(value) when is_map(value) do
    value =
      if Map.has_key?(value, :__struct__) do
        Map.delete(value, :__struct__)
      else
        value
      end

    entries =
      value
      |> Enum.map(fn {key, item} -> encode_key(key) <> ":" <> encode!(item) end)
      |> Enum.join(",")

    "{" <> entries <> "}"
  end

  def encode!(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &encode!/1) <> "]"
  def encode!(true), do: "true"
  def encode!(false), do: "false"
  def encode!(nil), do: "null"
  def encode!(value) when is_tuple(value), do: value |> Tuple.to_list() |> encode!()
  def encode!(value) when is_atom(value), do: encode!(Atom.to_string(value))
  def encode!(value) when is_binary(value), do: inspect(value)
  def encode!(value) when is_integer(value), do: Integer.to_string(value)
  def encode!(value) when is_float(value), do: Float.to_string(value)

  defp encode_key(key) when is_atom(key), do: encode!(Atom.to_string(key))
  defp encode_key(key), do: encode!(to_string(key))
end

FigureEightPowerCrossingProbe.run(System.argv())
