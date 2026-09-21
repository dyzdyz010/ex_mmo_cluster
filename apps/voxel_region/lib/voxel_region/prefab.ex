defmodule VoxelRegion.Prefab do
  @moduledoc "全局系统功能：VXPD v1–v3 发布 DAG；micro、宏格和初始附件共用 preorder occurrence，实际状态归 World。"
  alias MmoContracts.VoxelMaterialCatalog
  @runtime_limits [macro_cells: {512,:macro_cell_limit},micro_cells: {8192,:micro_cell_limit},
    nodes: {64,:node_limit},depth: {8,:depth_limit},attachment_slots: {8192,:attachment_slot_limit}]
  @runtime_bytes 24 + 14*(elem(@runtime_limits[:macro_cells],0)+elem(@runtime_limits[:micro_cells],0)) +
    49*(elem(@runtime_limits[:nodes],0)-1) + 21*elem(@runtime_limits[:attachment_slots],0)
  @runtime_extent 16 * VoxelRegion.Spatial.micro_resolution()

  @doc "工作台与发布入口共用的运行时预算；作者目录不受这些预算限制。"
  def limits, do: Map.new(@runtime_limits,fn {key,{limit,_}} -> {key,limit} end)
    |> Map.merge(%{extent_micro: @runtime_extent,bytes: @runtime_bytes})

  def load(path), do: load(path,nil)
  def load(path,runtime_path) do
    runtime = if runtime_path != nil and File.exists?(runtime_path),do: read_definitions(runtime_path),else: %{}
    {:ok,catalog} = publish(Map.merge(read_definitions(path),runtime))
    catalog
  end

  defp read_definitions(nil),do: %{}
  defp read_definitions(path) do
    File.ls!(path) |> Enum.filter(&(Path.extname(&1) == ".vxpd")) |> Map.new(fn name ->
      bytes = File.read!(Path.join(path,name))
      {:ok, definition} = decode(bytes)
      {:crypto.hash(:sha256,bytes),definition}
    end)
  end

  @doc "唯一VXPD v3编码；草稿排序后按内容寻址，不重排已发布v1/v2字节。"
  def encode(definition) do
    cells=Enum.sort(definition.cells)
    macros=Enum.sort(Map.get(definition,:macro_cells,[]))
    children=Enum.sort_by(definition.children,& &1.slot)
    attachments=Enum.sort_by(Map.get(definition,:attachments,[]),& &1.slot)
    IO.iodata_to_binary([<<"VXPD",3::32-little,length(cells)::32-little>>,encode_cells(cells),
      <<length(children)::32-little>>,
      for(%{slot: slot,definition_id: id,anchor: {x,y,z},orientation: o} <- children,
        do: <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,o>>),
      <<length(attachments)::32-little>>,
      for(%{slot: slot,kind: kind,axis: axis,anchor: {x,y,z},size: size,material: m} <- attachments,
        do: <<slot::32-little,kind,axis,x::signed-little-32,y::signed-little-32,z::signed-little-32,size,m::16-little>>),
      <<length(macros)::32-little>>,encode_cells(macros)])
  end

  defp encode_cells(cells),do: for({{x,y,z},m} <- cells,do: <<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little>>)

  def decode(bytes),do: decode_definition(bytes,false)
  defp decode_definition(<<"VXPD",version::32-little,n::32-little,body::binary-size(n*14),count::32-little,children::binary-size(count*49),tail::binary>>,bounded) when version in [1,2,3] do
    with :ok <- count_limit(:micro_cells,n,bounded),
         :ok <- count_limit(:nodes,count+1,bounded),
         {:ok,attachments,macro_cells} <- decode_tail(version,tail,bounded) do
    cells=decode_cells(body)
    refs = for <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,o::8 <- children>>,
      do: %{slot: slot,definition_id: id,anchor: {x,y,z},orientation: o}
    slots = Enum.map(refs,& &1.slot)
    with true <- n+count+length(attachments)+length(macro_cells)>0 and valid_cells?(cells) and valid_cells?(macro_cells) and
       slots == Enum.sort(Enum.uniq(slots)) and Enum.all?(refs,&(&1.orientation < 24)),
       do: {:ok,%{cells: cells,macro_cells: macro_cells,children: refs,attachments: attachments}}, else: (_ -> {:error,:invalid_definition})
    end
  end
  defp decode_definition(_,_), do: {:error,:invalid_definition}

  defp decode_cells(body), do: for(<<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little <- body>>, do: {{x,y,z},m})
  defp valid_cells?(cells) do
    coords = Enum.map(cells,&elem(&1,0))
    coords == Enum.sort(Enum.uniq(coords)) and Enum.all?(cells,fn {_,m} -> m != 0 and VoxelMaterialCatalog.valid_id?(m) end)
  end

  defp decode_tail(1,<<>>,_),do: {:ok,[],[]}
  defp decode_tail(version,<<n::32-little,body::binary-size(n*21),tail::binary>>,bounded) when version in [2,3] do
    with :ok <- count_limit(:attachment_slots,n,bounded),
         {:ok,attachments} <- decode_attachments(body),
         {:ok,macro_cells} <- decode_macros(version,tail,bounded),
         do: {:ok,attachments,macro_cells}
  end
  defp decode_tail(_,_,_),do: {:error,:invalid_definition}
  defp decode_macros(2,<<>>,_),do: {:ok,[]}
  defp decode_macros(3,<<n::32-little,body::binary>>,bounded) when byte_size(body)==n*14 do
    with :ok <- count_limit(:macro_cells,n,bounded),do: {:ok,decode_cells(body)}
  end
  defp decode_macros(_,_,_),do: {:error,:invalid_definition}

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
      case publish_one(definitions,id) do
        {:ok,compiled} -> {:cont,{:ok,Map.put(catalog,id,compiled)}}
        error -> {:halt,error}
      end
    end)
  end

  defp publish_one(definitions,id) do
    with {:ok,_} <- references(definitions,id,MapSet.new()),
           nodes = expand_definition(definitions,id,{0,0,0},0,nil,0,[]) |> elem(0),
           cells = Enum.flat_map(nodes,& &1.cells),
           macros = Enum.flat_map(nodes,& &1.macro_cells),
           true <- nonoverlapping?(cells,macros),
           :ok <- attachment_definition(nodes,cells,macros) do
        # 发布目录长期不变；节点体素保存为二进制，避免每次世界 GC 扫描展开坐标。
      summary=compiled_summary(nodes)
      nodes = Enum.map(nodes,fn node -> %{node | cells: :erlang.term_to_binary(node.cells),macro_cells: :erlang.term_to_binary(node.macro_cells)} end)
      {:ok,%{nodes: nodes,has_macro_cells: macros != [],definition: Map.fetch!(definitions,id),summary: summary}}
    else
      false -> {:error,:overlapping_definition}
      error -> error
    end
  end

  @doc "运行时单根发布边界：先按每次引用合并预算与包围盒，再展开和验证实际几何。"
  def compile(bytes,_catalog) when is_binary(bytes) and byte_size(bytes) > @runtime_bytes,
    do: {:error,:definition_bytes_limit}
  def compile(bytes,catalog) when is_binary(bytes) do
    with {:ok,definition} <- decode_definition(bytes,true),
         {:ok,_summary} <- runtime_summary(definition,catalog),
         id = :crypto.hash(:sha256,bytes),
         definitions = Map.new(catalog,fn {key,value} -> {key,value.definition} end) |> Map.put(id,definition),
         {:ok,compiled} <- publish_one(definitions,id),
         do: {:ok,id,compiled}
  end
  def compile(_,_),do: {:error,:invalid_definition}

  defp count_limit(_,_,false),do: :ok
  defp count_limit(field,count,true) do
    {limit,reason}=Keyword.fetch!(@runtime_limits,field)
    if count<=limit,do: :ok,else: {:error,reason}
  end

  defp summary_limit(summary) do
    result=Enum.reduce_while(@runtime_limits,:ok,fn {key,_},:ok ->
      case count_limit(key,Map.fetch!(summary,key),true) do
        :ok -> {:cont,:ok}
        error -> {:halt,error}
      end
    end)
    case {result,summary.bounds} do
      {:ok,{lo,hi}} -> if Enum.all?(0..2,&(elem(hi,&1)-elem(lo,&1)<=@runtime_extent)),do: :ok,else: {:error,:bounds_limit}
      _ -> result
    end
  end

  defp runtime_summary(definition,catalog) do
    summary=local_summary(definition)
    with :ok <- summary_limit(summary) do
      Enum.reduce_while(definition.children,{:ok,summary},fn child,{:ok,summary} ->
        case Map.fetch(catalog,child.definition_id) do
          :error -> {:halt,{:error,:definition_not_found}}
          {:ok,compiled} ->
            summary=merge_summary(summary,compiled.summary,child.anchor,child.orientation)
            case summary_limit(summary) do
              :ok -> {:cont,{:ok,summary}}
              error -> {:halt,error}
            end
        end
      end)
    end
  end

  defp local_summary(definition) do
    macros=Map.get(definition,:macro_cells,[])
    attachments=Map.get(definition,:attachments,[])
    bounds=Enum.reduce(attachments,volume_bounds(definition.cells,macros),fn g,bounds ->
      union_bounds(bounds,slot_bounds(g.kind,g.axis,g.anchor,g.size))
    end)
    %{macro_cells: length(macros),micro_cells: length(definition.cells),nodes: 1,depth: 1,bounds: bounds,
      attachment_slots: Enum.sum(Enum.map(attachments,fn g -> if g.kind==0,do: g.size*g.size,else: g.size end))}
  end

  defp merge_summary(parent,child,anchor,orientation) do
    merged=Enum.reduce([:macro_cells,:micro_cells,:nodes,:attachment_slots],parent,fn key,s -> Map.update!(s,key,&(&1+Map.fetch!(child,key))) end)
    %{merged | depth: max(parent.depth,child.depth+1),bounds: union_bounds(parent.bounds,transform_bounds(child.bounds,anchor,orientation))}
  end

  defp compiled_summary(nodes) do
    {summary,_depths}=Enum.with_index(nodes) |> Enum.reduce({%{macro_cells: 0,micro_cells: 0,nodes: length(nodes),depth: 0,bounds: nil,attachment_slots: 0},%{}},fn {node,index},{s,depths} ->
      depth=if node.parent==nil,do: 1,else: Map.fetch!(depths,node.parent)+1
      slots=for g<-node.attachments,slot<-g.slots,do: slot
      bounds=Enum.reduce(slots,volume_bounds(node.cells,node.macro_cells),fn {kind,axis,p},b -> union_bounds(b,slot_bounds(kind,axis,p,1)) end)
      {%{s | macro_cells: s.macro_cells+length(node.macro_cells),micro_cells: s.micro_cells+length(node.cells),
        depth: max(s.depth,depth),bounds: union_bounds(s.bounds,bounds),attachment_slots: s.attachment_slots+length(slots)},Map.put(depths,index,depth)}
    end)
    summary
  end

  defp volume_bounds(cells,macros) do
    Enum.reduce([{cells,1},{macros,VoxelRegion.Spatial.micro_resolution()}],nil,fn {cells,scale},bounds ->
      Enum.reduce(cells,bounds,fn {p,_},bounds ->
        lo=for i<-0..2,do: elem(p,i)*scale
        hi=Enum.map(lo,&(&1+scale))
        union_bounds(bounds,{List.to_tuple(lo),List.to_tuple(hi)})
      end)
    end)
  end
  defp slot_bounds(kind,axis,p,size) do
    hi=for i<-0..2,do: elem(p,i)+if((kind==0 and i != axis) or (kind==1 and i==axis),do: size,else: 0)
    {p,List.to_tuple(hi)}
  end
  defp transform_bounds(nil,_,_),do: nil
  defp transform_bounds({lo,hi},anchor,orientation) do
    for x<-[elem(lo,0),elem(hi,0)],y<-[elem(lo,1),elem(hi,1)],z<-[elem(lo,2),elem(hi,2)],reduce: nil do
      bounds -> p=point({x,y,z},anchor,orientation); union_bounds(bounds,{p,p})
    end
  end
  defp union_bounds(nil,b),do: b
  defp union_bounds(a,nil),do: a
  defp union_bounds({a,b},{c,d}),do: {List.to_tuple(for i<-0..2,do: min(elem(a,i),elem(c,i))),List.to_tuple(for i<-0..2,do: max(elem(b,i),elem(d,i)))}

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
