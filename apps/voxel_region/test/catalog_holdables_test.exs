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
  end
end
