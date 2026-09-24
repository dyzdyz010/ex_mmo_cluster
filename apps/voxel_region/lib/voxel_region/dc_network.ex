defmodule VoxelRegion.DCNetwork do
  @moduledoc """
  全局系统功能：线性电阻网络的 KCL 节点求解；任意支路可带电动势（多个电源、蓄能石串并联、热电石）。

  桥（去掉后图不再连通的支路）上的电流严格为 0：割集上只有这一条支路，KCL 使它的电流为零；它两端电位差
  等于它的电动势（开路电压）。所以先去掉全部桥，只在剩下的双边连通块内消元求解，块间电位沿桥传递。
  断开的开关、悬空的导线与电池串因此严格 0 A，不交给消元（大电导网格上的舍入会留下 ~1e-8 A 的假电流）。
  """

  @doc "输入支路 a/b、欧姆 r、伏特 emf（支路电流 a→b = (V_a − V_b − emf)/r）；返回节点电压与同序支路电流。"
  def solve(edges) do
    indexed=Enum.with_index(edges)
    adjacency=Enum.reduce(indexed,%{},fn {e,i},g ->
      g |> Map.update(e.a,[{e.b,i}],&[{e.b,i}|&1]) |> Map.update(e.b,[{e.a,i}],&[{e.a,i}|&1])
    end)
    bridges=bridges(adjacency)
    inner=for {e,i}<-indexed,not MapSet.member?(bridges,i),do: {e,i}
    # 双边连通块：只经非桥支路连通的节点集合；每条非桥支路只归入它所在的块一次（保持原边序）。
    blocks=inner |> Enum.reduce(Map.new(Map.keys(adjacency),&{&1,[]}),fn {e,_},g ->
      g |> Map.update!(e.a,&[e.b|&1]) |> Map.update!(e.b,&[e.a|&1])
    end) |> components()
    owner=blocks |> Enum.with_index() |> Enum.reduce(%{},fn {nodes,c},m->Enum.reduce(nodes,m,&Map.put(&2,&1,c)) end)
    grouped=Enum.group_by(inner,fn {e,_}->Map.fetch!(owner,e.a) end)
    local=blocks |> Enum.with_index() |> Enum.reduce(%{},fn {nodes,c},volts->
      block=Map.get(grouped,c,[])
      case Enum.find(block,fn {e,_}->e.emf != 0.0 end) do
        nil -> Enum.reduce(nodes,volts,&Map.put(&2,&1,0.0))
        {source,_} -> Map.merge(volts,component(block,nodes,source.b))
      end
    end)
    volts=link(adjacency,edges,bridges,owner,blocks |> Enum.map(&MapSet.to_list/1) |> List.to_tuple(),local)
    currents=Enum.map(indexed,fn {e,i}->
      if MapSet.member?(bridges,i),do: 0.0,else: (volts[e.a]-volts[e.b]-e.emf)/e.r
    end)
    %{volts: volts,currents: currents}
  end

  # 块内电位各自以块内一点为零；沿桥从每个连通分量的一个块出发平移：桥上 i = 0，V_b = V_a − emf。
  defp link(adjacency,edges,bridges,owner,members,local) do
    tuple=List.to_tuple(edges)
    Enum.reduce(Map.keys(adjacency),{%{},MapSet.new()},fn start,{volts,seen}->
      if MapSet.member?(seen,Map.fetch!(owner,start)),do: {volts,seen},
        else: shift([{start,0.0}],adjacency,tuple,bridges,{owner,members},local,volts,MapSet.put(seen,Map.fetch!(owner,start)))
    end) |> elem(0)
  end
  defp shift([],_g,_edges,_bridges,_blocks,_local,volts,seen),do: {volts,seen}
  defp shift([{node,offset}|queue],g,edges,bridges,{owner,members}=blocks,local,volts,seen) do
    # 以入口节点定块的平移量：块内每点 = 本地电位 − 入口本地电位 + 入口绝对电位。
    base=offset-Map.fetch!(local,node)
    members=elem(members,Map.fetch!(owner,node))
    volts=Enum.reduce(members,volts,&Map.put(&2,&1,Map.fetch!(local,&1)+base))
    {queue,seen}=Enum.reduce(members,{queue,seen},fn n,acc->
      Enum.reduce(Map.fetch!(g,n),acc,fn {m,i},{q,s}->
        next=Map.fetch!(owner,m)
        if MapSet.member?(bridges,i) and not MapSet.member?(s,next) do
          e=elem(edges,i)
          # 桥 a→b：V_a − V_b = emf。
          v=if e.a==n,do: Map.fetch!(volts,n)-e.emf,else: Map.fetch!(volts,n)+e.emf
          {[{m,v}|q],MapSet.put(s,next)}
        else
          {q,s}
        end
      end)
    end)
    shift(queue,g,edges,bridges,blocks,local,volts,seen)
  end

  # Tarjan 桥：按支路编号跳过来路（平行支路不是桥）。
  defp bridges(adjacency) do
    Enum.reduce(Map.keys(adjacency),{%{},MapSet.new(),0},fn n,{order,found,t}=acc->
      if Map.has_key?(order,n),do: acc,else: (
        {order,_low,found,t}=dfs(adjacency,n,nil,order,%{},found,t)
        {order,found,t})
    end) |> elem(1)
  end
  defp dfs(g,n,via,order,low,found,t) do
    order=Map.put(order,n,t); low=Map.put(low,n,t)
    Enum.reduce(Map.fetch!(g,n),{order,low,found,t+1},fn {m,i},{order,low,found,t}->
      cond do
        i==via -> {order,low,found,t}
        Map.has_key?(order,m) -> {order,Map.update!(low,n,&min(&1,Map.fetch!(order,m))),found,t}
        true ->
          {order,low,found,t}=dfs(g,m,i,order,low,found,t)
          low=Map.update!(low,n,&min(&1,Map.fetch!(low,m)))
          found=if Map.fetch!(low,m)>Map.fetch!(order,n),do: MapSet.put(found,i),else: found
          {order,low,found,t}
      end
    end)
  end

  defp components(g),do: components(g,Map.keys(g),MapSet.new(),[])
  defp components(_g,[],_seen,result),do: result
  defp components(g,[n|rest],seen,result) do
    if MapSet.member?(seen,n),do: components(g,rest,seen,result),else:
      (nodes=walk(g,[n],MapSet.new()); components(g,rest,MapSet.union(seen,nodes),[nodes|result]))
  end
  defp walk(_g,[],seen),do: seen
  defp walk(g,[n|queue],seen) do
    if MapSet.member?(seen,n),do: walk(g,queue,seen),else: walk(g,g[n]++queue,MapSet.put(seen,n))
  end

  defp component(edges,nodes,ground) do
    matrix=for n<-nodes,n != ground,into: %{},do: {n,{%{},0.0}}
    matrix=Enum.reduce(edges,matrix,fn {e,_},m ->
      g=1.0/e.r
      m |> stamp(e.a,e.b,g,g*e.emf,ground) |> stamp(e.b,e.a,g,-g*e.emf,ground)
    end)
    eliminate(matrix,[]) |> Enum.reduce(%{ground=>0.0},fn {node,diagonal,row,rhs},values ->
      value=(rhs-Enum.reduce(row,0.0,fn {other,g},sum->sum+g*Map.fetch!(values,other) end))/diagonal
      Map.put(values,node,value)
    end)
  end
  defp stamp(matrix,node,other,g,current,ground) do
    if node==ground,do: matrix,else: Map.update!(matrix,node,fn {row,rhs}->
      row=Map.update(row,node,g,&(&1+g))
      row=if other==ground,do: row,else: Map.update(row,other,-g,&(&1-g))
      {row,rhs+current}
    end)
  end

  # 正定接地矩阵的稀疏消元；优先低度节点，线段不产生稠密填充。主元按 {行非零数, 节点} 最小选取，
  # 用有序集合维护，每步只更新受影响的行（原先每步扫描全部剩余行，O(N²)）；选取次序与算术不变。
  defp eliminate(matrix,stack) do
    queue=Enum.reduce(matrix,:gb_sets.empty(),fn {n,{r,_}},q->:gb_sets.add({map_size(r),n},q) end)
    eliminate(matrix,queue,stack)
  end
  defp eliminate(matrix,_queue,stack) when map_size(matrix)==0,do: stack
  defp eliminate(matrix,queue,stack) do
    {{_,node},queue}=:gb_sets.take_smallest(queue)
    {row,rhs}=Map.fetch!(matrix,node)
    diagonal=Map.fetch!(row,node)
    row=Map.delete(row,node)
    matrix=Map.delete(matrix,node)
    {matrix,queue}=Enum.reduce(row,{matrix,queue},fn {other,weight},{m,q} ->
      {r,b}=Map.fetch!(m,other)
      q=:gb_sets.delete({map_size(r),other},q)
      r=Map.delete(r,node)
      r=Enum.reduce(row,r,fn {column,value},r->Map.update(r,column,-weight*value/diagonal,&(&1-weight*value/diagonal)) end)
      {Map.put(m,other,{r,b-weight*rhs/diagonal}),:gb_sets.add({map_size(r),other},q)}
    end)
    eliminate(matrix,queue,[{node,diagonal,row,rhs}|stack])
  end
end
