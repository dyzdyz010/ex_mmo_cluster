defmodule GateServer.Npc.Perception do
  @moduledoc "全局系统功能：父脑与技能共用的感知工具、范围校验及真实 World 只读入口。"
  alias VoxelRegion.World
  @cells 512
  @reach 32

  @doc "当前角色可查询的各轴距离上限，单位米。"
  def reach, do: @reach
  @doc "当前可调用的感知工具；世界写入不属于此模块。"
  def tools, do: [
      %{
        type: "function",
        name: "look",
        description:
          "看一个整数格闭区间 (x0,y0,z0)–(x1,y1,z1) 里有什么：1 格 = 1 米，格 (x,y,z) 占据 [x,x+1)×[y,y+1)×[z,z+1)。" <>
            "最多 512 格，各边离自己不超过 32 米。结果只列非空气格（按 \"x,z\" 列给出 [y, material]；有人放下的格是 [y, material, 放置者的 entity_id]，" <>
            "没有第三项表示没有放置溯源，可能是天然地形或历史／作者写入）。refined.micro_cells 给出精确 WORLD micro 坐标、材质与归属。" <>
            "仅在 bounds_macro_inclusive 内两处都没列出的才是空气；窗口外未知，附件须用 inspect。seq 是观察时的世界版本。",
        parameters: %{
          type: "object",
          properties: %{
            x0: %{type: "integer"},
            y0: %{type: "integer"},
            z0: %{type: "integer"},
            x1: %{type: "integer"},
            y1: %{type: "integer"},
            z1: %{type: "integer"}
          },
          required: ["x0", "y0", "z0", "x1", "y1", "z1"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "inspect",
        description:
          "列出周围（自己所在 64 米 tile 及相邻 tile）的附件与预制件构件：附件给 attachment_id、kind、axis、micro 坐标、material、hp、电路状态；" <>
            "构件给 instance [birth, occurrence] 与占的格。只列离自己最近的 24 件，total 是总数。detach、prefab remove / replace、对附件 use_tool 都要用这里的身份。",
        parameters: %{type: "object", properties: %{}, additionalProperties: false}
      }
  ]

  @doc "模型参数转为只读命令；坐标与预算交 prepare 校验。"
  def command("look", p), do: %{verb: :look, min: {p["x0"],p["y0"],p["z0"]}, max: {p["x1"],p["y1"],p["z1"]}}
  def command("inspect", p) when map_size(p) == 0, do: %{verb: :inspect}
  def command(_, _), do: nil

  @doc "以当前角色位置校验完整 XYZ 查询范围；非法参数不访问 World。"
  def prepare({px,py,pz}, %{verb: :look,min: {x0,y0,z0},max: {x1,y1,z1}})
      when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and
        is_integer(y1) and is_integer(z1) and x0 <= x1 and y0 <= y1 and z0 <= z1 and
        (x1-x0+1)*(y1-y0+1)*(z1-z0+1) <= @cells and
        x0 >= px-@reach and x1 <= px+@reach and y0 >= py-@reach and y1 <= py+@reach and
        z0 >= pz-@reach and z1 <= pz+@reach,
    do: {:look,for(x <- x0..x1,y <- y0..y1,z <- z0..z1,do: {x,y,z})}
  def prepare({x,y,z}, %{verb: :inspect}) do
    {rx,ry,rz} = {floor(x/64),floor(y/64),floor(z/64)}
    {:inspect,{{rx-1,ry-1,rz-1},{rx+2,ry+2,rz+2}}}
  end
  def prepare(_, _), do: nil

  @doc "读取已通过范围检查的请求；保留版本、采样范围与未观测边界。"
  def read(world, cid, {:look,cells}) do
    snapshot = World.material_snapshot(world,[cid],cells,:micro)
    lo = for axis <- 0..2, do: cells |> Enum.map(&elem(&1,axis)) |> Enum.min()
    hi = for axis <- 0..2, do: cells |> Enum.map(&elem(&1,axis)) |> Enum.max()
    {:ok,Map.merge(snapshot,%{bounds_macro_inclusive: [lo,hi],outside: :unknown,attachments: :not_sampled})}
  end
  def read(world, cid, {:inspect,box}),
    do: {:ok,World.simulation_snapshot(world,[cid],box) |> Map.take([:seq,:property_states]) |> Map.put(:bounds_region_half_open,box)}
end
