defmodule VoxelRegion.CatalogHoldablesTest do
  # 只测试：Voxim 交互设计“2026-11-09 修订”第 1 步“持物与姿态”给可玩属性目录加了 holdables（持物动作表：
  # 作业工具、战斗工具、有序技能列表，只引用目录里已有的工具；客户端装备槽按 id 引用）。服务端暂不校验持有，也不解析该段；
  # 本测试证明新发布能被服务端加载（摘要等于文件名），且相对交互部署所用的 7228759e 只多出 holdables：
  # 工具、材料与附件规格逐项不变，因此在线发布入口（World.publish_properties / publish_parameters）的兼容规则都接受它。
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.{Damage, ParameterEvolution}

  @playable Path.expand("../../../../Voxim/Content/Voxel/Properties/Playable/Published", __DIR__)
  @interaction "7228759eab488b0af472c65427daf9597fdbda6ebf44d07066806f51fa5d4f14"
  @holdables "f105c1bb718e039347a66d4fc8507b77be2a03a8272766bc7658cfd80664ae29"

  test "the holdables publication loads and only adds the client-side action table" do
    path = Path.join(@playable, @holdables <> ".json")
    old = Damage.load(Path.join(@playable, @interaction <> ".json"))
    new = Damage.load(path)
    assert Base.encode16(new.digest, case: :lower) == @holdables
    assert new.tools == old.tools
    assert new.materials == old.materials
    assert new.attachments == old.attachments and new.liquid == old.liquid and new.retired == old.retired
    assert ParameterEvolution.compatible?(old, new)

    # 手写期望：作者表 Docs/Gameplay/author_actions.py HOLDABLES。本增量只有剑（战斗 22、技能 [23]），两关卡的装备槽都指向它。
    %{"holdables" => rows} = Jason.decode!(File.read!(path))
    assert rows == [%{"id" => "sword", "display_name" => "剑", "combat_tool_id" => 22, "skill_tool_ids" => [23]}]

    # 每个引用都是目录工具：作业工具 precise，战斗工具为判定区招式（客户端解码同一条规则）。
    for row <- rows do
      assert Map.get(new.tools[row["work_tool_id"]] || %{}, "target_mode", "precise") == "precise"
      if id = row["combat_tool_id"], do: assert(new.tools[id]["target_mode"] in ["object", "direction"])
      assert Enum.all?(row["skill_tool_ids"], &Map.has_key?(new.tools, &1))
    end

    # 没有 basic_windup_s 的目录：服务端没有固定前摇表。
    assert new.basic_windups == []
  end

  # 法杖普攻固定前摇（Voxim 交互设计"2026-11-20 修订"，用户 2026-11-20 定；魔法 v2 切片 3 迁至 IR v2）：
  # `fixtures/items/08bb766b…` 为 Voxim `author_actions.py holdables` 真实发布物（magic-v2-online 62042c84，原样复制、按 sha256 核对），basic_spell 为小写十六进制 IR v2 字节
  # （〈握〉〈形 球 0.05 m，0.01 kg〉〈辉 100 W〉〈蓄 2 kJ〉〈投 30 m/s〉｜当〈遇〉则〈散〉），
  # basic_windup_s 仍为 0.3；剑没有普攻法术。旧 v1 JSON 对象在加载边界直接拒绝。
  @staff "08bb766b665b8c7423341d78c4a63dcc9a3ff47bfe37c192b7b4854c96e105bc"
  @bolt_hex "02010100070001000200003200000000000a010010006401001b07d001001e7530010001002201002c00"
  test "the staff publication carries the bolt's IR v2 bytes and authored basic wind-up 0.3 s" do
    path = Path.expand("fixtures/items/#{@staff}.json", __DIR__)
    catalog = Damage.load(path)
    assert Base.encode16(catalog.digest, case: :lower) == @staff
    bolt = Base.decode16!(@bolt_hex, case: :lower)
    assert catalog.basic_windups == [{bolt, 0.3}]

    # 不保留 v1 兼容分支：basic_spell 为旧 JSON map 或非法十六进制在加载边界显式失败。
    data = Jason.decode!(File.read!(path))
    tmp = Path.join(System.tmp_dir!(), "holdable_v1_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(tmp) end)

    for {bad, exc} <- [
          {%{"v" => 1, "steps" => []}, MatchError},
          {"NOT_HEX", ArgumentError},
          {"0201GG", ArgumentError}
        ] do
      bad_holdables = [%{"id" => "staff", "basic_spell" => bad, "basic_windup_s" => 0.3}]
      File.write!(tmp, Jason.encode!(Map.put(data, "holdables", bad_holdables)))
      assert_raise exc, fn -> Damage.load(tmp) end
    end
  end
end
