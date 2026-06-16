defmodule SceneServer.Voxel.TagPhysics do
  @moduledoc """
  声明式「tag → 物理属性」绑定(功能完善 · 正交架构 S3 Part A)。

  把"哪些 tag 蕴含哪些物理属性"从硬编码的碰撞分支里抽出来,集中成一张**append-only 数据表**。
  碰撞/渲染等系统读这张表而不是写死某个具体 tag,任何未来「可通行态」(开启的门/闸门、被打穿的墙)
  只需把其 tag 名加进 `@passable_tag_names`,不改碰撞代码。

  S3 只做 **passability**:带任一「可通行」tag 的实心格在碰撞查询里视为可穿行。后续可同表扩展
  transparent(透光)、porous(流体可渗)等,各自一个属性 + 一个 tag 名集,机制相同。

  tag 用**名引用**(稳定),运行时经 `TagCatalog` 解析为 id;名→id 解析失败的 tag 直接忽略
  (惰性安全:未注册 tag 不赋予任何物理属性)。
  """

  alias SceneServer.Voxel.TagCatalog

  # 蕴含「可通行」物理属性的 tag 名(append-only)。:open = 通电门/机关已开。
  @passable_tag_names ["open"]

  @doc "蕴含可通行属性的 tag 名(append-only)。"
  @spec passable_tag_names() :: [String.t()]
  def passable_tag_names, do: @passable_tag_names

  @doc """
  当前已注册的「可通行」tag id 集合(经 TagCatalog 解析名→id;未注册的名忽略)。

  解析依赖运行中的 `TagCatalog`(同 ChunkProcess 既有 `:open` 解析路径);无对应 id 的名不计入。
  """
  @spec passable_tag_ids() :: MapSet.t(non_neg_integer())
  def passable_tag_ids do
    @passable_tag_names
    |> Enum.flat_map(fn name ->
      case TagCatalog.lookup_by_name(name) do
        {:ok, id, _defn} -> [id]
        _other -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  一组 cell tag id 是否蕴含「可通行」(任一 ∈ 可通行 tag id 集)。

  入参是某 cell 已解析的 tag id 列表(由调用方从 tag_set_ref 解析,保持 Storage tag 表归属在调用方)。
  空列表 → 不可通行(快路径,无 tag 的绝大多数实心格不必解析)。
  """
  @spec passable?(Enumerable.t()) :: boolean()
  def passable?(tag_ids) do
    case tag_ids do
      [] ->
        false

      ids ->
        passable = passable_tag_ids()
        Enum.any?(ids, &MapSet.member?(passable, &1))
    end
  end
end
