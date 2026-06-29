node = :"dev@#{:inet.gethostname() |> elem(1)}"
log_path = "D:/dev/ex_mmo_cluster/clients/Voxia/Saved/server_observe.log"
IO.inspect(Node.connect(node), label: "connect")
r = :rpc.call(node, Application, :put_env, [:gate_server, :cli_observe_log, log_path])
IO.inspect(r, label: "put_env")
v = :rpc.call(node, Application, :get_env, [:gate_server, :cli_observe_log])
IO.inspect(v, label: "verify_get_env")
