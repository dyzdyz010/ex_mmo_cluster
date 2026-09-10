defmodule SceneServer.Movement.Clock do
  @moduledoc "Scene 与 Player 共用的60Hz公共时间映射；已发布碰撞水位单独约束物理消费。"
  @doc "生产单调时钟；测试可注入相同接口。"
  def now(_), do: System.monotonic_time(:microsecond)
  @doc "安排下一次公共 tick。"
  def schedule(_, pid, delay), do: Process.send_after(pid, :tick, delay)
  @doc "读取本运行时注入的单调时钟。"
  def monotonic(%{clock: {module, ref}}), do: module.now(ref)
  @doc "同一样本的服务器时间与公共时钟tick；不使用玩家的旧消费水位。"
  def sample(state) do
    mono = monotonic(state)
    {state.time_origin + mono - state.time_mono_origin, due_tick(state, mono)}
  end
  @doc "公共时钟尚未建立时保持tick零。"
  def due_tick(%{mono_origin: nil}, _), do: 0
  def due_tick(state, mono), do: max(0, div((mono - state.mono_origin) * 60, 1_000_000))
  @doc "固定步整数微秒deadline，向上取整防止早调度。"
  def deadline(state, tick), do: state.mono_origin + div(tick * 1_000_000 + 59, 60)

  @doc "将源 tick 映射到接收 Scene；偏移为源零点减接收零点的微秒差，保留历史年龄。"
  def translate_tick(tick, origin_offset_us),
    do: tick + Integer.floor_div(origin_offset_us * 60, 1_000_000)

  @doc "已初始化 Scene 的 tick 零点，沿现有单调映射表达为服务器时间。"
  def origin_us(state), do: state.time_origin + state.mono_origin - state.time_mono_origin
end
