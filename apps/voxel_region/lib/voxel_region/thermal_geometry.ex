defmodule VoxelRegion.ThermalGeometry do
  @moduledoc "全局系统功能：从 canonical 实占用生成可丢弃的热容量、接触面积和导热摘要。"
  alias VoxelRegion.Prefab
  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "温度节点身份：宏格或精确微格；生命期身份保留在 target 中。"
  def key(%{granularity: 4}=t),do: VoxelRegion.ThermalAttachments.key(VoxelRegion.Attachments.slot(t))
  def key(t), do: {t.granularity,t.micro}

  @doc "列出宏格或实际微格的面采样点；仅使用 refined 的占用索引，不读取世界。"
  def faces(cell, refined) do
    case Map.fetch(refined, cell) do
      {:ok, slots} ->
        Enum.map(slots, fn {slot, _} ->
          micro = Prefab.micro_coord(cell, slot)
          {micro, for(axis <- 0..2, sign <- [-1, 1],
            do: {put_elem(micro, axis, elem(micro, axis) + sign), axis})}
        end)

      :error ->
        micro = scale(cell, @micro)
        faces = for axis <- 0..2, sign <- [-1, 1], reduce: [] do
          acc ->
            neighbor = put_elem(cell, axis, elem(cell, axis) + sign)
            if Map.has_key?(refined, neighbor) do
              [u, v] = Enum.reject(0..2, &(&1 == axis))
              samples = for a <- 0..(@micro-1), b <- 0..(@micro-1) do
                point = micro
                  |> put_elem(axis, elem(micro, axis) + if(sign == 1, do: @micro, else: -1))
                  |> put_elem(u, elem(micro, u) + a)
                  |> put_elem(v, elem(micro, v) + b)
                {point, axis}
              end
              samples ++ acc
            else
              [{scale(neighbor, @micro), axis} | acc]
            end
        end
        [{micro, faces}]
    end
  end

  @doc "面摘要所需的唯一 canonical 采样点，保留首次出现次序。"
  def points(faces) do
    Enum.flat_map(faces, fn {micro, neighbors} ->
      [micro | Enum.map(neighbors, &elem(&1, 0))]
    end) |> Enum.uniq()
  end

  @doc "消费冻结的 point → nil 或 {target, volume} 值，生成热节点；缺失采样不是空气。"
  def cell(faces, materials, samples) do
    Enum.flat_map(faces, fn {micro, neighbors} ->
      case Map.fetch!(samples, micro) do
        nil -> []
        {target, volume} ->
          material = Map.fetch!(materials, target.material)
          if Map.has_key?(material, "heat_capacity_per_macro") do
            bounds = bounds(target, volume)
            contacts = Enum.map(neighbors, fn {point, axis} ->
              case Map.fetch!(samples, point) do
                nil -> {nil, {0.0, 0.0, 0.0}}
                {other, volume} -> {other, contact(bounds, bounds(other, volume), axis)}
              end
            end)
            covered = Enum.reduce(contacts, 0.0, fn {_, {area, _, _}}, sum -> sum + area end)
            contacts = for {other, {area, d, other_d}} <- contacts, other != nil, area > 0,
                Map.has_key?(materials[other.material], "heat_capacity_per_macro") do
              k = material["thermal_conductivity"]
              ko = materials[other.material]["thermal_conductivity"]
              g = if k == 0 or ko == 0, do: 0.0, else: area/(d/k + other_d/ko)
              {key(other), g}
            end
            {x, y, z} = lengths(bounds)
            [{key(target), %{target: target, material: material,
              capacity: material["heat_capacity_per_macro"]*x*y*z,
              exposed_faces: 2*(x*y+x*z+y*z)-covered, contacts: contacts}}]
          else
            []
          end
      end
    end)
  end

  @doc "每个真实接触只结算一次，边界不依赖 chunk 或 region。"
  def contacts(nodes) do
    for {id,n}<-nodes,{other,g}<-n.contacts,id<other,Map.has_key?(nodes,other),do: {id,other,g}
  end

  @doc "Y-up 实占用盒；有限宏格以数量比例决定底部液柱高度，微格保持原尺寸。"
  def bounds(target,volume) do
    size=if target.granularity==0,do: 1.0,else: 1.0/@micro
    low=target.micro |> Tuple.to_list() |> Enum.map(&(&1/@micro)) |> List.to_tuple()
    high=for axis<-0..2,do: elem(low,axis)+size*if(axis==1,do: volume,else: 1.0)
    {low,List.to_tuple(high)}
  end

  defp lengths({low,high}),do: for(axis<-0..2,do: elem(high,axis)-elem(low,axis)) |> List.to_tuple()

  @doc "相邻占用盒的真实共面面积及各自法向半程；空隙不传热。"
  def contact({alo,ahi}=a,{blo,bhi}=b,axis) do
    touching=abs(elem(ahi,axis)-elem(blo,axis))<1.0e-12 or abs(elem(bhi,axis)-elem(alo,axis))<1.0e-12
    area=if touching,do: overlap(a,b,axis),else: 0.0
    {area,(elem(ahi,axis)-elem(alo,axis))/2,(elem(bhi,axis)-elem(blo,axis))/2}
  end

  @doc "附件面片与宿主表面的重叠和宿主半程，共用有限高度接触规则。"
  def surface_contact({low,high}=bounds,axis,plane,patch) do
    touching=abs(elem(low,axis)-plane)<1.0e-12 or abs(elem(high,axis)-plane)<1.0e-12
    {if(touching,do: overlap(bounds,patch,axis),else: 0.0),(elem(high,axis)-elem(low,axis))/2}
  end

  defp overlap({alo,ahi},{blo,bhi},normal) do
    for axis<-0..2,axis != normal,reduce: 1.0 do
      area->area*max(0.0,min(elem(ahi,axis),elem(bhi,axis))-max(elem(alo,axis),elem(blo,axis)))
    end
  end

  defp scale({x,y,z},n),do: {x*n,y*n,z*n}
end
