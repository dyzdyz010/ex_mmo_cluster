defmodule MmoContracts.Session.Outbound do
  @moduledoc "全局系统功能：Scene 到连接 owner 的出站消息契约；不依赖 Gate 或具体传输。"

  @doc "可靠消息保留会话身份和流语义，由连接 owner 编码发送。"
  def reliable(gate_pid, identity, stream, message) when stream in [:control, :voxel] do
    purpose = if stream == :control, do: 1, else: 2
    send(gate_pid, {:mmo_reliable, identity, purpose, message})
    :ok
  end

  @doc "投递可替换的移动样本，由连接 owner 维护发送队列。"
  def datagram(gate_pid, identity, message) do
    send(gate_pid, {:mmo_datagram, identity, message})
    :ok
  end

  @doc "只关闭指定会话身份，不影响随后重新登录的会话。"
  def close(gate_pid, identity, reason) do
    send(gate_pid, {:mmo_close, identity, reason})
    :ok
  end
end
