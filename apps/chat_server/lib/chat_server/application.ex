defmodule ChatServer.Application do
  @moduledoc """
  Starts the standalone MMO chat runtime.

  Chat owns channel membership, delivery policy, message history, and
  observable chat events. Gate forwards authenticated chat intents here; Scene
  can provide AOI hints later, but it does not own chat truth.
  """

  use Application

  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      [
        {DynamicSupervisor, strategy: :one_for_one, name: ChatServer.RuntimeShardSup},
        {ChatServer.RuntimeDirectory,
         name: ChatServer.RuntimeDirectory, runtime_supervisor: ChatServer.RuntimeShardSup},
        interface_child()
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: ChatServer.Supervisor)
  end

  defp interface_child do
    if @is_test_build do
      nil
    else
      {ChatServer.Interface, name: ChatServer.Interface}
    end
  end
end
