defmodule CircuitPlaygroundSeed do
  @moduledoc false

  @default_logical_scene_id 1
  @default_region_id 1_000_001
  @owner_scene_instance_ref 1
  @bounds_min {-2, -2, -2}
  @bounds_max {3, 3, 3}
  @lease_ttl_ms :timer.hours(6)
  @chunks [{0, 0, 0}, {1, 0, 0}, {0, 0, 1}, {1, 0, 1}]
  @clear_layers 1..6

  @platform 1
  @iron 5
  @power 6
  @load 7

  def run(argv) do
    opts = parse!(argv)
    target = connect_target!(opts)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    lease_ttl_ms = Keyword.fetch!(opts, :lease_ttl_ms)

    region = ensure_playground_region!(target, logical_scene_id, lease_ttl_ms)
    routes = route_chunks!(target, logical_scene_id)
    apply_route_leases!(target, routes)

    scenarios = scenarios()
    validate_scenarios!(scenarios)

    writes =
      @chunks
      |> Enum.map(fn chunk_coord ->
        route = Map.fetch!(routes, chunk_coord)
        chunk_scenarios = Enum.filter(scenarios, &(&1.chunk == chunk_coord))
        intents = chunk_intents(logical_scene_id, chunk_coord, route.lease, chunk_scenarios)
        reply = apply_intents!(target, chunk_coord, intents)

        %{
          chunk: coord_list(chunk_coord),
          scenario_ids: Enum.map(chunk_scenarios, & &1.id),
          scenario_count: length(chunk_scenarios),
          expected_active_circuits: Enum.count(chunk_scenarios, &(&1.expected == :active)),
          attempted: length(intents),
          changed_count: Map.get(reply, :changed_count, 0),
          skipped_count: Map.get(reply, :skipped_count, 0),
          chunk_version: Map.get(reply, :chunk_version, 0)
        }
      end)

    auto_circuits =
      @chunks
      |> Enum.map(fn chunk_coord ->
        route = Map.fetch!(routes, chunk_coord)
        expected = expected_active_for_chunk(scenarios, chunk_coord)
        summary = trigger_auto_circuit!(target, logical_scene_id, chunk_coord, route.lease)

        %{
          chunk: coord_list(chunk_coord),
          expected_active_circuits: expected,
          created: Map.get(summary, :created, false),
          reason: Map.get(summary, :reason),
          closed_circuit_count: Map.get(summary, :closed_circuit_count, 0),
          source_count: Map.get(summary, :source_count, 0),
          load_count: Map.get(summary, :load_count, 0),
          region_id: Map.get(summary, :region_id)
        }
      end)

    result = %{
      status: :ok,
      target_node: target,
      logical_scene_id: logical_scene_id,
      region: region,
      material_ids: %{platform: @platform, conductor: @iron, power: @power, load: @load},
      scenarios: Enum.map(scenarios, &summarize_scenario/1),
      writes: writes,
      auto_circuits: auto_circuits,
      totals: %{
        chunks: length(@chunks),
        scenarios: length(scenarios),
        expected_active_circuits: Enum.count(scenarios, &(&1.expected == :active)),
        expected_inactive_shapes: Enum.count(scenarios, &(&1.expected != :active))
      }
    }

    IO.puts(summary_text(result))
    Enum.each(result.scenarios, fn scenario -> IO.puts(scenario_text(scenario)) end)
    Enum.each(result.auto_circuits, fn summary -> IO.puts(auto_circuit_text(summary)) end)
    IO.puts("circuit_playground_json=#{JsonLike.encode!(result)}")
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
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @lease_ttl_ms)
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
      raise "cannot connect to #{inspect(target)}; confirm the dev server is running with the same ERLANG_COOKIE and ERL_EPMD_PORT"
    end
  end

  defp validate_target_name!(target_name) do
    expected = default_target_node()

    unless target_name == expected do
      raise "refusing target node #{inspect(target_name)}; expected #{inspect(expected)} from NODE_NAME/COMPUTERNAME"
    end
  end

  defp ensure_playground_region!(target, logical_scene_id, lease_ttl_ms) do
    existing =
      rpc!(target, WorldServer.Voxel.MapLedger, :route_chunk_with_lease, [
        WorldServer.Voxel.MapLedger,
        logical_scene_id,
        {0, 0, 0}
      ])

    owner_epoch = next_owner_epoch(existing)

    {:ok, assignment} =
      rpc!(target, WorldServer.Voxel.MapLedger, :put_region, [
        WorldServer.Voxel.MapLedger,
        %{
          logical_scene_id: logical_scene_id,
          region_id: region_id(logical_scene_id),
          bounds_chunk_min: @bounds_min,
          bounds_chunk_max: @bounds_max,
          owner_scene_instance_ref: @owner_scene_instance_ref,
          owner_epoch: owner_epoch,
          assigned_scene_node: target
        }
      ])

    {:ok, lease} =
      rpc!(target, WorldServer.Voxel.MapLedger, :issue_lease, [
        WorldServer.Voxel.MapLedger,
        assignment.region_id,
        @owner_scene_instance_ref,
        [owner_epoch: owner_epoch, ttl_ms: lease_ttl_ms, token_version: owner_epoch]
      ])

    %{
      region_id: assignment.region_id,
      bounds_chunk_min: coord_list(assignment.bounds_chunk_min),
      bounds_chunk_max: coord_list(assignment.bounds_chunk_max),
      lease_id: lease.lease_id,
      owner_epoch: lease.owner_epoch
    }
  end

  defp region_id(@default_logical_scene_id), do: @default_region_id
  defp region_id(logical_scene_id), do: logical_scene_id * 1_000_000 + 1

  defp next_owner_epoch({:ok, %{lease: lease}}), do: lease.owner_epoch + 1
  defp next_owner_epoch(_missing), do: 1

  defp route_chunks!(target, logical_scene_id) do
    case rpc!(target, WorldServer.Voxel.MapLedger, :route_chunks_with_leases, [
           WorldServer.Voxel.MapLedger,
           logical_scene_id,
           @chunks
         ]) do
      {:ok, routes} -> routes
      {:error, reason} -> raise "failed to route playground chunks: #{inspect(reason)}"
    end
  end

  defp apply_route_leases!(target, routes) do
    routes
    |> Map.values()
    |> Enum.map(& &1.lease)
    |> Enum.uniq_by(&{&1.region_id, &1.lease_id})
    |> Enum.each(fn lease ->
      {:ok, _lease} = rpc!(target, SceneServer.Voxel.RegionRuntime, :apply_lease, [lease])
    end)
  end

  defp chunk_intents(logical_scene_id, chunk_coord, lease, chunk_scenarios) do
    clear_intents(logical_scene_id, chunk_coord, lease) ++
      platform_intents(logical_scene_id, chunk_coord, lease) ++
      scenario_intents(logical_scene_id, chunk_coord, lease, chunk_scenarios)
  end

  defp clear_intents(logical_scene_id, chunk_coord, lease) do
    for y <- @clear_layers,
        x <- 0..15,
        z <- 0..15 do
      %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :break_block,
        macro: {x, y, z}
      }
    end
  end

  defp platform_intents(logical_scene_id, chunk_coord, lease) do
    for x <- 0..15,
        z <- 0..15 do
      put_intent(logical_scene_id, chunk_coord, lease, {x, 0, z}, @platform)
    end
  end

  defp scenario_intents(logical_scene_id, chunk_coord, lease, chunk_scenarios) do
    chunk_scenarios
    |> Enum.flat_map(& &1.cells)
    |> Enum.map(fn {local_macro, material_id} ->
      put_intent(logical_scene_id, chunk_coord, lease, local_macro, material_id)
    end)
  end

  defp put_intent(logical_scene_id, chunk_coord, lease, local_macro, material_id) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      lease: lease,
      operation: :put_solid_block,
      macro: local_macro,
      block: %{material_id: material_id, health: 100}
    }
  end

  defp apply_intents!(target, chunk_coord, intents) do
    reply =
      rpc!(target, GenServer, :call, [
        SceneServer.Voxel.ChunkDirectory,
        {:apply_intents, intents},
        60_000
      ])

    case reply do
      {:ok, applied} -> applied
      {:error, reason} -> raise "failed to seed #{inspect(chunk_coord)}: #{inspect(reason)}"
    end
  end

  defp trigger_auto_circuit!(target, logical_scene_id, {cx, cy, cz} = _chunk_coord, lease) do
    world_macro = {cx * 16 + 1, cy * 16 + 2, cz * 16 + 1}

    case rpc!(target, SceneServer.Voxel.Field.DevFieldCreate, :auto_circuit, [
           [
             logical_scene_id: logical_scene_id,
             world_macro: world_macro,
             lease: lease,
             ttl_ticks: 12_000
           ]
         ]) do
      {:ok, summary} ->
        summary

      {:error, reason} ->
        raise "auto circuit failed for #{inspect(world_macro)}: #{inspect(reason)}"
    end
  end

  defp scenarios do
    [
      scenario("C01", "simple_closed_loop", {0, 0, 0}, :active, simple_loop()),
      scenario("C02", "open_source_load_path", {0, 0, 0}, :inactive, open_path()),
      scenario("C03", "closed_loop_with_dangling_branch", {0, 0, 0}, :active, dangling_branch()),
      scenario("C04", "power_only_closed_loop", {0, 0, 0}, :inactive, power_only_loop()),
      scenario("C05", "parallel_ladder", {1, 0, 0}, :active, parallel_ladder()),
      scenario("C06", "short_bypass_candidate", {1, 0, 0}, :active, short_bypass()),
      scenario("C07", "series_loads_on_one_loop", {1, 0, 0}, :active, series_loads()),
      scenario("C08", "load_only_closed_loop", {1, 0, 0}, :inactive, load_only_loop()),
      scenario("C09", "figure_eight_shared_leg", {0, 0, 1}, :active, figure_eight()),
      scenario("C10", "nested_mesh_loop", {0, 0, 1}, :active, nested_mesh()),
      scenario("C11", "vertical_via_loop", {0, 0, 1}, :active, vertical_via_loop()),
      scenario("C12", "broken_u_shape", {0, 0, 1}, :inactive, broken_u()),
      scenario("C13", "dense_grid_mesh", {1, 0, 1}, :active, dense_grid()),
      scenario("C14", "source_load_tree_no_cycle", {1, 0, 1}, :inactive, tree_no_cycle()),
      scenario("C15", "chunk_edge_loop", {1, 0, 1}, :active, edge_loop()),
      scenario("C16", "double_source_double_load_loop", {1, 0, 1}, :active, double_source_load())
    ]
  end

  defp scenario(id, name, chunk, expected, cells) do
    %{
      id: id,
      name: name,
      chunk: chunk,
      expected: expected,
      cells: Map.to_list(cells)
    }
  end

  defp simple_loop do
    rect(1, 4, 2, 1, 4)
    |> with_roles({1, 2, 1}, [{4, 2, 4}])
  end

  defp open_path do
    line({7, 2, 1}, {12, 2, 1})
    |> with_roles({7, 2, 1}, [{12, 2, 1}])
  end

  defp dangling_branch do
    (rect(1, 5, 2, 8, 12) ++ line({5, 2, 10}, {8, 2, 10}))
    |> with_roles({1, 2, 8}, [{5, 2, 12}])
  end

  defp power_only_loop do
    rect(10, 14, 2, 8, 12)
    |> as_material(@iron)
    |> Map.put({10, 2, 8}, @power)
  end

  defp parallel_ladder do
    (line({1, 2, 1}, {6, 2, 1}) ++
       line({1, 2, 5}, {6, 2, 5}) ++
       line({1, 2, 1}, {1, 2, 5}) ++
       line({3, 2, 1}, {3, 2, 5}) ++
       line({6, 2, 1}, {6, 2, 5}))
    |> with_roles({1, 2, 1}, [{6, 2, 5}])
  end

  defp short_bypass do
    (rect(9, 14, 2, 1, 5) ++ line({9, 2, 3}, {14, 2, 3}))
    |> with_roles({9, 2, 3}, [{12, 2, 5}])
  end

  defp series_loads do
    rect(1, 6, 2, 9, 13)
    |> with_roles({1, 2, 9}, [{3, 2, 9}, {6, 2, 13}])
  end

  defp load_only_loop do
    rect(10, 14, 2, 9, 13)
    |> with_roles(nil, [{10, 2, 9}, {14, 2, 13}])
  end

  defp figure_eight do
    (rect(1, 4, 2, 1, 7) ++ rect(4, 7, 2, 1, 7))
    |> with_roles({1, 2, 1}, [{7, 2, 7}])
  end

  defp nested_mesh do
    (rect(10, 14, 2, 1, 6) ++
       rect(11, 13, 2, 2, 5) ++
       line({12, 2, 1}, {12, 2, 6}) ++
       line({10, 2, 3}, {14, 2, 3}))
    |> with_roles({10, 2, 1}, [{14, 2, 6}, {12, 2, 5}])
  end

  defp vertical_via_loop do
    (line({1, 2, 10}, {5, 2, 10}) ++
       line({5, 2, 10}, {5, 4, 10}) ++
       line({5, 4, 10}, {1, 4, 10}) ++
       line({1, 4, 10}, {1, 2, 10}))
    |> with_roles({1, 2, 10}, [{5, 4, 10}])
  end

  defp broken_u do
    (line({10, 2, 10}, {14, 2, 10}) ++
       line({14, 2, 10}, {14, 2, 14}) ++
       line({14, 2, 14}, {10, 2, 14}))
    |> with_roles({10, 2, 10}, [{10, 2, 14}])
  end

  defp dense_grid do
    verticals = Enum.flat_map([1, 3, 5, 7], &line({&1, 2, 1}, {&1, 2, 7}))
    horizontals = Enum.flat_map([1, 3, 5, 7], &line({1, 2, &1}, {7, 2, &1}))

    (verticals ++ horizontals)
    |> with_roles({1, 2, 1}, [{7, 2, 7}])
  end

  defp tree_no_cycle do
    (line({10, 2, 1}, {10, 2, 6}) ++
       line({10, 2, 3}, {14, 2, 3}) ++
       line({10, 2, 5}, {13, 2, 5}))
    |> with_roles({10, 2, 1}, [{14, 2, 3}])
  end

  defp edge_loop do
    rect(12, 15, 2, 9, 13)
    |> with_roles({15, 2, 9}, [{12, 2, 13}])
  end

  defp double_source_load do
    (rect(1, 7, 2, 10, 14) ++ line({1, 2, 12}, {7, 2, 12}))
    |> with_roles({1, 2, 10}, [{7, 2, 10}, {1, 2, 14}])
    |> Map.put({7, 2, 14}, @power)
  end

  defp rect(x1, x2, y, z1, z2) do
    (line({x1, y, z1}, {x2, y, z1}) ++
       line({x2, y, z1}, {x2, y, z2}) ++
       line({x2, y, z2}, {x1, y, z2}) ++
       line({x1, y, z2}, {x1, y, z1}))
    |> Enum.uniq()
  end

  defp line({x, y, z}, {x, y, z}), do: [{x, y, z}]

  defp line({x1, y, z}, {x2, y, z}) when x1 != x2 do
    for x <- axis_range(x1, x2), do: {x, y, z}
  end

  defp line({x, y1, z}, {x, y2, z}) when y1 != y2 do
    for y <- axis_range(y1, y2), do: {x, y, z}
  end

  defp line({x, y, z1}, {x, y, z2}) when z1 != z2 do
    for z <- axis_range(z1, z2), do: {x, y, z}
  end

  defp line(from, to),
    do: raise("only axis-aligned lines are supported: #{inspect(from)} -> #{inspect(to)}")

  defp axis_range(first, last) when first <= last, do: first..last
  defp axis_range(first, last), do: first..last//-1

  defp with_roles(cells, source, loads) do
    cells
    |> as_material(@iron)
    |> maybe_put_source(source)
    |> put_loads(loads)
  end

  defp maybe_put_source(map, nil), do: map
  defp maybe_put_source(map, coord), do: Map.put(map, coord, @power)

  defp put_loads(map, loads) do
    Enum.reduce(loads, map, fn coord, acc -> Map.put(acc, coord, @load) end)
  end

  defp as_material(cells, material_id) do
    Map.new(cells, fn coord -> {coord, material_id} end)
  end

  defp validate_scenarios!(scenarios) do
    Enum.each(scenarios, fn scenario ->
      Enum.each(scenario.cells, fn {{x, y, z}, material_id} ->
        unless x in 0..15 and y in 0..15 and z in 0..15 do
          raise "#{scenario.id} has out-of-chunk coord #{inspect({x, y, z})}"
        end

        unless material_id in [@iron, @power, @load] do
          raise "#{scenario.id} has unsupported material #{inspect(material_id)}"
        end
      end)
    end)

    scenarios
    |> Enum.group_by(& &1.chunk)
    |> Enum.each(fn {chunk, chunk_scenarios} ->
      seen =
        Enum.reduce(chunk_scenarios, %{}, fn scenario, acc ->
          Enum.reduce(scenario.cells, acc, fn {coord, material_id}, inner ->
            case Map.fetch(inner, coord) do
              {:ok, {other_id, other_material}} when other_material != material_id ->
                raise "cell conflict in chunk #{inspect(chunk)} at #{inspect(coord)}: #{other_id} vs #{scenario.id}"

              {:ok, _same} ->
                inner

              :error ->
                Map.put(inner, coord, {scenario.id, material_id})
            end
          end)
        end)

      if map_size(seen) == 0 do
        raise "chunk #{inspect(chunk)} has no scenario cells"
      end
    end)
  end

  defp expected_active_for_chunk(scenarios, chunk_coord) do
    scenarios
    |> Enum.filter(&(&1.chunk == chunk_coord and &1.expected == :active))
    |> length()
  end

  defp summarize_scenario(scenario) do
    %{
      id: scenario.id,
      name: scenario.name,
      chunk: coord_list(scenario.chunk),
      expected: scenario.expected,
      block_count: length(scenario.cells)
    }
  end

  defp summary_text(result) do
    totals = result.totals

    "circuit_playground=ok target=#{result.target_node} chunks=#{totals.chunks} scenarios=#{totals.scenarios} expected_active=#{totals.expected_active_circuits} expected_inactive=#{totals.expected_inactive_shapes}"
  end

  defp scenario_text(scenario) do
    "scenario=#{scenario.id} name=#{scenario.name} chunk=#{Enum.join(scenario.chunk, ",")} expected=#{scenario.expected} blocks=#{scenario.block_count}"
  end

  defp auto_circuit_text(summary) do
    "auto_circuit chunk=#{Enum.join(summary.chunk, ",")} created=#{summary.created} closed=#{summary.closed_circuit_count} expected=#{summary.expected_active_circuits} sources=#{summary.source_count} loads=#{summary.load_count} reason=#{summary.reason || "none"}"
  end

  defp coord_list({x, y, z}), do: [x, y, z]

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

  def encode!(value) when is_list(value) do
    "[" <> (value |> Enum.map(&encode!/1) |> Enum.join(",")) <> "]"
  end

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

CircuitPlaygroundSeed.run(System.argv())
