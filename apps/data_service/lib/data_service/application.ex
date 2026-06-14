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
        {DataService.DispatcherSup, name: DataService.DispatcherSup},
        {DataService.UidGenerator, name: DataService.UidGenerator}
        # 梯队4:WriteTokenStore 兼容垫片(空 GenServer)已移除——fence 真相在 Postgres,模块级无状态调用。
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
