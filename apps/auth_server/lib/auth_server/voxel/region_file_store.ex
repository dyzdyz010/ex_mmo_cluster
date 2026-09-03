defmodule AuthServer.Voxel.RegionFileStore do
  @moduledoc """
  `POST /ingame/voxel/regions` 的后端（Voxim R6 切片 S1）：把 Voxim 离线烘焙出的 region 载荷文件原样吐出去。

  目录 = `config :auth_server, :voxel_region_root`（`VOXEL_REGION_ROOT`，即 Voxim 的 `WorldBake/`），
  布局 `<root>/<content_version 16 hex>/L<level>/r_<x>_<y>_<z>.vxr`；每个文件就是一个 `RegionPayload`
  （头里带 level / region / seq / content_version / hash），所以服务端不解压、不算 hash，只核对头。

  这是接口活到最后、后端会换掉的一步：S4 把这里换成"载荷缓存 ⊕ overlay 日志"，路由与线格式不变。
  没有 fallback：缺文件 = `missing`，不生成地形。

  应答的三种情况（决策稿 §5.1）：
  - `unchanged`：客户端报的 (have_seq, have_hash) 与文件头相同（且客户端的 content_version 就是本目录的）
  - `payload`：其余
  - `missing`：文件不存在 / 头对不上路径
  （`entries` 要等 S2 的日志。）
  """

  require Logger
  alias AuthServer.Voxel.RegionCodec

  @doc "当前目录的 content_version（root 下唯一的 16 hex 子目录）；没有 → `{:error, :no_world}`。"
  @spec content_version(String.t()) :: {:ok, non_neg_integer()} | {:error, :no_world}
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

  @doc "整个请求 → 应答 iodata。"
  @spec serve(String.t(), binary()) :: {:ok, iodata()} | {:error, :invalid_request | :no_world}
  def serve(root, request) when is_binary(root) and is_binary(request) do
    with {:ok, client_version, items} <- RegionCodec.decode_request(request),
         {:ok, version} <- content_version(root) do
      replies = Enum.map(items, &serve_item(root, version, client_version, &1))
      {:ok, RegionCodec.encode_reply(version, replies)}
    end
  end

  def serve(_root, _request), do: {:error, :no_world}

  @doc "一个 region 的应答。"
  def serve_item(root, version, client_version, %{level: level, region: {x, y, z} = region, have_seq: have_seq, have_hash: have_hash}) do
    path = Path.join([root, Base.encode16(<<version::64>>, case: :lower), "L#{level}", "r_#{x}_#{y}_#{z}.vxr"])

    with {:ok, bytes} <- File.read(path),
         {:ok, header} <- RegionCodec.decode_payload_header(bytes),
         true <- header.level == level and header.region == region and header.content_version == version do
      if client_version == version and header.hash == have_hash and header.seq == have_seq do
        {:unchanged, level, region}
      else
        {:payload, level, region, bytes}
      end
    else
      {:error, :enoent} ->
        {:missing, level, region}

      other ->
        Logger.warning("voxel region file rejected #{path}: #{inspect(other)}")
        {:missing, level, region}
    end
  end
end
