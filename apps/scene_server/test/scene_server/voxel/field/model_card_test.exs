defmodule SceneServer.Voxel.Field.ModelCardTest do
  # 梯队3 step3.11(EMG-1/3/7):涌现系统模型卡——fidelity_class + 安全阀 + 假设可审计。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{ModelCard, ModelCardRegistry}

  describe "ModelCard.new!/1" do
    test "构造合法模型卡并填默认值" do
      card =
        ModelCard.new!(
          kernel_id: :demo,
          fidelity_class: :qualitative
        )

      assert card.kernel_id == :demo
      assert card.fidelity_class == :qualitative
      assert card.model_version == 1
      assert card.safety_valve == %{}
      assert card.description == ""
      assert card.assumptions == []
    end

    test "保留显式字段" do
      card =
        ModelCard.new!(%{
          kernel_id: :demo,
          fidelity_class: :semi_quantitative,
          model_version: 3,
          safety_valve: %{type: :frontier_budget, max_frontier: 512},
          description: "x",
          assumptions: ["a", "b"]
        })

      assert card.model_version == 3
      assert card.safety_valve == %{type: :frontier_budget, max_frontier: 512}
      assert card.assumptions == ["a", "b"]
    end

    test "拒绝非法 fidelity_class" do
      assert_raise ArgumentError, ~r/非法 fidelity_class/, fn ->
        ModelCard.new!(kernel_id: :demo, fidelity_class: :made_up)
      end
    end

    test "拒绝非 atom kernel_id" do
      assert_raise ArgumentError, ~r/kernel_id 必须是 atom/, fn ->
        ModelCard.new!(kernel_id: "demo", fidelity_class: :qualitative)
      end
    end

    test "拒绝非 map safety_valve" do
      assert_raise ArgumentError, ~r/safety_valve 必须是 map/, fn ->
        ModelCard.new!(kernel_id: :demo, fidelity_class: :qualitative, safety_valve: [])
      end
    end
  end

  describe "ModelCard.summary/1" do
    test "返回紧凑摘要(assumption 折叠为计数)" do
      card =
        ModelCard.new!(
          kernel_id: :demo,
          fidelity_class: :quantitative,
          safety_valve: %{type: :current_limit, current_limit_amps: 10.0},
          assumptions: ["a", "b", "c"]
        )

      assert ModelCard.summary(card) == %{
               kernel_id: :demo,
               fidelity_class: :quantitative,
               model_version: 1,
               safety_valve: %{type: :current_limit, current_limit_amps: 10.0},
               assumption_count: 3
             }
    end
  end

  describe "ModelCardRegistry" do
    test "登记全部 5 个涌现 kernel" do
      assert length(ModelCardRegistry.kernel_modules()) == 5
      assert length(ModelCardRegistry.cards()) == 5
    end

    test "每张卡 fidelity_class/safety_valve 合法且 kernel_id 与模块自述一致" do
      for module <- ModelCardRegistry.kernel_modules() do
        card = module.model_card()
        assert %ModelCard{} = card
        assert card.kernel_id == module.kernel_id()
        assert card.fidelity_class in ModelCard.fidelity_classes()
        assert is_map(card.safety_valve)
        # EMG-7:每个涌现系统都必须声明一个安全阀(预算/熔断),不能是空。
        assert map_size(card.safety_valve) > 0
        assert Map.has_key?(card.safety_valve, :type)
      end
    end

    test "by_kernel_id/0 唯一且可 fetch" do
      by_id = ModelCardRegistry.by_kernel_id()
      assert map_size(by_id) == 5

      assert {:ok, %ModelCard{kernel_id: :temperature_diffusion}} =
               ModelCardRegistry.fetch(:temperature_diffusion)

      assert {:ok, %ModelCard{kernel_id: :circuit_current}} =
               ModelCardRegistry.fetch(:circuit_current)

      assert :error = ModelCardRegistry.fetch(:nonexistent)
    end

    test "summaries/0 与 cards/0 一一对应" do
      assert ModelCardRegistry.summaries() ==
               Enum.map(ModelCardRegistry.cards(), &ModelCard.summary/1)
    end

    test "已知保真档分布(温度/电势半定量,图/路径类定性)" do
      by_id = ModelCardRegistry.by_kernel_id()
      assert by_id[:temperature_diffusion].fidelity_class == :semi_quantitative
      assert by_id[:electric_potential].fidelity_class == :semi_quantitative
      assert by_id[:conduction_path].fidelity_class == :qualitative
      assert by_id[:electric_discharge].fidelity_class == :qualitative
      assert by_id[:circuit_current].fidelity_class == :qualitative
    end
  end
end
