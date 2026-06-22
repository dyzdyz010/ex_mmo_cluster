defmodule SceneServer.Voxel.Reaction.ActuatorsTest do
  # 功能完善 · 正交架构 S3 Part B:通用执行器规格 → 规则展开。证设备从"每设备手写两条规则"
  # 收敛为"每设备一条声明式数据",且展开机制 material/tag 无关——加一条规格即得新设备,零新代码。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Reaction.{Actuator, Actuators, Rule}

  describe "门规格展开(迁移自手写 door_open/door_close)" do
    test "Actuators.all 含门规格" do
      assert %Actuator{material: :door, trigger_tag: :powered, active_tag: :open} in Actuators.all()
    end

    test "门展开成 activate / deactivate 两条等价规则" do
      door = %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}
      assert [activate, deactivate] = Actuators.rules_for(door)

      # activate:有 :powered 且未开 → 加 :open
      assert %Rule{
               kind: :tag_reaction,
               material: :door,
               require_tags: [:powered],
               forbid_tags: [:open],
               effects: [{:add_tag, :open}]
             } = activate

      # deactivate:已开但失电 → 去 :open
      assert %Rule{
               kind: :tag_reaction,
               material: :door,
               require_tags: [:open],
               forbid_tags: [:powered],
               effects: [{:remove_tag, :open}]
             } = deactivate
    end

    test "门两条规则 id 唯一且可辨识" do
      door = %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}
      [activate, deactivate] = Actuators.rules_for(door)
      assert activate.id == :door_open_activate
      assert deactivate.id == :door_open_deactivate
      assert activate.id != deactivate.id
    end

    test "to_rules 把全部规格展开(每规格两条)" do
      rules = Actuators.to_rules()
      assert length(rules) == length(Actuators.all()) * 2
      assert Enum.all?(rules, &match?(%Rule{kind: :tag_reaction}, &1))
    end
  end

  describe "光门:光驱动设备(与电门对称,光成一等 device trigger)" do
    test "Actuators.all 含光门规格(photo_sensor:illuminated<->open)" do
      assert %Actuator{material: :photo_sensor, trigger_tag: :illuminated, active_tag: :open} in Actuators.all()
    end

    test "光门展开成对称 activate/deactivate(与电门同机制,trigger=:illuminated)" do
      gate = %Actuator{material: :photo_sensor, trigger_tag: :illuminated, active_tag: :open}
      assert [activate, deactivate] = Actuators.rules_for(gate)

      # 被光照(:illuminated)且未开 → 加 :open(可通行)。
      assert %Rule{
               material: :photo_sensor,
               require_tags: [:illuminated],
               forbid_tags: [:open],
               effects: [{:add_tag, :open}]
             } = activate

      # 遮光(去 :illuminated)→ 去 :open(复阻挡)。
      assert %Rule{
               material: :photo_sensor,
               require_tags: [:open],
               forbid_tags: [:illuminated],
               effects: [{:remove_tag, :open}]
             } = deactivate

      assert activate.id == :photo_sensor_open_activate
      assert deactivate.id == :photo_sensor_open_deactivate
    end
  end

  describe "可扩展性:加一条规格 = 新设备,零新代码/碰撞" do
    # 用 iron 作"活塞"示例设备材料(MaterialCatalog 已有,免目录改动),:extended 作激活态。
    # 证展开 material/tag 完全无关——一条新规格即得 powered<->extended 状态机,与门同机制。
    test "第二设备(piston:powered<->extended)由一条规格展开出对称规则对" do
      piston = %Actuator{material: :iron, trigger_tag: :powered, active_tag: :extended}
      assert [activate, deactivate] = Actuators.rules_for(piston)

      assert %Rule{
               material: :iron,
               require_tags: [:powered],
               forbid_tags: [:extended],
               effects: [{:add_tag, :extended}]
             } = activate

      assert %Rule{
               material: :iron,
               require_tags: [:extended],
               forbid_tags: [:powered],
               effects: [{:remove_tag, :extended}]
             } = deactivate

      assert activate.id == :iron_extended_activate
      assert deactivate.id == :iron_extended_deactivate
    end

    test "多规格列表展开:N 规格 → 2N 规则,各设备规则互不串扰" do
      door = %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}
      piston = %Actuator{material: :iron, trigger_tag: :powered, active_tag: :extended}

      rules = Enum.flat_map([door, piston], &Actuators.rules_for/1)
      assert length(rules) == 4
      materials = rules |> Enum.map(& &1.material) |> Enum.uniq() |> Enum.sort()
      assert materials == [:door, :iron]
    end
  end
end
