defmodule VoxelRegion.Prefab do
  @moduledoc "VXPD v1 发布 DAG；冻结内容、preorder occurrence 与 A0 整数体积变换。"
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

  def decode(<<"VXPD",1::32-little,n::32-little,body::binary-size(n*14),count::32-little,children::binary-size(count*49)>>) when n+count > 0 do
    cells = for <<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little <- body>>, do: {{x,y,z},m}
    refs = for <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,o::8 <- children>>,
      do: %{slot: slot,definition_id: id,anchor: {x,y,z},orientation: o}
    coords = Enum.map(cells,&elem(&1,0))
    slots = Enum.map(refs,& &1.slot)
    if coords == Enum.sort(Enum.uniq(coords)) and slots == Enum.sort(Enum.uniq(slots)) and
       Enum.all?(cells,fn {_,m} -> m != 0 and VoxelMaterialCatalog.valid_id?(m) end) and Enum.all?(refs,&(&1.orientation < 24)),
      do: {:ok,%{cells: cells,children: refs}}, else: {:error,:invalid_definition}
  end
  def decode(_), do: {:error,:invalid_definition}

  def publish(definitions) do
    Enum.reduce_while(definitions,{:ok,%{}},fn {id,_},{:ok,catalog} ->
      with :ok <- references(definitions,id,MapSet.new()),
           nodes = expand_definition(definitions,id,{0,0,0},0,nil,0,[]) |> elem(0),
           cells = Enum.flat_map(nodes,& &1.cells),
           true <- length(cells) == MapSet.size(MapSet.new(Enum.map(cells,&elem(&1,0)))) do
        {:cont,{:ok,Map.put(catalog,id,%{nodes: nodes,cells: cells})}}
      else
        false -> {:halt,{:error,:overlapping_definition}}
        error -> {:halt,error}
      end
    end)
  end

  defp references(definitions,id,path) do
    cond do
      MapSet.member?(path,id) -> {:error,:definition_cycle}
      not Map.has_key?(definitions,id) -> {:error,:definition_not_found}
      true -> Enum.reduce_while(definitions[id].children,:ok,fn child,:ok ->
        case references(definitions,child.definition_id,MapSet.put(path,id)) do
          :ok -> {:cont,:ok}
          error -> {:halt,error}
        end
      end)
    end
  end

  defp expand_definition(definitions,id,anchor,orientation,parent,slot,nodes) do
    index = length(nodes)
    definition = Map.fetch!(definitions,id)
    node = %{definition_id: id,anchor: anchor,orientation: orientation,parent: parent,component_slot: slot,
      cells: footprint(definition,anchor,orientation)}
    Enum.reduce(definition.children,{nodes ++ [node],index},fn child,{nodes,_} ->
      {nodes,_} = expand_definition(definitions,child.definition_id,point(child.anchor,anchor,orientation),
        compose(orientation,child.orientation),index,child.slot,nodes)
      {nodes,index}
    end)
  end

  def occurrences(%{nodes: nodes},anchor,orientation,birth,parent_id \\ {0,0},slot \\ 0) do
    nodes |> Enum.with_index() |> Enum.map(fn {node,index} ->
      parent = if node.parent == nil, do: parent_id, else: {birth,node.parent}
      metadata = %{definition_id: node.definition_id,anchor: point(node.anchor,anchor,orientation),
        orientation: compose(orientation,node.orientation),parent_id: parent,
        component_slot: if(node.parent == nil,do: slot,else: node.component_slot)}
      {{birth,index},metadata,footprint(node.cells,anchor,orientation)}
    end)
  end

  def footprint(%{cells: cells},anchor,orientation), do: footprint(cells,anchor,orientation)
  def footprint(cells, anchor, orientation) when orientation in 0..23 do
    rows = rotation(orientation)
    Enum.map(cells,fn {cell,m} ->
      cell = rows |> Enum.with_index() |> Enum.map(fn {{a,b,c},i} ->
        elem(anchor,i)+a*elem(cell,0)+b*elem(cell,1)+c*elem(cell,2)+if(a == -1 or b == -1 or c == -1,do: -1,else: 0)
      end) |> List.to_tuple()
      {cell,m}
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

  def macro_slot({x,y,z}) do
    n = VoxelRegion.Spatial.micro_resolution()
    macro = {Integer.floor_div(x,n),Integer.floor_div(y,n),Integer.floor_div(z,n)}
    slot = Integer.mod(x,n)+n*(Integer.mod(y,n)+n*Integer.mod(z,n))
    {macro,slot}
  end
end
