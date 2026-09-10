defmodule VoxelRegion.Prefab do
  @moduledoc "Published VXPD v1 content and A0 integer cell-volume rotations."
  alias MmoContracts.VoxelMaterialCatalog

  def load(nil), do: %{}
  def load(path) do
    File.ls!(path) |> Enum.filter(&(Path.extname(&1) == ".vxpd")) |> Map.new(fn name ->
      file = Path.join(path,name)
      bytes = File.read!(file)
      {:ok, definition} = decode(bytes)
      {:crypto.hash(:sha256,bytes),definition}
    end)
  end

  def decode(<<"VXPD",1::32-little,n::32-little,body::binary-size(n*14),0::32-little>>) when n > 0 do
    cells = for <<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little <- body>>, do: {{x,y,z},m}
    coords = Enum.map(cells,&elem(&1,0))
    if coords == Enum.sort(Enum.uniq(coords)) and Enum.all?(cells,fn {_,m} -> m != 0 and VoxelMaterialCatalog.valid_id?(m) end),
      do: {:ok,cells}, else: {:error,:invalid_definition}
  end
  def decode(_), do: {:error,:invalid_definition}

  def footprint(definition, anchor, orientation) when orientation in 0..23 do
    [ax,ay] = Enum.at([
      [{1,0,0},{0,1,0}], [{1,0,0},{0,-1,0}],
      [{0,-1,0},{1,0,0}], [{0,1,0},{-1,0,0}],
      [{1,0,0},{0,0,1}], [{1,0,0},{0,0,-1}]
    ],div(orientation,4))
    ax = Enum.reduce(List.duplicate(nil,rem(orientation,4)),ax,fn _,x -> cross(x,ay) end)
    az = cross(ax,ay)
    rows = for i <- 0..2, do: {elem(ax,i),elem(ay,i),elem(az,i)}
    Enum.map(definition,fn {{x,y,z},m} ->
      cell = rows |> Enum.with_index() |> Enum.map(fn {{a,b,c},i} ->
        elem(anchor,i)+a*x+b*y+c*z+if(a == -1 or b == -1 or c == -1,do: -1,else: 0)
      end) |> List.to_tuple()
      {cell,m}
    end)
  end
  defp cross({a,b,c},{d,e,f}), do: {b*f-c*e,c*d-a*f,a*e-b*d}

  def macro_slot({x,y,z}) do
    n = VoxelRegion.Spatial.micro_resolution()
    macro = {Integer.floor_div(x,n),Integer.floor_div(y,n),Integer.floor_div(z,n)}
    slot = Integer.mod(x,n)+n*(Integer.mod(y,n)+n*Integer.mod(z,n))
    {macro,slot}
  end
end
