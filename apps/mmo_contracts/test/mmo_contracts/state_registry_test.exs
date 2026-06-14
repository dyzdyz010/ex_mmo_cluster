defmodule MmoContracts.StateRegistryTest do
  use ExUnit.Case, async: true

  alias MmoContracts.{StateRegistry, StateClass}

  describe "StateClassed 声明宏" do
    defmodule Dummy do
      use MmoContracts.StateClassed, class: :runtime_authoritative
    end

    test "注入 __state_class__/0 并编译期校验" do
      assert Dummy.__state_class__() == :runtime_authoritative
    end

    test "非法分类编译期失败(PERS-5)" do
      assert_raise ArgumentError, ~r/invalid state_class/, fn ->
        Code.eval_string("""
        defmodule MmoContracts.StateRegistryTest.Bad do
          use MmoContracts.StateClassed, class: :not_a_class
        end
        """)
      end
    end
  end

  describe "StateRegistry 清单" do
    test "validate!/0 通过(所有 class 合法、holder 不重复)" do
      assert StateRegistry.validate!() == :ok
    end

    test "四个分类都有代表性持有者" do
      for class <- StateClass.all() do
        assert StateRegistry.by_class(class) != [], "分类 #{class} 缺少登记的持有者"
      end
    end

    test "holders 无重复" do
      holders = StateRegistry.holders()
      assert holders == Enum.uniq(holders)
    end

    test "每条目带 spec 与 note(可审计)" do
      for e <- StateRegistry.entries() do
        assert is_binary(e.spec) and e.spec != ""
        assert is_binary(e.note) and e.note != ""
        assert is_atom(e.app)
        assert StateClass.valid?(e.state_class)
      end
    end
  end
end
