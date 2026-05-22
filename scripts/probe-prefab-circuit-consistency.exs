defmodule PrefabCircuitConsistencyProbe do
  @moduledoc false

  @logical_scene_id 1
  @chunk {-2, 0, 0}
  @region_id 1_000_002
  @owner_ref 1
  @bounds_min {-4, -2, -2}
  @bounds_max {3, 3, 3}
  @lease_ttl_ms :timer.hours(6)

  @iron 5
  @power 6
  @load 7

  @wire_x 4
  @junction_xz 5
  @power_terminal_x 6
  @load_terminal_x 7
  @blueprint_version 2

  @y 5
  @source {6, @y, 4}
  @load_coord {6, @y, 8}

  def run(argv) do
    opts = parse!(argv)
    target = connect_target!(opts)
    lease = ensure_region_and_lease!(target)
    apply_lease!(target, lease)

    scenarios = scenarios(target)
    results = Enum.map(scenarios, &run_scenario!(target, lease, &1))

    failures = Enum.reject(results, & &1.verdict.pass?)

    IO.puts("prefab_circuit_consistency=#{if failures == [], do: "ok", else: "failed"}")
    Enum.each(results, &IO.puts(scenario_text(&1)))
    IO.puts("prefab_circuit_consistency_json=#{JsonLike.encode!(%{results: results})}")

    if failures == [] do
      maybe_leave_scenario!(target, lease, scenarios, Keyword.get(opts, :leave_scenario))
    end

    if failures != [] do
      failed = Enum.map_join(failures, ",", & &1.name)
      raise "prefab circuit consistency failed: #{failed}"
    end
  end

  defp parse!(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv, switches: [target_node: :string, leave_scenario: :string])

    if invalid != [] do
      raise "invalid options: #{inspect(invalid)}"
    end

    [
      target_node: Keyword.get(opts, :target_node, default_target_node()),
      leave_scenario: Keyword.get(opts, :leave_scenario)
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

    case existing do
      {:ok, %{lease: lease}} ->
        lease

      _missing ->
        create_probe_region_lease!(target)
    end
  end

  defp create_probe_region_lease!(target) do
    {:ok, assignment} =
      rpc!(target, WorldServer.Voxel.MapLedger, :put_region, [
        WorldServer.Voxel.MapLedger,
        %{
          logical_scene_id: @logical_scene_id,
          region_id: @region_id,
          bounds_chunk_min: @bounds_min,
          bounds_chunk_max: @bounds_max,
          owner_scene_instance_ref: @owner_ref,
          owner_epoch: 1,
          assigned_scene_node: target
        }
      ])

    {:ok, lease} =
      rpc!(target, WorldServer.Voxel.MapLedger, :issue_lease, [
        WorldServer.Voxel.MapLedger,
        assignment.region_id,
        @owner_ref,
        [owner_epoch: 1, ttl_ms: @lease_ttl_ms, token_version: 1]
      ])

    lease
  end

  defp apply_lease!(target, lease) do
    {:ok, _lease} = rpc!(target, SceneServer.Voxel.RegionRuntime, :apply_lease, [lease])
    :ok
  end

  defp scenarios(target) do
    solid_loop = rect_loop()
    horizontal_wire_slots = slot_count!(target, @wire_x)
    junction_slots = slot_count!(target, @junction_xz)
    terminal_slots = slot_count!(target, @power_terminal_x)

    [
      %{
        name: :macro_solid_loop,
        kind: :solid,
        description: "pure macro solid loop",
        placements:
          solid_loop
          |> Map.new(fn coord -> {coord, @iron} end)
          |> Map.put(@source, @power)
          |> Map.put(@load_coord, @load),
        expected: expected_active(solid_loop, 0)
      },
      %{
        name: :prefab_junction_loop,
        kind: :prefab,
        description: "pure prefab loop using x/z junctions on corners and vertical runs",
        placements: prefab_junction_loop(),
        expected:
          expected_active(
            solid_loop,
            terminal_slots * 2 + horizontal_wire_slots * 4 + junction_slots * 10
          )
      },
      %{
        name: :prefab_rotated_wire_loop,
        kind: :prefab,
        description: "prefab loop using rotated x-wires for z-axis sides",
        placements: prefab_rotated_wire_loop(),
        expected:
          expected_active(
            solid_loop,
            terminal_slots * 2 + horizontal_wire_slots * 10 + junction_slots * 4
          )
      },
      %{
        name: :mixed_macro_prefab_loop,
        kind: :mixed,
        description: "solid macro conductors connected to prefab source/load terminals",
        placements: mixed_macro_prefab_loop(),
        expected: expected_active(solid_loop, terminal_slots * 2)
      },
      %{
        name: :unrotated_prefab_z_gap,
        kind: :negative,
        description: "unrotated x-wires placed on z-axis sides should remain electrically open",
        placements: prefab_unrotated_z_gap(),
        expected: expected_inactive()
      }
    ]
  end

  defp expected_active(loop_coords, micro_slots) do
    %{
      should_conduct?: true,
      closed_components: 1,
      active_macro_cells: length(loop_coords),
      expected_micro_current_slots: micro_slots,
      expected_reason: nil,
      energized_coords: Enum.map(loop_coords, &coord_list(world_coord(&1)))
    }
  end

  defp expected_inactive do
    %{
      should_conduct?: false,
      closed_components: 0,
      active_macro_cells: 0,
      expected_micro_current_slots: 0,
      expected_reason: :no_closed_circuit,
      energized_coords: []
    }
  end

  defp run_scenario!(target, lease, scenario) do
    clear_chunk!(target, lease)
    apply_intents!(target, intents_for_placements!(target, lease, scenario.placements))
    auto = trigger_auto_circuit!(target, lease)
    Process.sleep(350)
    current = collect_current!(target, scenario)
    verdict = verdict(scenario.expected, auto, current)

    %{
      name: scenario.name,
      kind: scenario.kind,
      description: scenario.description,
      expected: scenario.expected,
      auto_circuit: summarize_auto(auto),
      current: current,
      verdict: verdict
    }
  end

  defp maybe_leave_scenario!(_target, _lease, _scenarios, nil), do: :ok

  defp maybe_leave_scenario!(target, lease, scenarios, name) do
    scenario =
      Enum.find(scenarios, fn scenario ->
        Atom.to_string(scenario.name) == name
      end) || raise "unknown scenario for --leave-scenario: #{inspect(name)}"

    clear_chunk!(target, lease)
    apply_intents!(target, intents_for_placements!(target, lease, scenario.placements))
    auto = trigger_auto_circuit!(target, lease)
    Process.sleep(350)
    current = collect_current!(target, scenario)

    IO.puts(
      "left_scenario=#{scenario_text(%{name: scenario.name, kind: scenario.kind, description: scenario.description, expected: scenario.expected, auto_circuit: summarize_auto(auto), current: current, verdict: verdict(scenario.expected, auto, current)})}"
    )
  end

  defp clear_chunk!(target, lease) do
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

    apply_intents!(target, clear)
  end

  defp intents_for_placements!(target, lease, placements) when is_map(placements) do
    placements
    |> Enum.flat_map(fn
      {coord, material_id} when is_integer(material_id) ->
        [
          %{
            logical_scene_id: @logical_scene_id,
            chunk_coord: @chunk,
            lease: lease,
            operation: :put_solid_block,
            macro: coord,
            block: %{material_id: material_id, health: 100}
          }
        ]

      {coord, {:prefab, blueprint_id, rotation, owner_object_id}} ->
        prefab_intents!(target, lease, coord, blueprint_id, rotation, owner_object_id)
    end)
  end

  defp intents_for_placements!(target, lease, placements) when is_list(placements) do
    placements
    |> Enum.flat_map(fn
      {:solid, coord, material_id} ->
        intents_for_placements!(target, lease, %{coord => material_id})

      {:prefab, coord, blueprint_id, rotation, owner_object_id} ->
        prefab_intents!(target, lease, coord, blueprint_id, rotation, owner_object_id)
    end)
  end

  defp prefab_intents!(target, lease, coord, blueprint_id, rotation, owner_object_id) do
    {:ok, cells} =
      rpc!(target, SceneServer.Voxel.PrefabRaster, :rasterize, [
        blueprint_id,
        @blueprint_version,
        coord |> world_coord() |> world_micro_anchor(),
        rotation,
        [owner_object_id: owner_object_id, owner_part_id: 1]
      ])

    Enum.map(cells, fn cell ->
      %{
        logical_scene_id: @logical_scene_id,
        chunk_coord: cell.chunk_coord,
        lease: lease,
        operation: :put_micro_block,
        macro: cell.local_macro,
        micro_slot: cell.micro_slot,
        micro_layer: cell.layer_attrs
      }
    end)
  end

  defp trigger_auto_circuit!(target, lease) do
    case rpc!(target, SceneServer.Voxel.Field.DevFieldCreate, :auto_circuit, [
           [
             logical_scene_id: @logical_scene_id,
             world_macro: world_coord(@source),
             lease: lease,
             ttl_ticks: 12_000
           ]
         ]) do
      {:ok, summary} -> summary
      {:error, reason} -> raise "auto_circuit failed: #{inspect(reason)}"
    end
  end

  defp collect_current!(target, scenario) do
    {:ok, chunk_pid} =
      rpc!(target, SceneServer.Voxel.ChunkDirectory, :lookup_chunk_pid, [
        @logical_scene_id,
        @chunk
      ])

    debug = rpc!(target, :sys, :get_state, [chunk_pid])

    projection =
      rpc!(target, SceneServer.Voxel.Field.ParticipantProjection, :build, [debug.storage])

    source_key = {:auto_circuit, @logical_scene_id, @chunk}
    source_samples = [@source, @load_coord]

    case Map.fetch(debug.field_region_sources, source_key) do
      :error ->
        zero_current_summary(target, projection, source_samples)

      {:ok, region_id} ->
        worker_pid = Map.fetch!(debug.field_regions, region_id)
        worker_state = rpc!(target, :sys, :get_state, [worker_pid])
        region = worker_state.region

        current_layer =
          rpc!(target, SceneServer.Voxel.Field.FieldRegion, :get_layer, [
            region,
            :electric_current
          ])

        active =
          rpc!(target, SceneServer.Voxel.Field.FieldLayer, :active_cells, [
            current_layer,
            region.aabb,
            0.001
          ])

        active_macro_coords =
          Enum.map(active, fn {macro_index, _value} ->
            target
            |> macro_coord!(macro_index)
            |> world_coord()
            |> coord_list()
          end)

        expected_local =
          scenario.expected.energized_coords
          |> Enum.map(&list_to_tuple/1)
          |> Enum.map(&local_coord/1)

        missing_expected_current =
          expected_local
          |> Enum.reject(fn coord ->
            index = rpc!(target, SceneServer.Voxel.Types, :macro_index!, [coord])

            Enum.any?(active, fn {active_index, _value} -> active_index == index end)
          end)
          |> Enum.map(&(world_coord(&1) |> coord_list()))

        samples =
          sample_current_values(target, current_layer, source_samples)

        %{
          region_id: region_id,
          tick_count: region.tick_count,
          active_current_cells: length(active),
          active_macro_coords: active_macro_coords,
          missing_expected_current: missing_expected_current,
          sample_current_amps: samples,
          projection: projection_summary(target, projection)
        }
    end
  end

  defp zero_current_summary(target, projection, sample_coords) do
    %{
      region_id: nil,
      tick_count: 0,
      active_current_cells: 0,
      active_macro_coords: [],
      missing_expected_current: [],
      sample_current_amps:
        Map.new(sample_coords, fn coord ->
          {coord_name(coord), 0.0}
        end),
      projection: projection_summary(target, projection)
    }
  end

  defp sample_current_values(target, current_layer, sample_coords) do
    Map.new(sample_coords, fn coord ->
      index = rpc!(target, SceneServer.Voxel.Types, :macro_index!, [coord])
      value = rpc!(target, SceneServer.Voxel.Field.FieldLayer, :get, [current_layer, index])
      {coord_name(coord), value}
    end)
  end

  defp projection_summary(target, projection) do
    entries = Map.get(projection, :entries, %{})

    role_counts =
      Enum.reduce(entries, %{source: 0, load: 0, conductor: 0}, fn {macro_index, _entry}, acc ->
        roles =
          if is_nil(target) do
            MapSet.new()
          else
            rpc!(target, SceneServer.Voxel.Field.ParticipantProjection, :electric_roles, [
              projection,
              macro_index
            ])
          end

        acc
        |> maybe_increment_role(roles, :source)
        |> maybe_increment_role(roles, :load)
        |> maybe_increment_role(roles, :conductor)
      end)

    %{conductive_entries: map_size(entries), role_counts: role_counts}
  end

  defp maybe_increment_role(acc, roles, role) do
    if MapSet.member?(roles, role) do
      Map.update!(acc, role, &(&1 + 1))
    else
      acc
    end
  end

  defp verdict(expected, auto, current) do
    auto_summary = summarize_auto(auto)
    source_current = current.sample_current_amps.source
    load_current = current.sample_current_amps.load

    checks = %{
      reason: auto_summary.reason == expected.expected_reason,
      closed_components: auto_summary.closed_circuit_count == expected.closed_components,
      active_macro_cells: current.active_current_cells == expected.active_macro_cells,
      source_current: expected_current_state_matches?(expected.should_conduct?, source_current),
      load_current: expected_current_state_matches?(expected.should_conduct?, load_current),
      no_missing_expected_current: current.missing_expected_current == []
    }

    %{pass?: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp expected_current_state_matches?(true, value), do: abs(value) > 0.001
  defp expected_current_state_matches?(false, value), do: abs(value) <= 0.001

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

  defp scenario_text(result) do
    auto = result.auto_circuit
    current = result.current

    "#{result.name}=#{if result.verdict.pass?, do: "ok", else: "failed"} " <>
      "closed=#{auto.closed_circuit_count} reason=#{inspect(auto.reason)} " <>
      "active=#{current.active_current_cells}/#{result.expected.active_macro_cells} " <>
      "source=#{format_float(current.sample_current_amps.source)} " <>
      "load=#{format_float(current.sample_current_amps.load)} " <>
      "expected_micro_current_slots=#{result.expected.expected_micro_current_slots} " <>
      "missing=#{length(current.missing_expected_current)}"
  end

  defp rect_loop do
    (line({4, @y, 4}, {8, @y, 4}) ++
       line({8, @y, 4}, {8, @y, 8}) ++
       line({8, @y, 8}, {4, @y, 8}) ++
       line({4, @y, 8}, {4, @y, 4}))
    |> Enum.uniq()
  end

  defp prefab_junction_loop do
    base_prefab_loop()
    |> Map.merge(%{
      {4, @y, 5} => prefab(@junction_xz, 0, 205),
      {4, @y, 6} => prefab(@junction_xz, 0, 206),
      {4, @y, 7} => prefab(@junction_xz, 0, 207),
      {8, @y, 5} => prefab(@junction_xz, 0, 208),
      {8, @y, 6} => prefab(@junction_xz, 0, 209),
      {8, @y, 7} => prefab(@junction_xz, 0, 210)
    })
  end

  defp prefab_rotated_wire_loop do
    base_prefab_loop()
    |> Map.merge(%{
      {4, @y, 5} => prefab(@wire_x, 1, 305),
      {4, @y, 6} => prefab(@wire_x, 1, 306),
      {4, @y, 7} => prefab(@wire_x, 1, 307),
      {8, @y, 5} => prefab(@wire_x, 1, 308),
      {8, @y, 6} => prefab(@wire_x, 1, 309),
      {8, @y, 7} => prefab(@wire_x, 1, 310)
    })
  end

  defp prefab_unrotated_z_gap do
    base_prefab_loop()
    |> Map.merge(%{
      {4, @y, 5} => prefab(@wire_x, 0, 405),
      {4, @y, 6} => prefab(@wire_x, 0, 406),
      {4, @y, 7} => prefab(@wire_x, 0, 407),
      {8, @y, 5} => prefab(@wire_x, 0, 408),
      {8, @y, 6} => prefab(@wire_x, 0, 409),
      {8, @y, 7} => prefab(@wire_x, 0, 410)
    })
  end

  defp base_prefab_loop do
    %{
      @source => prefab(@power_terminal_x, 0, 200),
      @load_coord => prefab(@load_terminal_x, 0, 201),
      {5, @y, 4} => prefab(@wire_x, 0, 202),
      {7, @y, 4} => prefab(@wire_x, 0, 203),
      {5, @y, 8} => prefab(@wire_x, 0, 204),
      {7, @y, 8} => prefab(@wire_x, 0, 211),
      {4, @y, 4} => prefab(@junction_xz, 0, 212),
      {8, @y, 4} => prefab(@junction_xz, 0, 213),
      {4, @y, 8} => prefab(@junction_xz, 0, 214),
      {8, @y, 8} => prefab(@junction_xz, 0, 215)
    }
  end

  defp mixed_macro_prefab_loop do
    rect_loop()
    |> Map.new(fn coord -> {coord, @iron} end)
    |> Map.put(@source, prefab(@power_terminal_x, 0, 500))
    |> Map.put(@load_coord, prefab(@load_terminal_x, 0, 501))
  end

  defp prefab(blueprint_id, rotation, owner_object_id) do
    {:prefab, blueprint_id, rotation, owner_object_id}
  end

  defp line({x, y, z}, {x, y, z}), do: [{x, y, z}]
  defp line({x1, y, z}, {x2, y, z}), do: for(x <- axis_range(x1, x2), do: {x, y, z})
  defp line({x, y, z1}, {x, y, z2}), do: for(z <- axis_range(z1, z2), do: {x, y, z})
  defp axis_range(first, last) when first <= last, do: first..last
  defp axis_range(first, last), do: first..last//-1

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

  defp slot_count!(target, blueprint_id) do
    case rpc!(target, SceneServer.Voxel.BlueprintCatalog, :slot_count, [blueprint_id]) do
      count when is_integer(count) ->
        count

      other ->
        raise "missing blueprint slot count for #{inspect(blueprint_id)}: #{inspect(other)}"
    end
  end

  defp macro_coord!(target, macro_index) do
    rpc!(target, SceneServer.Voxel.Types, :macro_coord!, [macro_index])
  end

  defp coord_name(@source), do: :source
  defp coord_name(@load_coord), do: :load
  defp coord_name(coord), do: coord

  defp world_coord({x, y, z}) do
    {cx, cy, cz} = @chunk
    {cx * 16 + x, cy * 16 + y, cz * 16 + z}
  end

  defp local_coord({x, y, z}) do
    {cx, cy, cz} = @chunk
    {x - cx * 16, y - cy * 16, z - cz * 16}
  end

  defp world_micro_anchor({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp coord_list({x, y, z}), do: [x, y, z]
  defp list_to_tuple([x, y, z]), do: {x, y, z}

  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_float(value), do: inspect(value)

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

PrefabCircuitConsistencyProbe.run(System.argv())
