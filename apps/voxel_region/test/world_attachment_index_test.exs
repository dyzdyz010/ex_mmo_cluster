defmodule VoxelRegion.WorldAttachmentIndexTest do
  use ExUnit.Case, async: true

  alias VoxelRegion.Attachments
  alias VoxelRegion.World.{AttachmentOps, Canonical}

  # 只测试：attachments 派生索引（L0 区域 => 锚点在该区的槽）的增量维护，以及按区域取候选的读取与整表定义逐项相同。
  # 期望来自手算区域与各读取的定义（整表筛选），不复用被测的区域候选逻辑。
  @micro VoxelRegion.Spatial.micro_resolution()

  defp empty, do: %{attachments: %{}, attachment_regions: %{}}

  test "put and drop keep the region index equal to a full rebuild" do
    # 微格 8 = 1 宏格，L0 区域 = 64 宏格 = 512 微格：锚点 (8, 16, -8) 在区域 {0, 0, -1}，(600, 0, 0) 在 {1, 0, 0}。
    assert @micro == 8
    a = {0, 1, {8, 16, -8}}
    b = {1, 0, {600, 0, 0}}
    c = {0, 2, {9, 16, -8}}

    state = Canonical.put_attachments(empty(), %{a => {1, 11}, b => {2, 24}, c => {1, 11}})
    assert state.attachment_regions == %{{0, 0, -1} => %{a => {1, 11}, c => {1, 11}}, {1, 0, 0} => %{b => {2, 24}}}

    # 改值不改归属；删除后空集合连键去掉；删不存在的槽不动索引。
    state = state |> Canonical.put_attachments(%{a => {3, 12}}) |> Canonical.drop_attachments([b, {0, 0, {0, 0, 0}}])
    assert state.attachments == %{a => {3, 12}, c => {1, 11}}
    assert state.attachment_regions == %{{0, 0, -1} => %{a => {3, 12}, c => {1, 11}}}
    assert Canonical.index_attachments(state).attachment_regions == state.attachment_regions
  end

  # 跨正负坐标与区域边界（±512 微格附近）的随机附件表；固定种子。
  defp random_state(seed, n) do
    :rand.seed(:exsss, {seed, seed, seed})
    edge = fn -> Enum.random([-513, -512, -511, -8, -1, 0, 1, 7, 8, 504, 511, 512, 513]) + :rand.uniform(9) - 5 end

    slots =
      for _ <- 1..n, into: %{} do
        {{Enum.random([0, 1]), Enum.random(0..2), {edge.(), edge.(), edge.()}}, {:rand.uniform(50), 11}}
      end

    Canonical.index_attachments(Map.put(empty(), :attachments, slots))
  end

  test "affected slots, L1 face groups and region extracts equal the full-table definitions" do
    for seed <- 1..5 do
      state = random_state(seed, 400)
      all = Map.keys(state.attachments)
      macros = all |> Attachments.macros() |> Enum.take_random(40)
      cells = macros ++ [{-1, -1, -1}, {63, 0, 64}, {64, 64, -65}]

      touched = MapSet.new(cells)
      expected = for slot <- Enum.sort(all), Enum.any?(Attachments.macros([slot]), &MapSet.member?(touched, &1)), do: slot
      assert AttachmentOps.affected_attachments(state, cells) == expected

      parents = Enum.map(cells, fn {x, y, z} -> {Integer.floor_div(x, 2), Integer.floor_div(y, 2), Integer.floor_div(z, 2)} end)
      assert Attachments.l1_faces(Canonical.attachments_near_parents(state, parents), parents) ==
               Attachments.l1_faces(Enum.sort(state.attachments), parents)

      for region <- [{0, 0, 0}, {-1, -1, -1}, {0, 1, -1}, {1, 0, 0}] do
        assert Attachments.extract(Canonical.attachments_around_region(state, region), region) ==
                 Attachments.extract(state.attachments, region)
      end
    end
  end

  test "dropped and changed slots are the keys missing or revalued after the change, wherever they were" do
    before = random_state(7, 300)
    [gone, revalued] = before.attachments |> Map.keys() |> Enum.take_random(40) |> Enum.chunk_every(20)
    state = before |> Canonical.drop_attachments(gone) |> Canonical.put_attachments(Map.new(revalued, &{&1, {99, 11}}))
    # 新增槽不是提交前的槽；同值重写不算改值。
    state = Canonical.put_attachments(state, %{{0, 0, {4096, 0, 0}} => {98, 11}, hd(Map.keys(state.attachments)) => state.attachments[hd(Map.keys(state.attachments))]})
    assert Canonical.dropped_attachments(before, state) == Enum.sort(gone)
    assert Canonical.changed_attachments(before, state) == for(slot <- Enum.sort(gone ++ revalued), do: {slot, before.attachments[slot]})
    assert Canonical.dropped_attachments(state, state) == []
    assert Canonical.changed_attachments(state, state) == []
  end
end
