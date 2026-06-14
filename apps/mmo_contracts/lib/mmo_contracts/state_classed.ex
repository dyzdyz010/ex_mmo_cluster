defmodule MmoContracts.StateClassed do
  @moduledoc """
  让状态持有者模块**声明** PERS-5 `state_class` 的 `use` 宏。

      defmodule SceneServer.Combat.State do
        use MmoContracts.StateClassed, class: :runtime_authoritative
        # ...
      end

  注入 `__state_class__/0`,并在**编译期**用 `MmoContracts.StateClass.fetch!/1` 校验:
  传入非法/未声明分类会直接编译失败,从机制上落实 PERS-5"未分类禁止进入生产代码"。

  配套 `MmoContracts.StateRegistry`(分类清单单一来源)做集中登记与完备性校验。
  """

  @doc false
  defmacro __using__(opts) do
    class = Keyword.fetch!(opts, :class)
    # 编译期校验(PERS-5):非法分类在此 raise,使用方编译失败。
    validated = MmoContracts.StateClass.fetch!(class)

    quote do
      @doc false
      @spec __state_class__() :: MmoContracts.StateClass.t()
      def __state_class__, do: unquote(validated)
    end
  end
end
