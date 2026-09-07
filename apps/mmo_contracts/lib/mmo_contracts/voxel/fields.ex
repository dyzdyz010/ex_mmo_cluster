defmodule MmoContracts.Voxel.Fields do
  @moduledoc "现有编辑意图字段的信任边界检查，当前与遗留表面元件编码共用。"

  @doc "接纳既有无符号八位字段。"
  def u8!(v, _f) when is_integer(v) and v in 0..0xFF, do: {:ok, v}
  def u8!(v, f), do: {:error, {:invalid_field, f, v}}

  @doc "接纳既有无符号十六位字段。"
  def u16!(v, _f) when is_integer(v) and v in 0..0xFFFF, do: {:ok, v}
  def u16!(v, f), do: {:error, {:invalid_field, f, v}}

  @doc "接纳既有无符号三十二位字段。"
  def u32!(v, _f) when is_integer(v) and v in 0..0xFFFF_FFFF, do: {:ok, v}
  def u32!(v, f), do: {:error, {:invalid_field, f, v}}

  @doc "接纳既有无符号六十四位字段。"
  def u64!(v, _f) when is_integer(v) and v >= 0 and v <= 0xFFFF_FFFF_FFFF_FFFF, do: {:ok, v}
  def u64!(v, f), do: {:error, {:invalid_field, f, v}}

  @doc "接纳既有完整 XYZ 有符号六十四位 micro 坐标。"
  def world_micro!({x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) and
             x in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF and
             y in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF and
             z in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF do
    {:ok, {x, y, z}}
  end

  def world_micro!(other), do: {:error, {:invalid_field, :target_world_micro, other}}

  @doc "接纳既有三轴有符号八位法线。"
  def face_normal!({nx, ny, nz})
      when is_integer(nx) and is_integer(ny) and is_integer(nz) and nx in -128..127 and
             ny in -128..127 and nz in -128..127 do
    {:ok, {nx, ny, nz}}
  end

  def face_normal!(other), do: {:error, {:invalid_field, :face_normal, other}}
end
