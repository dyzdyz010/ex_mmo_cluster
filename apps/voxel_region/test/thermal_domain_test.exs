defmodule VoxelRegion.ThermalDomainTest do
  @moduledoc """
  只测试：常驻热域的节点表与原生内核项必须与 World 端参考规则逐项相同——接触按 `ThermalGeometry.contacts/1`
  遍历节点表、下标按 `Enum.to_list/1` 次序（超过 32 键的 map 两者互逆），辐射按 `ThermalRadiation.terms/4`。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.{ThermalDomain, ThermalGeometry, ThermalNative, ThermalRadiation}

  defp key(i), do: {0, {i * 8, 0, 0}}

  # 链状节点：每个节点接前一、后一、后二，接触次序固定；导热各不相同，使求和次序可见。
  defp chain(range) do
    Map.new(range, fn i ->
      {key(i), %{contacts: for(j <- [i - 1, i + 1, i + 2], j >= 0, do: {key(j), 1.0 + i + j / 100})}}
    end)
  end

  defp plain(n), do: {Map.merge(%{cell: {0, 0, 0}, cells: [{0, 0, 0}], damage_key: :row}, n), false}

  # 只测试：节点表与拓扑契约不看节点值；装入一组合法的常量静态量与动态量。
  defp load(_node),
    do: {{1.0, 1.0, 1000.0, 6.0, 293.15, nil, false, true, nil}, {293.15, 1.0, 1.0, nil, 0.0, false, nil, nil}}

  defp reference(nodes) do
    ordered = Enum.to_list(nodes)
    indices = ordered |> Enum.with_index() |> Map.new(fn {{k, _}, i} -> {k, i} end)
    {Enum.map(ordered, &elem(&1, 0)), for({a, b, g} <- ThermalGeometry.contacts(nodes), do: {indices[a], indices[b], g}),
     indices}
  end

  defp native(domain, emissivity \\ 0.0) do
    {domain, ordered} = ThermalDomain.index(domain, emissivity)
    {edges, radiation} = ThermalNative.domain_terms(domain.native)
    {Enum.map(ordered, &elem(&1, 0)), edges, radiation}
  end

  test "接触次序与下标同参考规则：小表（≤32 键）与大表（>32 键，推导式与 to_list 互逆）" do
    for size <- [10, 40] do
      nodes = chain(0..(size - 1))
      domain = ThermalDomain.sync(ThermalDomain.new(), nodes, :full, [], :tag, nil, &plain/1, &load/1)
      {keys, edges, _} = native(domain)
      {ref_keys, ref_edges, _} = reference(nodes)
      assert keys == ref_keys
      assert edges == ref_edges
      assert length(edges) > size
    end
  end

  test "同一提交内增量扩域与整表比较得到同一节点表和内核边；离开的节点不再出现" do
    grown = ThermalDomain.sync(ThermalDomain.new(), chain(0..29), :full, [], :tag, nil, &plain/1, &load/1)
    grown = ThermalDomain.sync(grown, chain(0..44), {:grown, Enum.map(30..44, &key/1)}, [], :tag, nil, &plain/1, &load/1)
    full = ThermalDomain.sync(ThermalDomain.new(), chain(0..44), :full, [], :tag, nil, &plain/1, &load/1)
    assert native(grown) == native(full)
    assert {elem(reference(chain(0..44)), 0), elem(reference(chain(0..44)), 1)} ==
             {elem(native(full), 0), elem(native(full), 1)}

    shrunk = ThermalDomain.sync(grown, chain(0..19), :full, [], :tag, nil, &plain/1, &load/1)
    {keys, edges, _} = native(shrunk)
    {ref_keys, ref_edges, _} = reference(chain(0..19))
    assert {keys, edges} == {ref_keys, ref_edges}
  end

  test "热分区不同的接触被过滤；未变节点不重算分区，迟到的同区邻点照常接通" do
    a = key(-1)
    b = key(0)
    c = key(1)
    holder = fn k -> send(self(), {:holder, k}); if(k == c, do: :cold, else: :warm) end
    node = %{contacts: [{b, 2.0}, {c, 3.0}]}
    domain = ThermalDomain.sync(ThermalDomain.new(), %{a => node}, :full, [], :tag, holder, &plain/1, &load/1)
    assert domain.table[a].contacts == [{b, 2.0}]
    for k <- [a, b, c], do: assert_receive({:holder, ^k})

    domain = ThermalDomain.sync(domain, %{a => node, b => %{contacts: [{a, 2.0}]}}, {:grown, [b]}, [], :tag, holder,
      &plain/1, &load/1)
    assert_receive {:holder, ^b}
    assert_receive {:holder, ^a}
    refute_received {:holder, _}
    {keys, edges, _} = native(domain)
    assert for({i, j, g} <- edges, do: {Enum.at(keys, i), Enum.at(keys, j), g}) == [{a, b, 2.0}]
  end

  test "派生字段按标签缓存，有限节点每轮重算，槽位下标可按键查询" do
    nodes = chain(0..2)
    counting = fn n -> send(self(), :augment); {n |> plain() |> elem(0) |> Map.put(:default, :row), n == nodes[key(1)]} end
    domain = ThermalDomain.sync(ThermalDomain.new(), nodes, :full, [], :tag, nil, counting, &load/1)
    for _ <- 1..3, do: assert_receive(:augment)
    domain = ThermalDomain.sync(domain, nodes, :full, [], :tag, nil, counting, &load/1)
    assert_receive :augment
    refute_received :augment
    ThermalDomain.sync(domain, nodes, :full, [], :other, nil, counting, &load/1)
    for _ <- 1..3, do: assert_receive(:augment)

    {domain, ordered} = ThermalDomain.index(domain, 0.0)
    expected = ordered |> Enum.with_index() |> Map.new(fn {{k, _}, i} -> {k, i} end)
    assert ThermalDomain.positions(domain, [key(0), key(2), key(7)]) == Map.take(expected, [key(0), key(2)])
  end

  test "辐射项同 ThermalRadiation.terms/4：对天空、遮挡、域内伙伴与域外伙伴" do
    nodes = chain(0..39)
    sights = %{
      {0, 0, 0} => [{key(0), :sky, 0.5}, {key(0), {key(3), {3, 0, 0}}, 1.0}, {key(0), :blocked, 0.25}],
      {5, 0, 0} => [{key(5), {key(90), {90, 0, 0}}, 1.0}, {key(5), :sky, 0.75}, {key(5), {key(2), {2, 0, 0}}, 0.5}]
    }

    domain = ThermalDomain.sync(ThermalDomain.new(), nodes, :full, [], :tag, nil, &plain/1, &load/1)
    domain = ThermalDomain.sync_sights(domain, sights)
    {_, _, radiation} = native(domain, 0.9)
    {ordered, _, indices} = reference(nodes)
    assert radiation == ThermalRadiation.terms(Enum.map(ordered, &{&1, nil}), sights, 0.9, indices)

    # 编辑丢弃视线缓存后整体重推：旧视线不残留。
    domain = ThermalDomain.sync_sights(domain, Map.take(sights, [{5, 0, 0}]))
    {_, _, radiation} = native(domain, 0.9)
    assert radiation == ThermalRadiation.terms(Enum.map(ordered, &{&1, nil}), Map.take(sights, [{5, 0, 0}]), 0.9, indices)
  end
end
