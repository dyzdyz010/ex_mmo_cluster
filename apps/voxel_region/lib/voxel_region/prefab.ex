defmodule VoxelRegion.Prefab do
  @moduledoc "全局系统功能：VXPD v1–v3 发布 DAG；micro、宏格和初始附件共用 preorder occurrence，实际状态归 World。"
  alias MmoContracts.VoxelMaterialCatalog

  def load(nil), do: %{}
  def load(path) do
    definitions = File.ls!(path) |> Enum.filter(&(Path.extname(&1) == ".vxpd")) |> Map.new(fn name ->
      bytes = File.read!(Path.join(path,name))
      {:ok, definition} = decode(bytes)
      {:crypto.hash(:sha256,bytes),definition}
    end)
    {:ok, catalog} = publish(definitions)
    catalog
  end

  def decode(<<"VXPD",version::32-little,n::32-little,body::binary-size(n*14),count::32-little,children::binary-size(count*49),tail::binary>>) when version in [1,2,3] do
    cells = decode_cells(body)
    refs = for <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,o::8 <- children>>,
      do: %{slot: slot,definition_id: id,anchor: {x,y,z},orientation: o}
    slots = Enum.map(refs,& &1.slot)
    with {:ok,attachments,macro_cells} <- decode_tail(version,tail),
       true <- n+count+length(attachments)+length(macro_cells)>0 and valid_cells?(cells) and valid_cells?(macro_cells) and
       slots == Enum.sort(Enum.uniq(slots)) and Enum.all?(refs,&(&1.orientation < 24)),
       do: {:ok,%{cells: cells,macro_cells: macro_cells,children: refs,attachments: attachments}}, else: (_ -> {:error,:invalid_definition})
  end
  def decode(_), do: {:error,:invalid_definition}

  defp decode_cells(body), do: for(<<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little <- body>>, do: {{x,y,z},m})
  defp valid_cells?(cells) do
    coords = Enum.map(cells,&elem(&1,0))
    coords == Enum.sort(Enum.uniq(coords)) and Enum.all?(cells,fn {_,m} -> m != 0 and VoxelMaterialCatalog.valid_id?(m) end)
  end

  defp decode_tail(1,<<>>),do: {:ok,[],[]}
  defp decode_tail(version,<<n::32-little,body::binary-size(n*21),tail::binary>>) when version in [2,3] do
    with {:ok,attachments} <- decode_attachments(body),
         {:ok,macro_cells} <- decode_macros(version,tail),
         do: {:ok,attachments,macro_cells}
  end
  defp decode_tail(_,_),do: {:error,:invalid_definition}
  defp decode_macros(2,<<>>),do: {:ok,[]}
  defp decode_macros(3,<<n::32-little,body::binary>>) when byte_size(body)==n*14,do: {:ok,decode_cells(body)}
  defp decode_macros(_,_),do: {:error,:invalid_definition}

  defp decode_attachments(body) do
    groups=for <<slot::32-little,kind,axis,x::signed-little-32,y::signed-little-32,z::signed-little-32,size,material::16-little <- body>>,
      do: %{slot: slot,kind: kind,axis: axis,anchor: {x,y,z},size: size,material: material}
    slots=Enum.map(groups,& &1.slot)
    if slots==Enum.sort(Enum.uniq(slots)) and Enum.all?(groups,fn g ->
      g.kind in [0,1] and g.axis in 0..2 and g.size in [1,VoxelRegion.Spatial.micro_resolution()] and
        MmoContracts.Voxel.Attachments.material?(g.material)
    end),do: {:ok,groups},else: {:error,:invalid_definition}
  end

  def publish(definitions) do
    Enum.reduce_while(definitions,{:ok,%{}},fn {id,_},{:ok,catalog} ->
      with {:ok,_} <- references(definitions,id,MapSet.new()),
           nodes = expand_definition(definitions,id,{0,0,0},0,nil,0,[]) |> elem(0),
           cells = Enum.flat_map(nodes,& &1.cells),
           macros = Enum.flat_map(nodes,& &1.macro_cells),
           true <- nonoverlapping?(cells,macros),
           :ok <- attachment_definition(nodes,cells,macros) do
        # 发布目录长期不变；节点体素保存为二进制，避免每次世界 GC 扫描展开坐标。
        nodes = Enum.map(nodes,fn node -> %{node | cells: :erlang.term_to_binary(node.cells),macro_cells: :erlang.term_to_binary(node.macro_cells)} end)
        {:cont,{:ok,Map.put(catalog,id,%{nodes: nodes,has_macro_cells: macros != []})}}
      else
        false -> {:halt,{:error,:overlapping_definition}}
        error -> {:halt,error}
      end
    end)
  end

  defp nonoverlapping?(cells,macros) do
    macro_coords = MapSet.new(macros, &elem(&1,0))
    length(cells) == MapSet.size(MapSet.new(cells,&elem(&1,0))) and
      length(macros) == MapSet.size(macro_coords) and
      Enum.all?(cells,fn {micro,_} -> not MapSet.member?(macro_coords,elem(macro_slot(micro),0)) end)
  end

  defp references(definitions,id,path) do
    cond do
      MapSet.member?(path,id) -> {:error,:definition_cycle}
      not Map.has_key?(definitions,id) -> {:error,:definition_not_found}
      true -> Enum.reduce_while(definitions[id].children,{:ok,Map.get(definitions[id],:macro_cells,[]) != []},fn child,{:ok,has_macros} ->
        case references(definitions,child.definition_id,MapSet.put(path,id)) do
          {:ok,child_macros} ->
            if child_macros and not Enum.all?(Tuple.to_list(child.anchor),&(rem(&1,VoxelRegion.Spatial.micro_resolution())==0)),
              do: {:halt,{:error,:misaligned}},else: {:cont,{:ok,has_macros or child_macros}}
          error -> {:halt,error}
        end
      end)
    end
  end

  defp expand_definition(definitions,id,anchor,orientation,parent,slot,nodes) do
    index = length(nodes)
    definition = Map.fetch!(definitions,id)
    node = %{definition_id: id,anchor: anchor,orientation: orientation,parent: parent,component_slot: slot,
      cells: footprint(definition,anchor,orientation),
      macro_cells: transform_macros(Map.get(definition,:macro_cells,[]),anchor,orientation),
      attachments: Enum.map(Map.get(definition,:attachments,[]),fn g ->
        %{slot: g.slot,material: g.material,slots: VoxelRegion.Attachments.footprint(g.kind,g.axis,g.anchor,g.size)
          |> Enum.map(&attachment_slot(&1,anchor,orientation))}
      end)}
    Enum.reduce(definition.children,{nodes ++ [node],index},fn child,{nodes,_} ->
      {nodes,_} = expand_definition(definitions,child.definition_id,point(child.anchor,anchor,orientation),
        compose(orientation,child.orientation),index,child.slot,nodes)
      {nodes,index}
    end)
  end

  # 用几何端点的包围盒变换面／棱，负轴只偏移有长度的轴；不套用体积格的三轴 -1。
  defp attachment_slot({kind,axis,p},anchor,orientation) do
    endpoint=for d<-0..2,into: [],do: elem(p,d)+if((kind==0 and d != axis) or (kind==1 and d==axis),do: 1,else: 0)
    a=point(p,anchor,orientation); b=point(List.to_tuple(endpoint),anchor,orientation)
    vector=point(put_elem({0,0,0},axis,1),{0,0,0},orientation)
    axis=Enum.find(0..2,&(elem(vector,&1)!=0))
    {kind,axis,List.to_tuple(for d<-0..2,do: min(elem(a,d),elem(b,d)))}
  end

  defp attachment_definition(nodes,cells,macros) do
    slots=for node<-nodes,g<-node.attachments,s<-g.slots,do: s
    samples=Map.new(cells)
    macro_samples=Map.new(macros)
    cond do
      length(slots)!=MapSet.size(MapSet.new(slots)) -> {:error,:overlapping_attachments}
      not Enum.all?(slots,fn slot -> Enum.any?(VoxelRegion.Attachments.neighbors(slot),
        &VoxelMaterialCatalog.blocks_movement?(Map.get(samples,&1,Map.get(macro_samples,elem(macro_slot(&1),0),0)))) end) -> {:error,:unsupported_attachment}
      true -> :ok
    end
  end

  @doc "定义仅在首次放置展开；绑定到同一 preorder occurrence，恢复不得调用它重建附件。"
  def attachments(%{nodes: nodes},anchor,orientation,birth) do
    for {node,index}<-Enum.with_index(nodes),g<-node.attachments,
      do: %{owner: {birth,index},slot: g.slot,material: g.material,
        slots: Enum.map(g.slots,&attachment_slot(&1,anchor,orientation))}
  end

  def occurrences(definition,anchor,orientation,birth,parent_id \\ {0,0},slot \\ 0),
    do: occurrence_rows(definition,anchor,orientation,birth,parent_id,slot,:cells)

  @doc "宏格与 micro 共用实例身份；返回宏格地址，不展开成微格。放置锚点由 World 检查对齐。"
  def macro_occurrences(definition,anchor,orientation,birth,parent_id \\ {0,0},slot \\ 0),
    do: occurrence_rows(definition,anchor,orientation,birth,parent_id,slot,:macro_cells)

  defp occurrence_rows(%{nodes: nodes},anchor,orientation,birth,parent_id,slot,field) do
    nodes |> Enum.with_index() |> Enum.map(fn {node,index} ->
      parent = if node.parent == nil, do: parent_id, else: {birth,node.parent}
      metadata = %{definition_id: node.definition_id,anchor: point(node.anchor,anchor,orientation),
        orientation: compose(orientation,node.orientation),parent_id: parent,
        component_slot: if(node.parent == nil,do: slot,else: node.component_slot)}
      cells = if field == :cells,do: footprint(node.cells,anchor,orientation),else: transform_macros(node.macro_cells,anchor,orientation)
      {{birth,index},metadata,cells}
    end)
  end

  def macro_footprint(%{nodes: nodes},anchor,orientation),
    do: Enum.flat_map(nodes,&transform_macros(&1.macro_cells,anchor,orientation))

  defp transform_macros(cells,anchor,orientation) do
    macro_anchor = anchor |> Tuple.to_list() |> Enum.map(&div(&1,VoxelRegion.Spatial.micro_resolution())) |> List.to_tuple()
    footprint(cells,macro_anchor,orientation)
  end

  def footprint(%{nodes: nodes},anchor,orientation), do: Enum.flat_map(nodes,&footprint(&1.cells,anchor,orientation))
  def footprint(cells,anchor,orientation) when is_binary(cells), do: footprint(:erlang.binary_to_term(cells),anchor,orientation)
  def footprint(%{cells: cells},anchor,orientation), do: footprint(cells,anchor,orientation)
  def footprint(cells, anchor, orientation) when orientation in 0..23 do
    # A0 旋转只交换轴并改变符号；体积反向轴的 -1 偏移在本次变换中只计算一次。
    [{ix,sx,ox},{iy,sy,oy},{iz,sz,oz}] = rotation(orientation)
      |> Enum.zip(Tuple.to_list(anchor))
      |> Enum.map(fn {row,origin} ->
        axis = Enum.find(0..2,&(elem(row,&1)!=0))
        sign = elem(row,axis)
        {axis,sign,origin+min(sign,0)}
      end)
    Enum.map(cells,fn {cell,m} ->
      {{sx*elem(cell,ix)+ox,sy*elem(cell,iy)+oy,sz*elem(cell,iz)+oz},m}
    end)
  end

  def point({x,y,z},anchor,orientation) do
    rotation(orientation) |> Enum.with_index() |> Enum.map(fn {{a,b,c},i} -> elem(anchor,i)+a*x+b*y+c*z end) |> List.to_tuple()
  end
  def compose(parent,child) do
    rows = for {a,b,c} <- rotation(parent) do
      cols = rotation(child)
      for(i <- 0..2,do: a*elem(Enum.at(cols,0),i)+b*elem(Enum.at(cols,1),i)+c*elem(Enum.at(cols,2),i)) |> List.to_tuple()
    end
    Enum.find(0..23,&(rotation(&1)==rows))
  end
  defp rotation(orientation) do
    [ax,ay] = Enum.at([
      [{1,0,0},{0,1,0}], [{1,0,0},{0,-1,0}],
      [{0,-1,0},{1,0,0}], [{0,1,0},{-1,0,0}],
      [{1,0,0},{0,0,1}], [{1,0,0},{0,0,-1}]
    ],div(orientation,4))
    ax = Enum.reduce(List.duplicate(nil,rem(orientation,4)),ax,fn _,x -> cross(x,ay) end)
    az = cross(ax,ay)
    for i <- 0..2, do: {elem(ax,i),elem(ay,i),elem(az,i)}
  end
  defp cross({a,b,c},{d,e,f}), do: {b*f-c*e,c*d-a*f,a*e-b*d}

  @doc "全局系统功能：宏格与 slot 转回 canonical 微格地址。"
  def micro_coord({x,y,z}, slot) do
    n = VoxelRegion.Spatial.micro_resolution()
    {x*n+rem(slot,n),y*n+rem(div(slot,n),n),z*n+div(slot,n*n)}
  end

  def macro_slot({x,y,z}) do
    n = VoxelRegion.Spatial.micro_resolution()
    macro = {Integer.floor_div(x,n),Integer.floor_div(y,n),Integer.floor_div(z,n)}
    slot = Integer.mod(x,n)+n*(Integer.mod(y,n)+n*Integer.mod(z,n))
    {macro,slot}
  end
end
