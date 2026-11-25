defmodule MmoContracts.ServerTime do
  @moduledoc """
  全局系统功能：客户端同步的服务器时间线（µs）唯一来源。值 = 本 VM 首次加载本模块时的墙钟锚点 + BEAM 单调时钟。
  Scene 移动时间回复（SessionStart／TimeReply）、World 施放记录与拟态 t0_us、投射物采样时刻都在这条线上；
  不直接读墙钟，墙钟与单调时钟漂移（2026-11-21 devenv 4.9 万 s 漂 2 s）不再拉开两端。
  测试可注入与 `now/1` 同接口的单调时钟 `{module, ref}`。
  """
  @on_load :anchor

  @doc false
  def anchor do
    if :persistent_term.get(__MODULE__, nil) == nil,
      do:
        :persistent_term.put(
          __MODULE__,
          System.system_time(:microsecond) - System.monotonic_time(:microsecond)
        )

    :ok
  end

  @doc "生产单调微秒。"
  def now(_ref), do: System.monotonic_time(:microsecond)

  @doc "注入单调时钟上的服务器时间。"
  def server_us({module, ref} \\ {__MODULE__, nil}),
    do: module.now(ref) + :persistent_term.get(__MODULE__)
end
