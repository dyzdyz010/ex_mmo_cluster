node = :"dev@#{:inet.gethostname() |> elem(1)}"
IO.inspect(Node.connect(node), label: "connect")

# Is the scene voxel + map ledger alive?
ml = :rpc.call(node, Process, :whereis, [SceneServer.Voxel.MapLedger])
IO.inspect(ml, label: "MapLedger pid")

# How many gate connections / scene chunk processes are live?
chunk_procs =
  :rpc.call(node, Supervisor, :which_children, [SceneServer.Voxel.ChunkProcessSupervisor])

case chunk_procs do
  list when is_list(list) -> IO.puts("live ChunkProcess count = #{length(list)}")
  other -> IO.inspect(other, label: "ChunkProcessSupervisor")
end

# Sample the durable region directory existence + WorldGen sanity.
wg = :rpc.call(node, SceneServer.Voxel.WorldGen, :surface_height_at, [0, 0])
IO.inspect(wg, label: "WorldGen surface_height_at(0,0)")
