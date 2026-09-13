# 隔离探针：参数为旧/新 World 源码与只读导出的日志 ETF，不连接节点或数据库。
[old_source,new_source,log_etf,out | flags] = System.argv()
Code.compiler_options(ignore_module_conflict: true)
alias VoxelRegion.{World,FileStore,OverlayLog}
alias MmoContracts.Voxel.Codec

defmodule B1InteractionSource do
  def open(opts) do
    s=File.read!("/tmp/b1-interaction-perf/source.etf") |> :erlang.binary_to_term()
    {:ok,Map.merge(s,%{log_root: Keyword.fetch!(opts,:log_root),observer: Keyword.fetch!(opts,:observer)})}
  end
  def content_version(s),do: s.content_version
  def world_dir(s),do: s.log_root
  def generated(_s),do: 0
  def ensure(_s,_l,_r),do: :ok
  def read(s,l,r) do
    send(s.observer,{:reading,self(),l,r})
    # 严禁生成或写入正在使用的 baseline；均匀区域只合成内存载荷。
    case VoxelRegion.GeneratedStore.classify(s,l,r) do
      {:uniform,_} -> VoxelRegion.GeneratedStore.read(s,l,r)
      :mixed ->
        true=File.exists?(VoxelRegion.GeneratedStore.path(s,l,r))
        VoxelRegion.GeneratedStore.read(s,l,r)
    end
  end
end

defmodule B1InteractionProbe do
  def drain do
    receive do _ -> drain() after 0 -> :ok end
  end
  def edit(w,material) do
    parent=self()
    started=System.monotonic_time(:microsecond)
    spawn_link(fn -> send(parent,{:edit_reply,VoxelRegion.World.apply_edit(w,{40,510,61},material),System.monotonic_time(:microsecond)}) end)
    receive do
      {:voxel_log_transaction_payload,bytes} ->
        broadcast=System.monotonic_time(:microsecond)
        receive do
          {:edit_reply,{:ok,seq},finished} ->
            %{seq: seq,wall_us: finished-started,broadcast_us: broadcast-started,tail_us: finished-broadcast,
              geometry_bytes: byte_size(bytes),geometry_sha256: :crypto.hash(:sha256,bytes) |> Base.encode16(case: :lower)}
        after 120_000 -> raise "edit timeout" end
    after 120_000 -> raise "broadcast timeout" end
  end
end

txns=log_etf |> File.read!() |> :erlang.binary_to_term()
cv=2696305293671044687
results=for {label,source} <- [{"before",old_source},{"after",new_source}] do
  if "--payload" in flags,do: Code.compile_file(Path.join(Path.dirname(source),"payload.ex"))
  Code.compile_file(source)
  root=Path.join(out,label)
  File.mkdir_p!(root)
  log=OverlayLog.File.open(root,cv)
  File.write!(log,<<>>)
  for txn <- txns,do: OverlayLog.File.append(log,txn)
  {startup_us,{:ok,w}}=:timer.tc(fn -> World.start_link(source: B1InteractionSource,root: "/demo/world",log_root: root,
    observer: self(),name: nil,log: OverlayLog.File,prefab_catalog_path: "/demo/r7-prefabs",
    property_catalog_path: "/demo/r7-b1/7c11b53fc05fe91d70e80a278d3ecfa57fff0bdd80004232baf24219f10f7ce9.json") end)
  start_seq=World.seq(w)
  World.subscribe(w,self(),start_seq,{{-10,-10,-10},{10,20,10}},0)
  if "--replica" in flags do
    {:ok,_}=World.replica_snapshot_and_subscribe(w,{{0,7,0},{1,8,1}},self())
  end
  B1InteractionProbe.drain()
  placed=B1InteractionProbe.edit(w,19)
  destroyed=B1InteractionProbe.edit(w,0)
  # 新区域不在初始化缓存中，整批32个公开载荷走真实 GeneratedStore 校验与 World 编码。
  cached=:sys.get_state(w).payloads
  items=Path.wildcard("/demo/world/"<>FileStore.hex(cv)<>"/baseline/L0/*.vxr")
    |> Enum.map(fn path -> [_,x,y,z]=Regex.run(~r/r_(-?\d+)_(-?\d+)_(-?\d+)\.vxr$/,path)
      {String.to_integer(x),String.to_integer(y),String.to_integer(z)} end)
    |> Enum.reject(&Map.has_key?(cached,{0,&1})) |> Enum.take(32)
    |> Enum.map(&%{level: 0,region: &1,have_seq: 0,have_hash: 0})
  request=Codec.encode_request(0,items) |> IO.iodata_to_binary()
  B1InteractionProbe.drain()
  parent=self()
  spawn_link(fn -> {elapsed,result}=:timer.tc(fn -> World.serve(w,request) end); send(parent,{:served,elapsed,result}) end)
  receive do {:reading,^w,_,_} -> :ok after 5_000 -> raise "no cold read" end
  {admission_us,_}=:timer.tc(fn -> GenServer.call(w,{:tool_range,1},60_000) end)
  batch=receive do {:served,elapsed,{:ok,bytes}} ->
    %{regions: length(items),wall_us: elapsed,tool_admission_us: admission_us,response_bytes: IO.iodata_length(bytes),
      sha256: :crypto.hash(:sha256,IO.iodata_to_binary(bytes)) |> Base.encode16(case: :lower)}
    after 60_000 -> raise "serve timeout" end
  GenServer.stop(w)
  %{version: label,replica: "--replica" in flags,source_seq: start_seq,startup_us: startup_us,placed: placed,destroyed: destroyed,cold_batch: batch}
end
File.write!(Path.join(out,"results.json"),Jason.encode!(results,pretty: true))
IO.puts(Jason.encode!(results,pretty: true))
