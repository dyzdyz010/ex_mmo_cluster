defmodule VoxelRegion.FileStore do
  @moduledoc """
  Voxim 离线烘焙的 region 载荷文件（S1 的真值基底）：`<root>/<content_version 16 hex>/L<level>/r_<x>_<y>_<z>.vxr`，
  每个文件就是一个 `RegionPayload`（头里带 level / region / seq = 0 / content_version / hash）。只读；缺文件 = `:missing`，不生成。
  """

  require Logger
  alias VoxelRegion.Codec

  @doc "root 下唯一的 16 hex 子目录 = content_version。"
  def content_version(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^[0-9a-f]{16}$/, &1))
        |> Enum.sort()
        |> case do
          [] -> {:error, :no_world}
          [hex | _] -> {:ok, String.to_integer(hex, 16)}
        end

      {:error, _} ->
        {:error, :no_world}
    end
  end

  def hex(version), do: Base.encode16(<<version::64>>, case: :lower)

  def path(root, version, level, {x, y, z}), do: Path.join([root, hex(version), "L#{level}", "r_#{x}_#{y}_#{z}.vxr"])

  @doc "读一个 region 文件并核对头与路径一致；`{:ok, bytes, header}` / `{:error, :missing}`。"
  def read(root, version, level, region) do
    p = path(root, version, level, region)

    with {:ok, bytes} <- File.read(p),
         {:ok, header} <- Codec.decode_payload_header(bytes),
         true <- header.level == level and header.region == region and header.content_version == version do
      {:ok, bytes, header}
    else
      {:error, :enoent} ->
        {:error, :missing}

      other ->
        Logger.warning("voxel region file rejected #{p}: #{inspect(other)}")
        {:error, :missing}
    end
  end
end
