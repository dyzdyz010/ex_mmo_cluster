defmodule NpcServer.Genesis do
  @moduledoc """
  全局系统功能：创世能力组 `:genesis`（docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §3）。创世阶段的特权
  NPC 直接塑造地形：条目 `fill_box`（整数格闭区间全部写成一种材料）与 `set_cells`（逐格给材料）都构造同一个 Body 动词
  `genesis_edit`，Body 的执行进程把它交给 `VoxelRegion.World.apply_edits/2`——与 0x78 原始编辑后门同一个 World 入口、
  同一语义：不扣料、不记 placed_by、不查射程与保护区；液体规则与 refined 拒绝照 World。原始编辑后门保留到正式开放，
  届时创世能力随它一起收回。

  授予只有一个来源——注册表行（`NpcServer.Registry`，llm 大脑 params `genesis: true`）同时给出 `profile.genesis`
  （本组条目只在它为真时投影）与 Body 启动选项 `genesis: true`（Body 只在它为真时受理，否则 `not_permitted`）。
  Brain 是外部输入、Body 是信任边界：`prepare/3` 是 Body 受理前的唯一校验（同 `Perception.prepare/2` 之于 look）。
  条目形状与参数规格见 `NpcServer.Abilities`，命令形状见 `NpcServer.Brain`。
  """
  alias NpcServer.Perception
  alias VoxelRegion.EditBounds
  alias MmoContracts.VoxelMaterialCatalog

  # 一次 genesis_edit 最多这么多格（决策稿 §3）：一笔 World 事务的规模上限。
  @max_cells 4096
  @reach Perception.reach()

  @doc "一次 `genesis_edit` 最多的格数。"
  def max_cells, do: @max_cells

  @doc "创世条目（group `:genesis`），只在 `profile.genesis` 为真时给出；条目形状见 `NpcServer.Abilities`。"
  def entries(%{genesis: true}) do
    corner = {:tuple, [:integer, :integer, :integer]}

    limits =
      "一次最多 #{@max_cells} 格（超出回 invalid_command），每格各轴离自己不超过 #{@reach} 米（超出回 too_far，要走过去再改），" <>
        "格须在部署的编辑盒内（否则 out_of_bounds）。material 0 = 挖成空气；不扣自己的 balances，也不留放置记录（look 里没有放置者）。"

    [
      %{
        name: "fill_box",
        group: :genesis,
        description:
          "创世：把整数格闭区间 min–max（1 格 = 1 米，格 (x,y,z) 占据 [x,x+1)×[y,y+1)×[z,z+1)）里的每一格都写成 material，" <>
            "用来整平、挖空、填实一大块地形。" <> limits,
        done: "World 已提交（data.seq），玩家随即看到地形变化。",
        params: [min: corner, max: corner, material: :integer],
        build: &fill_box/2
      },
      %{
        name: "set_cells",
        group: :genesis,
        description:
          "创世：逐格写材料，cells 的每一项是 [x, y, z, material]（整数格坐标，1 格 = 1 米），用来修边、开洞、摆零散的格。" <>
            limits,
        done: "World 已提交（data.seq），玩家随即看到地形变化。",
        params: [cells: {:list, {:tuple, [:integer, :integer, :integer, :integer]}}],
        build: fn %{cells: cells}, _ ->
          %{verb: :genesis_edit, edits: for({x, y, z, m} <- cells, do: {{x, y, z}, m})}
        end
      }
    ]
  end

  def entries(_profile), do: []

  @doc """
  Body 受理 `genesis_edit` 前的唯一校验，`position` 是胶囊中心、`bounds` 是部署编辑盒：位置未知 → `:invalid_session`；
  edits 不是 1..#{@max_cells} 个 `{{x, y, z}, 材料}`（整数格；材料是目录合法 id，与 0x78 解码同一谓词）→ `:invalid_command`；
  任一格某轴离自己超过 `Perception.reach()` 米 → `:too_far`；任一格在编辑盒外 → `:out_of_bounds`（与 0x78 进 World 前的
  编辑盒门同一判定，`EditBounds.within?/2`）。全部通过回 `:ok`，不访问 World。
  """
  def prepare(nil, _bounds, _edits), do: {:error, :invalid_session}

  def prepare({px, py, pz}, bounds, edits) do
    cond do
      not (is_list(edits) and length(edits) in 1..@max_cells and Enum.all?(edits, &edit?/1)) ->
        {:error, :invalid_command}

      not Enum.all?(edits, fn {{x, y, z}, _} ->
        abs(x - px) <= @reach and abs(y - py) <= @reach and abs(z - pz) <= @reach
      end) ->
        {:error, :too_far}

      not Enum.all?(edits, fn {cell, _} -> EditBounds.within?(cell, bounds) end) ->
        {:error, :out_of_bounds}

      true ->
        :ok
    end
  end

  defp edit?({{x, y, z}, material}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: VoxelMaterialCatalog.valid_id?(material)

  defp edit?(_), do: false

  # 闭区间按 x、y、z 逐格展开（同 look）；某轴 min > max 是空盒。格数只在 prepare/3 判一次：这里只展开到上限多一格，
  # 超大的盒不必全部展开，交给 Body 照常以 invalid_command 拒绝。
  defp fill_box(%{min: {x0, y0, z0}, max: {x1, y1, z1}, material: material}, _) do
    edits =
      Stream.flat_map(x0..x1//1, fn x ->
        Stream.flat_map(y0..y1//1, fn y -> Stream.map(z0..z1//1, &{{x, y, &1}, material}) end)
      end)
      |> Enum.take(@max_cells + 1)

    %{verb: :genesis_edit, edits: edits}
  end
end
