defmodule MmoContracts.StateClassTest do
  use ExUnit.Case, async: true

  alias MmoContracts.StateClass

  describe "all/0 与 valid?/1" do
    test "恰好四个分类(PERS-5)" do
      assert StateClass.all() == [
               :durable_authoritative,
               :runtime_authoritative,
               :derived,
               :ephemeral
             ]
    end

    test "valid? 对四分类为真、对其它为假" do
      for class <- StateClass.all(), do: assert(StateClass.valid?(class))
      refute StateClass.valid?(:durable)
      refute StateClass.valid?("durable_authoritative")
      refute StateClass.valid?(nil)
    end
  end

  describe "fetch!/1(PERS-5 未分类禁入生产)" do
    test "合法分类原样返回" do
      assert StateClass.fetch!(:derived) == :derived
    end

    test "非法分类 raise ArgumentError" do
      assert_raise ArgumentError, ~r/invalid state_class/, fn ->
        StateClass.fetch!(:not_a_class)
      end
    end
  end

  describe "durable_commit_required?/1(AUTH-2 / PERS-6)" do
    test "仅 durable_authoritative 要求 durable-commit-before-ack" do
      assert StateClass.durable_commit_required?(:durable_authoritative)
      refute StateClass.durable_commit_required?(:runtime_authoritative)
      refute StateClass.durable_commit_required?(:derived)
      refute StateClass.durable_commit_required?(:ephemeral)
    end
  end

  describe "may_affect_settlement?/1(PERS-8)" do
    test "ephemeral 禁止影响最终结算,其余允许" do
      refute StateClass.may_affect_settlement?(:ephemeral)
      assert StateClass.may_affect_settlement?(:durable_authoritative)
      assert StateClass.may_affect_settlement?(:runtime_authoritative)
      assert StateClass.may_affect_settlement?(:derived)
    end
  end

  describe "recovery_required?/1(AUTH-15 / PERS-12)" do
    test "durable 与 runtime 权威必须声明恢复策略" do
      assert StateClass.recovery_required?(:durable_authoritative)
      assert StateClass.recovery_required?(:runtime_authoritative)
      refute StateClass.recovery_required?(:derived)
      refute StateClass.recovery_required?(:ephemeral)
    end
  end
end
