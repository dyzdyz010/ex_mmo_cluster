defmodule GateServer.Application do
  @moduledoc "玩家 QUIC 连接入口。会话登记由 WorldServer 拥有，NPC 由独立 NpcServer 应用监督。"
  use Application

  # 测试显式启动所需连接夹具，避免自动监听真实 QUIC 端口。
  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      if @is_test_build do
        []
      else
        quic =
          Application.fetch_env!(:gate_server, :quic)
          |> Keyword.put(:claims, WorldServer.Session)
          |> Keyword.put(:bounds, Application.fetch_env!(:voxel_region, :edit_bounds))

        [{GateServer.Transport.QuicListener, quic}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: GateServer.Supervisor)
  end
end
