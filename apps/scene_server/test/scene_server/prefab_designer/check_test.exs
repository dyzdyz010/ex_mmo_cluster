defmodule SceneServer.PrefabDesigner.CheckTest do
  @moduledoc "只测试：手算草稿几何，不启动 World、模型、数据库或渲染器。"
  use ExUnit.Case, async: true
  alias SceneServer.PrefabDesigner.Check

  @properties %{attachments: %{"material_units_per_micro" => 10, "face_units" => 2, "edge_units" => 1}}
  @profile %{radius: 0.125, half_height: 0.875, step_height: 0.25}

  defp compiled(micros, macros \\ [], attachments \\ []) do
    %{nodes: [%{cells: :erlang.term_to_binary(micros), macro_cells: :erlang.term_to_binary(macros), attachments: attachments}]}
  end

  defp opts(extra \\ []) do
    Keyword.merge([profile: @profile, properties: @properties, bounds: {{-4, -1, 0}, {5, 24, 8}},
      entry: {-2, 0, 3}, inside: {2, 0, 3}, ground_y: 0, interiors: [],
      max_path_nodes: 10_000, max_scan_cells: 100_000], extra)
  end

  defp frame(width) do
    for y <- 0..19, z <- 0..7, not (y < 16 and z in width), do: {{0, y, z}, 19}
  end

  test "a real micro doorway is passable, but one micro of width is not" do
    assert {:ok, open} = Check.run(compiled(frame(2..5)), opts())
    assert {:ok, path} = open.route
    assert List.last(path) == {2, 0, 3}
    assert open.materials.units == %{19 => 960} # 20*8 - 16*4 = 96 个 micro，每个 10 单位。
    assert open.floating == %{status: :checked, macro_cells: [], micro_cells: []}
    assert {:ok, narrow} = Check.run(compiled(frame(3..3)), opts())
    assert narrow.route == :no_path
    assert Enum.any?(open.views.layers, &String.contains?(&1.text, "+"))
  end

  test "a floor placed at the requested feet and a low ceiling are distinct blocked designs" do
    assert {:ok, floor} = Check.run(compiled([], [{{0, 0, 0}, 11}]), opts())
    assert floor.route == :no_path
    assert floor.headroom.inside.clear_micro == 0
    assert floor.headroom.inside.status == :blocked

    assert {:ok, ceiling} = Check.run(compiled([], [{{0, 1, 0}, 11}]), opts())
    assert ceiling.route == :no_path
    assert ceiling.headroom.inside.clear_micro == 8
    assert ceiling.headroom.inside.metres == 1.0
  end

  test "upstairs goal locks its Y, and only actual stairs make it reachable" do
    slab = for x <- 8..10, z <- 0..2, do: {{x, 15, z}, 11}
    options = opts(profile: %{radius: 0.05, half_height: 0.875, step_height: 0.25},
      bounds: {{-2, -1, -1}, {12, 40, 4}}, entry: {-1, 0, 1}, inside: {9, 16, 1})
    assert {:ok, flat} = Check.run(compiled(slab), options)
    assert flat.route == :no_path
    steps = for x <- 0..7, y <- 0..(2*x+1), z <- 0..2, do: {{x, y, z}, 11}
    assert {:ok, stairs} = Check.run(compiled(slab ++ steps), options)
    assert {:ok, path} = stairs.route
    assert List.last(path) == {9, 16, 1}
  end

  test "explicit rooms determine roof coverage and exact clearance, including a micro hole" do
    roof = for x <- 1..3, z <- 2..4, {x,z} != {2,3}, do: {{x, 16, z}, 11}
    options = opts(interiors: [%{name: "room", floor_y: 0, min: {1,2}, max: {4,5}}])
    assert {:ok, report} = Check.run(compiled(roof), options)
    assert [%{covered_columns: 8, total_columns: 9, complete: false}] = report.roof
    assert [%{min_clear_micro: 16, open_to_bound_columns: 1}] = report.headroom.interiors
  end

  test "floating means not connected to supplied ground; attachment costs use published units" do
    attachments = [%{material: 19, slots: [{0, 1, {0, 0, 0}}, {1, 0, {0, 0, 0}}]}]
    definition = compiled([{{8,0,0},11}], [{{0,0,0},11}, {{2,2,0},11}], attachments)
    assert {:ok, report} = Check.run(definition, opts(bounds: {{-4,-1,-2},{32,32,10}}))
    assert report.materials.units == %{11 => 10_250, 19 => 3}
    assert report.floating == %{status: :checked, macro_cells: [{2,2,0}], micro_cells: []}
    assert {:ok, unknown} = Check.run(definition, opts(bounds: {{-4,-1,-2},{32,32,10}}, ground_y: nil))
    assert unknown.floating.status == :unknown
  end

  test "bounds are unknown and budgets cannot turn an incomplete check into success" do
    assert {:ok, report} = Check.run(compiled(frame(2..5)), opts(inside: {20,0,3}))
    assert report.route == :no_path
    assert report.headroom.inside.status == :unknown
    assert {:error, :check_budget} = Check.run(compiled(frame(2..5)), opts(max_scan_cells: 1))
    assert {:ok, limited} = Check.run(compiled(frame(2..5)), opts(max_path_nodes: 1))
    assert limited.route == {:error, :search_limit}
  end

  @tag :endpoint_diagnostic
  test "endpoint facts distinguish radius obstruction from an open center and show landing" do
    options = opts(profile: %{radius: 0.35,half_height: 0.9,step_height: 1.0},
      bounds: {{-8,-1,-8},{8,24,8}},entry: {0,0,0},inside: {-4,0,0})
    assert {:ok,blocked} = Check.run(compiled([{{3,0,0},11}]),options)
    assert blocked.route == :no_path
    assert blocked.endpoints.entry.position == %{standable: false,landed: nil}
    assert blocked.endpoints.entry.body == %{kind: :solid,cell: {3,0,0}}
    assert blocked.endpoints.entry.support.kind == :solid
    assert blocked.endpoints.inside.position == %{standable: true,landed: {-4,0,0}}

    assert {:ok,falling} = Check.run(compiled([]),Keyword.put(options,:entry,{0,2,0}))
    assert falling.endpoints.entry.position == %{standable: false,landed: {0,0,0}}
    assert falling.endpoints.entry.body.kind == :open
    assert falling.endpoints.entry.support.kind == :open
  end

  test "standalone view uses compiled local bounds without inventing rooms or check points" do
    definition = compiled([{{-1,0,0},19}], [{{0,0,0},11}]) |> Map.put(:summary,%{bounds: {{-1,0,0},{8,8,8}}})
    assert {:ok,%{layers: [%{macro_y: 0,text: "+#"}],elevations: %{front: "+#"}}} = Check.view(definition)
    assert {:error,:empty_draft} = Check.view(compiled([]) |> Map.put(:summary,%{bounds: nil}))
    assert Check.materials(definition,@properties).units == %{11 => 5120,19 => 10}
  end

  @tag :micro_slice
  test "micro sections expose stair direction and preserve negative macro coordinates" do
    stairs = for x <- 0..2,y <- 0..x,do: {{x,y,0},11}
    geometry = compiled(stairs) |> Map.put(:summary,%{bounds: {{0,0,0},{3,3,1}}})
    assert {:ok,section} = Check.slice(geometry,2,0)
    assert section.text == "..+\n.++\n+++"
    assert section.resolution == :micro
    assert section.columns == %{axis: :x,min: 0,max_exclusive: 3}
    assert section.rows == %{axis: :y,min: 0,max_exclusive: 3,order: :descending}
    assert {:error,:outside_view} = Check.slice(geometry,2,1)

    mixed = compiled([{{0,0,0},19}],[{{-1,0,0},11}])
      |> Map.put(:summary,%{bounds: {{-8,0,0},{1,8,8}}})
    assert {:ok,top} = Check.slice(mixed,1,0)
    assert top.text == Enum.join(["########+"|List.duplicate("########.",7)],"\n")
    assert top.columns == %{axis: :x,min: -8,max_exclusive: 1}
    assert top.rows == %{axis: :z,min: 0,max_exclusive: 8,order: :ascending}
    assert {:error,:invalid_view} = Check.slice(mixed,3,0)
    huge = %{mixed|summary: %{bounds: {{0,0,0},{129,1,129}}}}
    assert {:error,:view_budget} = Check.slice(huge,1,0)
  end
end
