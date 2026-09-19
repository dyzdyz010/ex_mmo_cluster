defmodule VoxelRegion.TestSupport do
  @moduledoc "只测试：World 的数据源、角色和文件日志夹具，不依赖兄弟测试的加载顺序。"
  alias MmoContracts.Voxel.{Payload, Codec}
  alias VoxelRegion.OverlayLog

  defmodule Source do
    def open(opts), do: {:ok,%{root: Keyword.fetch!(opts,:root),observer: Keyword.fetch!(opts,:observer)}}
    def content_version(_), do: 123
    def world_dir(s), do: s.root
    def generated(_), do: 0
    def ensure(s,level,region) do
      send(s.observer,{:prepared,level,region})
      :ok
    end
    def read(s,level,region) do
      if level==0 and region in [{10,0,0},{11,0,0}] do
        send(s.observer,{:region_read_started,self(),region})
        receive do :continue_region_read -> :ok after 1_000 -> :ok end
      end
      p=%Payload{level: level,region: region,cells: :binary.copy(<<0,0>>,66*66*66)}
      bytes=Payload.encode(p,%{},0,123)
      {:ok,h}=Codec.decode_payload_header(bytes)
      {:ok,bytes,h}
    end
  end

  defmodule Actor do
    use GenServer
    def start_link(state),do: GenServer.start_link(__MODULE__,state)
    def init(state),do: {:ok,state}
    def tool_context(player,id),do: GenServer.call(player,{:tool_context,id})
    def handle_call({:tool_context,id},_,%{identity: id}=state),do: {:reply,{:ok,Map.put(state,:player,self())},state}
    def handle_call({:tool_context,_},_,state),do: {:reply,{:error,:invalid_state},state}
    def handle_call({:eye,eye},_,state),do: {:reply,:ok,%{state | eye: eye}}
    def handle_call(:seal,_,state),do: {:reply,:ok,%{state | identity: :sealed}}
  end

  defmodule Log do
    defdelegate open(path,cv),to: OverlayLog.File
    defdelegate replay(path),to: OverlayLog.File
    def checkpoint(path,txn) do
      File.write!(path<>".checkpoint_calls","1",[:append])
      OverlayLog.File.checkpoint(path,txn)
    end
    def append(path,txn) do
      if File.exists?(path<>".reject"),do: {:error,:test_disk_failure},else: OverlayLog.File.append(path,txn)
    end
  end

  @doc "只测试：消费限定窗口/角色的只读契约；键表仅便于按目标身份断言，不读取进程 state。"
  def observe(world, characters, box) do
    snapshot = VoxelRegion.World.simulation_snapshot(world, characters, box)
    %{seq: snapshot.seq, damage: Map.new(snapshot.property_states, &{VoxelRegion.Damage.key(&1), &1}),
      thermal: snapshot.thermal_accounting, liquid_units: snapshot.liquid_quantities,
      phase_inventory: snapshot.phase_inventory, epochs: snapshot.epochs,
      property_digest: snapshot.property_context.digest,
      material_balances: Map.new(snapshot.material_balances, &{{&1.character, &1.material}, &1.units})}
  end

  @doc "只测试：通过正式 payload 服务观察一个区域，保留协议所有者/结构和附件表示。"
  def payload(world, level, region) do
    request = Codec.encode_request(0, [%{level: level, region: region, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    {:ok, reply} = VoxelRegion.World.serve(world, request)
    {:ok, _, [{:payload, ^level, ^region, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, payload} = Payload.decode(bytes)
    payload
  end

  @doc "固定发布样本的绝对路径，不依赖 Mix 的当前工作目录。"
  def catalog(version \\ "ade8e630274214b6d9abba77286d8a5d8625d485bd6018e92a9bf0a43d3231ba") do
    Path.expand("../../../../../Voxim/Content/Voxel/Properties/Published/#{version}.json", __DIR__)
  end

  @doc "只测试：正常采回 {-6,1,-4} 的有限作者样本，库存只能由真实工具裁决入账。"
  def mine_authored(world, cid) do
    mine_authored(world, cid, {-6, 1, -4})
  end

  @doc "只测试：独立会话从指定作者样本正常采回材料，不改写余额或裁决结果。"
  def mine_authored(world, cid, {x, y, z}, tool_id \\ 1) do
    gate = spawn_link(fn -> receive do :stop -> :ok end end)
    actor = %{cid: cid, gate: gate, identity: make_ref(), refresh: &Actor.tool_context/2,
              eye: {x + 0.0625, y + 0.0625, z - 1.9375}, tick_us: 16_667}
    {:ok, player} = Actor.start_link(actor)
    actor = Map.put(actor, :player, player)
    try do
      mine_next(world, actor, 1, tool_id)
    after
      GenServer.stop(player)
      send(gate, :stop)
    end
  end

  defp mine_next(world, actor, seq, tool_id) do
    query = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool_id,
              direction: {0.0, 0.0, 1.0}, micro: {0,0,0}, granularity: 0, incarnation: 0, owner: {0,0}, material: 0}
    case VoxelRegion.World.tool_intent(world, actor, query) do
      {:error, :no_target} -> :ok
      {:ok, target} ->
        request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
        {:ok, _} = VoxelRegion.World.tool_intent(world,
          Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}), %{request | action: 1})
        mine_next(world, actor, seq + 1, tool_id)
    end
  end
end
