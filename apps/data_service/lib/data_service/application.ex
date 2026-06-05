defmodule DataService.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      [
        DataService.Repo,
        interface_child(),
        # NOTE: 旧的 DataService.DispatcherSup（Dispatcher GenServer + poolboy
        # worker 池）已删除。账号/角色访问现在由 DataService.Worker 的无状态
        # 函数直接走 Ecto 连接池，不再需要在其上叠加冗余串行层与第二个池。
        {DataService.UidGenerator, name: DataService.UidGenerator},
        {DataService.Voxel.WriteTokenStore, name: DataService.Voxel.WriteTokenStore}
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DataService.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp interface_child do
    if @is_test_build do
      nil
    else
      {DataService.InterfaceSup, name: DataService.InterfaceSup}
    end
  end
end
