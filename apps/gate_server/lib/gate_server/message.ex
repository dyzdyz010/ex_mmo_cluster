defmodule GateServer.Message do
  require Logger

  def parse(raw, state) do
    data = String.trim(raw)
    case state.status do
      :waiting_auth -> parse_auth(data)
      :test -> parse_test(data)
    end
  end

  @spec dispatch_msg(any) :: :ok
  def dispatch_msg(payload) do
    Logger.info("dispatch_msg: #{inspect(payload, pretty: true)}")

    :ok
  end

  def handle(%Packet{payload: {:credentials, credential}}, state, connection) do
    auth_server = GenServer.call(GateServer.Interface, :auth_server)
    case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:login, credential}) do
      {:ok, agent} ->
        GenServer.cast(connection, {:send, "ok"})
        {:ok, %{state | agent: agent}}
      {:error, :mismatch} ->
        GenServer.cast(connection, {:send, "mismatch"})
        {:ok,state}
      _ -> GenServer.cast(connection, {:send, "server error"})
      {:ok,state}
    end
  end
  def handle(%Packet{payload: _}, _state, connection) do
    GenServer.cast(connection, {:send, "ok"})
  end

  defp parse_test(data) do
    IO.inspect(data)
    plist = String.split(data, ";")
    username = plist |> Enum.at(0) |> String.split("=") |> Enum.at(1)
    password = plist |> Enum.at(1) |> String.split("=") |> Enum.at(1)

    %{username: username, password: password}
  end

  defp parse_auth(data) do
    Packet.decode(data)
  end
end
