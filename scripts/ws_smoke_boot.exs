env_int = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value -> String.to_integer(value)
  end
end

endpoint = Application.get_env(:auth_server, AuthServerWeb.Endpoint, [])
auth_port = env_int.("AUTH_PORT", 4100)
visualize_port = env_int.("VISUALIZE_PORT", 4101)
gate_tcp_port = env_int.("GATE_TCP_PORT", 29_100)
gate_udp_port = env_int.("GATE_UDP_PORT", 29_101)

Application.put_env(
  :auth_server,
  AuthServerWeb.Endpoint,
  Keyword.merge(endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: auth_port])
)

visualize_endpoint = Application.get_env(:visualize_server, VisualizeServerWeb.Endpoint, [])

Application.put_env(
  :visualize_server,
  VisualizeServerWeb.Endpoint,
  Keyword.merge(visualize_endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: visualize_port])
)

Application.put_env(:libcluster, :topologies, [])
Application.put_env(:auth_server, :dev_auto_login, true)
Application.put_env(:gate_server, :tcp_port, gate_tcp_port)
Application.put_env(:gate_server, :udp_port, gate_udp_port)

Enum.each([:data_service, :data_init, :beacon_server, :scene_server, :auth_server, :gate_server], fn app ->
  case Application.ensure_all_started(app) do
    {:ok, _} -> IO.puts("started #{app}")
    {:error, reason} -> IO.puts("failed #{app}: #{inspect(reason)}")
  end
end)

Process.sleep(:infinity)
