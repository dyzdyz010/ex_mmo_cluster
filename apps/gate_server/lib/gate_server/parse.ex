defmodule GateServer.Parse do
  require Logger

  def parse(raw, state) do
    data = String.trim(raw)
    case state.status do
      :waiting_auth -> parse_auth(data)
    end
  end

  defp parse_auth(data) do
    IO.inspect(data)
    plist = String.split(data, ";")
    username = plist |> Enum.at(0) |> String.split("=") |> Enum.at(1)
    password = plist |> Enum.at(1) |> String.split("=") |> Enum.at(1)

    %{username: username, password: password}
  end
end
