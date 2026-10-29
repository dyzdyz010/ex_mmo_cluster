defmodule VoxelRegion.World.Clock do
  @moduledoc """
  World 热／液体调度的单调毫秒与 timer 依赖。ready 切点、身体样本年龄和派生 lag 使用同一实例。
  默认沿 System／Process；替换依赖不改变物理步长、due 所有权或提交路径。
  """

  @callback now(term()) :: integer()
  @callback schedule(term(), pid(), term(), non_neg_integer()) :: reference()
  @callback cancel(term(), reference()) :: non_neg_integer() | false

  @doc "默认单调毫秒时间。"
  def now(_ref), do: System.monotonic_time(:millisecond)

  @doc "默认 timer 运输；到期消息不等于物理步已经完成。"
  def schedule(_ref, pid, message, delay), do: Process.send_after(pid, message, delay)

  @doc "仅取消默认 timer 运输，不取消 World 保存的 due。"
  def cancel(_ref, timer), do: Process.cancel_timer(timer)

  @doc "读取本 World 构造时接纳的时钟。"
  def monotonic(%{clock: {module, ref}}), do: module.now(ref)

  @doc "通过本 World 的同一时钟投递 timer。"
  def send_after(%{clock: {module, ref}}, pid, message, delay),
    do: module.schedule(ref, pid, message, delay)

  @doc "通过创建 timer 的同一依赖取消运输。"
  def cancel_timer(%{clock: {module, ref}}, timer), do: module.cancel(ref, timer)
end
