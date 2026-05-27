env_int = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value -> String.to_integer(value)
  end
end

endpoint = Application.get_env(:auth_server, AuthServerWeb.Endpoint, [])
auth_port = env_int.("AUTH_PORT", 20000)
visualize_port = env_int.("VISUALIZE_PORT", 20001)
gate_tcp_port = env_int.("GATE_TCP_PORT", 20_002)
gate_udp_port = env_int.("GATE_UDP_PORT", 20_003)

Application.put_env(
  :auth_server,
  AuthServerWeb.Endpoint,
  Keyword.merge(endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: auth_port]
  )
)

visualize_endpoint = Application.get_env(:visualize_server, VisualizeServerWeb.Endpoint, [])

Application.put_env(
  :visualize_server,
  VisualizeServerWeb.Endpoint,
  Keyword.merge(visualize_endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: visualize_port]
  )
)

Application.put_env(:libcluster, :topologies, [])
Application.put_env(:auth_server, :dev_auto_login, true)
Application.put_env(:gate_server, :tcp_port, gate_tcp_port)
Application.put_env(:gate_server, :udp_port, gate_udp_port)

Enum.each(
  [
    :data_service,
    :data_init,
    :beacon_server,
    :scene_server,
    :world_server,
    :auth_server,
    :chat_server,
    :gate_server
  ],
  fn app ->
    case Application.ensure_all_started(app) do
      {:ok, _} ->
        IO.puts("started #{app}")

      {:error, reason} ->
        raise "failed to start #{app}: #{inspect(reason)}"
    end
  end
)

wait_until = fn predicate, timeout_ms ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms

  Stream.repeatedly(fn -> System.monotonic_time(:millisecond) end)
  |> Enum.reduce_while(:timeout, fn now, _acc ->
    cond do
      predicate.() ->
        {:halt, :ok}

      now >= deadline ->
        {:halt, :timeout}

      true ->
        Process.sleep(50)
        {:cont, :timeout}
    end
  end)
end

interface_ready? = fn ->
  with pid when is_pid(pid) <- Process.whereis(GateServer.Interface),
       %{server_state: :ready, scene_server: scene, auth_server: auth}
       when not is_nil(scene) and not is_nil(auth) <- :sys.get_state(pid),
       auth_pid when is_pid(auth_pid) <- Process.whereis(AuthServer.Interface),
       %{server_state: :ready, data_service: data_service} when not is_nil(data_service) <-
         :sys.get_state(auth_pid) do
    true
  else
    _ -> false
  end
end

case wait_until.(interface_ready?, 60_000) do
  :ok -> IO.puts("interfaces ready")
  :timeout -> raise "timed out waiting for smoke interfaces"
end

if System.get_env("WS_SMOKE_PRESEED_VOXEL") == "1" do
  case WorldServer.Voxel.DevSeed.ensure_default_region(assigned_scene_node: node()) do
    {:ok, summary} ->
      IO.puts("voxel dev seed ready #{inspect(summary)}")

    {:error, reason} ->
      raise "failed to preseed smoke voxel region: #{inspect(reason)}"
  end
end

case System.get_env("WS_SMOKE_READY_FILE") do
  nil ->
    :ok

  ready_file ->
    File.mkdir_p!(Path.dirname(ready_file))
    File.write!(ready_file, "ready #{DateTime.utc_now()}\n")
end

Process.sleep(:infinity)
