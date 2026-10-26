defmodule VoxelRegion.World.Canopy do
  @moduledoc "从现存宏格归属派生通用树冠锚点和去叶呈现残余；不保存第二份占用，不读模板几何。"
  import Bitwise
  import VoxelRegion.World.Canonical
  alias MmoContracts.Voxel.{Payload, Refined, Skins}
  alias VoxelRegion.{Attachments, Prefab, Reducer, Structure}

  @doc """
  区域完整XYZ跨度内的真实锚点、实例及呈现残余；返回更新后的只读来源缓存。L1–L5 由跨度覆盖的 L0 页上的树冠片段合并
  （`fragments/2`，随提交维护、按 `(level, L0 页)` 持久；M2b），不读 L0 页；L0 照旧从驻留的 L0 数据现算。
  """
  def project(state,level,region) when level>0 do
    frags=for page<-span_regions(level,region),f=Map.get(state.canopy,{level,page}),f != nil,do: f
    in_span=&Payload.in_span?(Payload.local(region,&1))
    anchors=for f<-frags,{cell,value}<-f.anchors,in_span.(at_level(cell,level)),into: %{},do: {cell,value}
    instances=Enum.reduce(frags,%{},&Map.merge(&2,&1.instances))
    ids=Refined.ancestors(instances,Enum.map(anchors,fn {_,{_,owner,_}}->owner end))
    local=fn cell->Payload.cell_index(Payload.local(region,cell)) end
    values=for f<-frags,{cell,value}<-f.residual,in_span.(cell),into: %{},do: {local.(cell),value}
    grids=for f<-frags,{cell,grid}<-f.structure,in_span.(cell),into: %{},do: {local.(cell),grid}
    {anchors,Map.take(instances,ids),values,grids,state}
  end

  def project(state,level,region) do
    {anchors,state}=Enum.reduce(candidates(state,span_regions(level,region)),{%{},state},fn {cell,owner,bindings},{acc,s}->
      if Payload.in_span?(Payload.local(region,at_level(cell,level))) and not Map.has_key?(s.refined,cell) do
        {:ok,{material,_},s}=cell_value(s,0,cell)
        case Map.fetch(bindings,material) do
          {:ok,presentation}->{Map.put(acc,cell,{material,owner,presentation}),s}
          :error->{acc,s}
        end
      else
        {acc,s}
      end
    end)
    ids=Refined.ancestors(state.instances,Enum.map(anchors,fn {_,{_,owner,_}}->owner end))
    values=Map.new(anchors,fn {cell,_}->{cell,{0,Skins.uniform(0)}} end)
    {values,grids,state}=if level==0 or map_size(anchors)==0,do: {values,%{},state},else: reduce(state,values,%{},anchors,1,level)
    local=fn cell->Payload.cell_index(Payload.local(region,cell)) end
    {anchors,Map.take(state.instances,ids),Map.new(values,fn {cell,value}->{local.(cell),value} end),
      Map.new(grids,fn {cell,grid}->{local.(cell),grid} end),state}
  end

  @doc "前后显式绑定宏格与本次编辑共享的祖格及ring；owner替换和邻格编辑都需完整后像。"
  # 第 5 级祖格（32 宏格立方）落在一个 L0 区域（64 宏格）内：与改动格共享 0..5 级祖格的绑定格只可能在改动格所在的
  # L0 区域，所以只取这些区域的绑定格（派生索引），结果与比较全世界绑定格相同。
  def affected_keys(before,state,cells) do
    # A face can change exposure across a parent boundary, including when
    # pruning removed it. Both authoritative attachment footprints matter.
    cells=(VoxelRegion.World.AttachmentOps.attachment_dirty(before,cells) ++
      VoxelRegion.World.AttachmentOps.attachment_dirty(state,cells))
      |> Enum.map(&elem(&1,1)) |> Enum.uniq()
    regions=Enum.map(cells,&region_of/1)
    bound=Enum.map(candidates(before,regions)++candidates(state,regions),&elem(&1,0)) |> Enum.uniq()
    if bound==[] do
      []
    else
      for level<-0..5,
          changed=MapSet.new(cells,&at_level(&1,level)),
          parent<-MapSet.new(bound,&at_level(&1,level)),
          MapSet.member?(changed,parent),
          key<-VoxelRegion.LogProjection.region_keys([{level,parent}]),do: key
    end |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  一个 L0 页的树冠片段（L1–L5，`%{level => 片段 | nil}`）：页内全部绑定锚点（不细分的归属宏格、材料在呈现绑定内）、其祖先实例记录副本、
  逐级去叶残余与残余 structure。与 `project/3` 的 L≥1 合并规则配对：同一级格的全部锚点都在同一 L0 页（第 5 级祖格 32 宏格 < 64），
  所以按页分片再按跨度过滤，与对整个跨度现算逐项相同。读本页、ring 邻页的附件与 0..4 级粗层值（编辑闭包已驻留）。
  """
  def fragments(state,page) do
    {anchors,state}=Enum.reduce(candidates(state,[page]),{%{},state},fn {cell,owner,bindings},{acc,s}->
      if Map.has_key?(s.refined,cell) do
        {acc,s}
      else
        {:ok,{material,_},s}=cell_value(s,0,cell)
        case Map.fetch(bindings,material) do
          {:ok,presentation}->{Map.put(acc,cell,{material,owner,presentation}),s}
          :error->{acc,s}
        end
      end
    end)
    if map_size(anchors)==0 do
      {Map.new(1..5,&{&1,nil}),state}
    else
      instances=Map.take(state.instances,Refined.ancestors(state.instances,Enum.map(anchors,fn {_,{_,owner,_}}->owner end)))
      values=Map.new(anchors,fn {cell,_}->{cell,{0,Skins.uniform(0)}} end)
      {levels,_,_,state}=Enum.reduce(1..5,{%{},values,%{},state},fn level,{acc,values,grids,s}->
        {values,grids,s}=reduce(s,values,grids,anchors,level,level)
        {Map.put(acc,level,%{anchors: anchors,instances: instances,residual: values,structure: grids}),values,grids,s}
      end)
      {levels,state}
    end
  end

  @doc """
  提交时同笔维护树冠片段（M2b，父稿 P1“随 `Canopy.affected_keys` 同笔增量维护”）：`keys` 为本笔 `affected_keys/3` 的结果，
  空即无锚点与改动共享祖格，片段不变；否则重算改动格所在、提交前后有绑定格的 L0 页，变了的片段判脏。
  """
  def refresh(_before,state,_cells,[]),do: state
  def refresh(before,state,cells,_keys) do
    cells=(VoxelRegion.World.AttachmentOps.attachment_dirty(before,cells) ++
      VoxelRegion.World.AttachmentOps.attachment_dirty(state,cells)) |> Enum.map(&elem(&1,1))
    pages=cells |> Enum.map(&region_of/1) |> Enum.uniq()
    pages=Enum.filter(pages,fn page->candidates(before,[page]) != [] or candidates(state,[page]) != [] end)
    Enum.reduce(pages,state,&put_fragments/2)
  end

  @doc "重算全部有绑定格的 L0 页的片段（迁移、离线粗层重建；O(世界)）。"
  def refresh_all(state) do
    pages=for {page,cells}<-state.macro_owner_regions,map_size(cells)>0,do: page
    stale=for {{_,page},_}<-state.canopy,uniq: true,do: page
    Enum.reduce(Enum.uniq(pages++stale),state,&put_fragments/2)
  end

  @doc "重算这些 L0 页的片段（启动重放日志后缀之后：片段不进日志，后缀写到的页要按重放结果重算）。"
  def refresh_pages(state,pages) do
    pages=Enum.filter(Enum.uniq(pages),fn page->candidates(state,[page]) != [] or
      Enum.any?(1..5,&Map.has_key?(state.canopy,{&1,page})) end)
    Enum.reduce(pages,state,&put_fragments/2)
  end

  defp put_fragments(page,state) do
    {levels,state}=fragments(state,page)
    Enum.reduce(levels,state,fn {level,fragment},s->
      key={level,page}
      if Map.get(s.canopy,key)==fragment do
        s
      else
        canopy=if fragment==nil,do: Map.delete(s.canopy,key),else: Map.put(s.canopy,key,fragment)
        VoxelRegion.World.Pages.mark(%{s | canopy: canopy},{:fragment,:canopy,key})
      end
    end)
  end

  @doc "载荷区域在 level 上的跨度（含一格 ring，level 坐标 [64r−1, 64r+65)）覆盖的 L0 区域。"
  def span_regions(level,{rx,ry,rz}) do
    scale=1 <<< level
    axis=fn r -> floor_div((64*r-1)*scale,64)..floor_div((64*r+65)*scale-1,64) end
    for x<-axis.(rx),y<-axis.(ry),z<-axis.(rz),do: {x,y,z}
  end

  defp candidates(state,regions) do
    for {cell,owner}<-macro_owners_in_regions(state,regions),
        instance=Map.fetch!(state.instances,owner),
        definition=Map.fetch!(state.prefabs,instance.definition_id).definition,
        bindings=Map.get(definition,:presentation_bindings,%{}),map_size(bindings)>0,
        do: {cell,owner,bindings}
  end

  @doc "L0 宏格在 level 级的祖格。"
  def at_level({x,y,z},level) do
    scale=1 <<< level
    {floor_div(x,scale),floor_div(y,scale),floor_div(z,scale)}
  end

  defp reduce(state,values,grids,anchors,level,last) do
    parents=Map.keys(values) |> Enum.map(&VoxelRegion.World.Edits.parent_of/1) |> Enum.uniq()
    faces=if level==1,do: Attachments.l1_faces(attachments_near_parents(state,parents),parents),else: %{}
    {next,next_grids,state}=Enum.reduce(parents,{%{},%{},state},fn parent,{next,next_grids,s}->
      children=for oct<-0..7,do: {elem(parent,0)*2+(oct &&& 1),elem(parent,1)*2+((oct >>> 1) &&& 1),elem(parent,2)*2+((oct >>> 2) &&& 1)}
      {samples,s}=Enum.map_reduce(children,s,fn cell,s->
        case Map.fetch(values,cell) do
          {:ok,value}->{value,s}
          :error->{:ok,value,s}=cell_value(s,level-1,cell);{value,s}
        end
      end)
      {material,skins}=Reducer.reduce_cell(samples,level)
      sample=fn micro,world->
        {cell,_}=Prefab.macro_slot(micro)
        if Map.has_key?(anchors,cell),do: {0,world},else: rendered_target(world,micro)
      end
      {skins,s}=if level==1,do: Attachments.project_l1(parent,skins,Map.get(faces,parent,[]),sample,s),else: {skins,s}
      {grid,s}=if Map.has_key?(s.structure,{level,parent}) do
        fine=Enum.zip(children,samples) |> Enum.map(fn {cell,{m,_}}->
          cond do
            level==1 -> Map.get(s.refined,cell,m)
            Map.has_key?(values,cell) -> Map.get(grids,cell,m)
            true -> Map.get(s.structure,{level-1,cell},m)
          end
        end)
        if level==1 do
          Structure.project_attachments(Structure.from_canonical(fine),parent,Map.get(faces,parent,[]),sample,s)
        else
          {Structure.reduce(fine),s}
        end
      else
        {nil,s}
      end
      next_grids=if grid != nil and MmoContracts.Voxel.Structure.valid?(grid),do: Map.put(next_grids,parent,grid),else: next_grids
      {Map.put(next,parent,{material,skins}),next_grids,s}
    end)
    if level==last,do: {next,next_grids,state},else: reduce(state,next,next_grids,anchors,level+1,last)
  end

  defp rendered_target(state,micro) do
    {target,state}=target_at(micro,state)
    {if(target,do: target.material,else: 0),state}
  end
end