defmodule GateServer.Npc.Scheduler do
  @moduledoc """
  全局系统功能：技能中断策略。只决定继续或中断，不执行动作。
  唯一配置入口是 profile.interrupt_policy = {实现模块, 配置}；没有它就不做定时检查、不请求任何分类模型。
  荒野施工内部分诊用的 `scheduler` endpoint 是另一项职责，配置它不会顺带开启中断检查。
  Runtime 在独立 worker 中调用，context 含 skill、observation 与 heard（技能开始后听到的话，新在前）。
  `{:error, 原因}` 表示这次答不上来：Runtime 记一笔并继续技能，不当作中断理由。
  """
  @callback decide(context :: map(), config :: term()) ::
              :continue | {:interrupt, term()} | {:error, term()}

  @doc "在组合边界选择策略；没有配置时不创建定时检查。"
  def configured(%{interrupt_policy: {module, config}}), do: {module, config}
  def configured(_), do: nil
end
