defmodule GateServer.Npc.Scheduler do
  @moduledoc """
  全局系统功能：技能中断策略。只决定继续或中断，不执行动作。
  profile.interrupt_policy = {实现模块, 配置}；已有 scheduler endpoint 配置继续由 Jev 适配。
  interrupt_policy 不覆盖荒野施工内部使用的 scheduler，两个决策职责独立。
  Runtime 在独立 worker 中调用，传入 skill、observation、heard；配置不混入世界事实。
  """
  @callback decide(context :: map(), config :: term()) ::
              :continue | {:interrupt, term()} | {:error, term()}

  @doc "在组合边界选择策略；没有配置时不创建定时检查。"
  def configured(%{interrupt_policy: {module, config}}), do: {module, config}
  def configured(%{scheduler: _} = profile), do: {GateServer.Npc.Jev, profile}
  def configured(_), do: nil
end
