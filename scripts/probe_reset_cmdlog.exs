node = :"dev@#{:inet.gethostname() |> elem(1)}"
IO.inspect(Node.connect(node), label: "connect")
r = :rpc.call(node, DataService.Voxel.CommandLog, :reset, [])
IO.inspect(r, label: "command_log_reset")
