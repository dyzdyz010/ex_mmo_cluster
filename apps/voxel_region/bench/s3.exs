alias VoxelRegion.{FileStore, World}
alias MmoContracts.Voxel.{Codec}
cv = 0x5333
base = Path.expand(".demo/observe/voxim-s3-#{System.system_time(:millisecond)}")
File.mkdir_p!(base)
cells = :binary.copy(<<11::16-little>>, 66*66*66)
results = for radius <- [0,5,20,50] do
  root = Path.join(base,"r#{radius}")
  for level <- 0..5 do
    dir = Path.join([root,FileStore.hex(cv),"L#{level}"])
    File.mkdir_p!(dir)
    ext = min(Integer.pow(2, level),4)
    raw = <<66*66*66::32-little,cells::binary,66::32-little,66::32-little,66::32-little,ext::32-little,
            0::32-little,0::32-little,0::32-little,0::32-little,0::32-little,0::32-little>>
    for z <- -1..1,y <- -1..1,x <- -1..1 do
      File.write!(FileStore.path(root,cv,level,{x,y,z}),Codec.encode_payload(level,{x,y,z},0,cv,raw))
    end
  end
  {:ok,pid}=World.start_link(root: root,name: :bench)
  edits=for z <- -radius..radius,y <- -radius..radius,x <- -radius..radius,x*x+y*y+z*z <= radius*radius,do: {{32+x,32+y,32+z},0}
  :ok=World.subscribe(:bench,self(),0,{{-1,-1,-1},{1,1,1}},1)
  {cpu0,_}=:erlang.statistics(:runtime)
  {us,{:ok,1}}=:timer.tc(fn -> World.apply_edits(:bench,edits) end)
  {cpu1,_}=:erlang.statistics(:runtime)
  txn=receive do {:voxel_log_transaction_payload,bytes} -> {:ok,t}=Codec.decode_transaction(bytes); t end
  state=:sys.get_state(pid)
  sparse_bytes=Enum.reduce(state.overlay,16,fn {{level,cell},{m,skins}},n ->
    if level==0 do
      n+28
    else
      n+IO.iodata_length(Codec.encode_coarse(%{level: level,cell: cell,material: m,skins: skins}))
    end
  end)
  items=Enum.map(Map.keys(state.overlay_regions),fn {level,region} ->
    case FileStore.read(root,cv,level,region) do
      {:ok,_,h}->%{level: level,region: region,have_seq: 0,have_hash: h.hash}
      _->nil
    end
  end) |> Enum.reject(&is_nil/1)
  {:ok,http}=World.serve(:bench,Codec.encode_request(cv,items)|>IO.iodata_to_binary())
  result=%{radius: radius,cells: length(edits),elapsed_ms: us/1000,cpu_ms: cpu1-cpu0,
    wire_bytes: IO.iodata_length(Codec.encode_transaction(txn))+1,sparse_bytes: sparse_bytes,
    region_entries: Enum.count(txn.entries,&Map.has_key?(&1,:payload)),coarse: length(txn.coarse),
    http_resend_bytes: IO.iodata_length(http),http_regions: length(items),journal_bytes: File.stat!(state.log_path).size}
  IO.inspect(result,label: "S3_BENCH",limit: :infinity)
  GenServer.stop(pid)
  result
end
File.write!(Path.join(base,"results.term"),inspect(results,pretty: true,limit: :infinity))
IO.puts("S3_ARTIFACTS #{base}")

