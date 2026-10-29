defmodule VoxelRegion.ClosureEntriesTest do
  use ExUnit.Case, async: true

  alias VoxelRegion.World.Closure

  # 只提取 World 自身分派头部；不执行改写后的源码。
  defp entries(ast, names \\ [:call, :info]) do
    {_, found} = Macro.prewalk(ast, MapSet.new(), fn
      {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
        head = case head do
          {:when, _, [inner | _]} -> inner
          other -> other
        end

        case head do
          {name, _, args} when name in [:call, :info, :seeds] ->
            message = if name == :seeds, do: Enum.at(args, 1), else: hd(args)
            message = if name in names, do: message, else: nil
            case shape(message, name) do
              nil -> {node, acc}
              entry -> {node, MapSet.put(acc, entry)}
            end
          _ -> {node, acc}
        end
      node, acc -> {node, acc}
    end)
    found
  end

  defp shape({:=, _, [left, _]}, name), do: shape(left, name)
  defp shape({:{}, _, [tag | rest]}, _) when is_atom(tag), do: {tag, length(rest) + 1}
  defp shape({tag, _}, _) when is_atom(tag), do: {tag, 2}
  defp shape({:{}, _, [{ref, _, context} | rest]}, name) when name in [:info, :seeds]
       and is_atom(ref) and is_atom(context), do: {:reference, length(rest) + 1}
  defp shape({{ref, _, context}, _}, name) when name in [:info, :seeds] and is_atom(ref) and is_atom(context), do: {:reference, 2}
  defp shape(atom, _) when is_atom(atom) and not is_nil(atom), do: {atom, 0}
  defp shape(_, _), do: nil

  defp missing(actual) do
    registered = Closure.registered_entries() |> Map.values() |> List.flatten() |> MapSet.new()
    MapSet.difference(actual, registered)
  end

  defp paged_info_tags(ast) do
    {_, tags} = Macro.prewalk(ast, [], fn
      {:@, _, [{:paged_infos, _, [tags]}]} = node, _ -> {node, tags}
      node, tags -> {node, tags}
    end)
    tags
  end

  test "World 的具体分派入口均已登记，未知入口不能被兜底掩盖" do
    ast = __DIR__ |> Path.join("../lib/voxel_region/world.ex") |> File.read!() |> Code.string_to_quoted!()
    actual = entries(ast)
    assert MapSet.size(actual) > 40
    assert missing(actual) == MapSet.new()
    page_tags = Closure.registered_entries().page |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(paged_info_tags(ast)), page_tags)
    assert Closure.needs(%{}, {:new_page_read, :some_region}) == :none
    added = Code.string_to_quoted!("defp call({:new_page_read, region}, from, state), do: {region, from, state}")
    assert missing(MapSet.union(actual, entries(added))) == MapSet.new([{:new_page_read, 2}])
  end

  test "页登记对应实际闭包分支，非页登记独立明确" do
    ast = __DIR__ |> Path.join("../lib/voxel_region/world/closure.ex") |> File.read!() |> Code.string_to_quoted!()
    %{page: page, none: none} = Closure.registered_entries()
    seeds = entries(ast, [:seeds]) |> MapSet.union(MapSet.new([{:publish_properties, 2}, {:thermal_experiment, 2}]))
    assert seeds == MapSet.new(page)
    assert MapSet.disjoint?(MapSet.new(page), MapSet.new(none))
    assert {:content_version, 0} in none
  end

  test "GM 操作和引用采样结果保留闭包语义" do
    assert Closure.needs(%{}, {:gm, :key, :liquid_fill, %{seed: {0, 0, 0}}}) != :none
    assert Closure.needs(%{}, {:gm, :key, :unknown, %{}}) == :none
    assert Closure.needs(%{thermal: nil}, {make_ref(), []}) == {[], [], []}
    assert Closure.needs(%{}, :content_version) == :none
    assert Closure.needs(%{}, {:publish_parameters, :catalog, :digest}) == :all
    assert Closure.needs(%{instances: %{}}, {:remove_prefab, :missing}) == {[], [], [:missing]}
  end
end
