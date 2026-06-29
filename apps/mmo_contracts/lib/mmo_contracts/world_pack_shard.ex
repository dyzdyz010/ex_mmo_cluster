defmodule MmoContracts.WorldPackShard do
  @moduledoc """
  `.vxpack` chunk payload shard 的最小二进制契约。

  文件主体先连续写入 chunk payload，尾部写固定宽度 offset table：
  `local_x:i32, local_y:i32, local_z:i32, payload_offset:u64, payload_size:u32`。
  最后 8 字节为 `entry_count:u32` 与 `VXFT` magic。客户端可从尾部读取
  footer，再按 shard 内 local coord 随机定位 payload。
  """

  @entry_size 24
  @footer_magic "VXFT"

  @type local_coord :: {integer(), integer(), integer()}
  @type entry :: %{required(:local_coord) => local_coord(), required(:payload) => binary()}
  @type footer_summary :: %{
          required(:entry_count) => pos_integer(),
          required(:local_coords) => MapSet.t(local_coord())
        }

  @doc "编码一个 `.vxpack` shard；输入非法时返回结构化错误。"
  @spec encode([entry() | map() | keyword()]) :: {:ok, binary()} | {:error, term()}
  def encode([]), do: {:error, :empty_entries}

  def encode(entries) when is_list(entries) do
    with {:ok, normalized} <- normalize_entries(entries) do
      {payload_blob, footer, _offset} =
        Enum.reduce(normalized, {<<>>, <<>>, 0}, fn %{local_coord: coord, payload: payload},
                                                    {payload_acc, footer_acc, offset} ->
          size = byte_size(payload)

          footer_entry = <<
            elem(coord, 0)::signed-little-32,
            elem(coord, 1)::signed-little-32,
            elem(coord, 2)::signed-little-32,
            offset::unsigned-little-64,
            size::unsigned-little-32
          >>

          {payload_acc <> payload, footer_acc <> footer_entry, offset + size}
        end)

      {:ok, payload_blob <> footer <> <<length(normalized)::unsigned-little-32, @footer_magic>>}
    end
  end

  def encode(_entries), do: {:error, :invalid_entries}

  @doc "从 `.vxpack` shard 中按 shard 内 local coord 读取 payload。"
  @spec fetch(binary(), local_coord()) :: {:ok, binary()} | {:error, term()}
  def fetch(shard, local_coord) when is_binary(shard) do
    with {:ok, coord} <- normalize_local_coord(local_coord),
         {:ok, footer_start, footer} <- footer_table(shard) do
      fetch_from_footer(shard, coord, footer_start, footer)
    end
  end

  def fetch(_shard, _local_coord), do: {:error, :invalid_shard}

  @doc """
  从磁盘 `.vxpack` 文件中按 shard 内 local coord 随机读取 payload。

  该入口只读取文件尾部 footer table 和命中的 payload 段，供 full-pack verifier
  与 launcher 避免把整个 shard 载入内存。
  """
  @spec fetch_file(String.t(), local_coord()) :: {:ok, binary()} | {:error, term()}
  def fetch_file(path, local_coord) when is_binary(path) do
    with {:ok, coord} <- normalize_local_coord(local_coord),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        fetch_from_file_io(io, coord)
      after
        File.close(io)
      end
    end
  end

  def fetch_file(_path, _local_coord), do: {:error, :invalid_shard_path}

  @doc "读取 `.vxpack` 二进制 footer 摘要，不读取或解码 payload 内容。"
  @spec footer_summary(binary()) :: {:ok, footer_summary()} | {:error, term()}
  def footer_summary(shard) when is_binary(shard) do
    with {:ok, footer_start, footer} <- footer_table(shard) do
      parse_footer_summary(footer, footer_start)
    end
  end

  def footer_summary(_shard), do: {:error, :invalid_shard}

  @doc "从磁盘 `.vxpack` 文件读取 footer 摘要，用于发布包完整性校验。"
  @spec footer_summary_file(String.t()) :: {:ok, footer_summary()} | {:error, term()}
  def footer_summary_file(path) when is_binary(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, shard_size} <- :file.position(io, :eof),
             :ok <- validate_minimum_file_size(shard_size),
             {:ok, trailer} <- pread_exact(io, shard_size - 8, 8),
             {:ok, footer_start, footer} <- file_footer_table(io, shard_size, trailer) do
          parse_footer_summary(footer, footer_start)
        end
      after
        File.close(io)
      end
    end
  end

  def footer_summary_file(_path), do: {:error, :invalid_shard_path}

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      with {:ok, normalized} <- normalize_entry(entry) do
        if MapSet.member?(seen, normalized.local_coord) do
          {:halt, {:error, {:duplicate_local_coord, normalized.local_coord}}}
        else
          {:cont, {:ok, [normalized | acc], MapSet.put(seen, normalized.local_coord)}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_entry(entry) do
    local_coord = value(entry, :local_coord)
    payload = value(entry, :payload)

    with {:ok, coord} <- normalize_local_coord(local_coord),
         {:ok, payload} <- normalize_payload(payload) do
      {:ok, %{local_coord: coord, payload: payload}}
    end
  end

  defp normalize_local_coord({x, y, z} = coord)
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {:ok, coord}

  defp normalize_local_coord(value), do: {:error, {:invalid_local_coord, value}}

  defp normalize_payload(payload) when is_binary(payload) and byte_size(payload) > 0,
    do: {:ok, payload}

  defp normalize_payload(value), do: {:error, {:invalid_payload, value}}

  defp footer_table(shard) do
    shard_size = byte_size(shard)

    cond do
      shard_size < 8 ->
        {:error, :invalid_footer}

      binary_part(shard, shard_size - 4, 4) != @footer_magic ->
        {:error, :invalid_footer_magic}

      true ->
        entry_count = :binary.decode_unsigned(binary_part(shard, shard_size - 8, 4), :little)
        footer_size = entry_count * @entry_size
        footer_start = shard_size - 8 - footer_size

        if entry_count == 0 or footer_start < 0 do
          {:error, :invalid_footer_table}
        else
          {:ok, footer_start, binary_part(shard, footer_start, footer_size)}
        end
    end
  end

  defp fetch_from_file_io(io, coord) do
    with {:ok, shard_size} <- :file.position(io, :eof),
         :ok <- validate_minimum_file_size(shard_size),
         {:ok, trailer} <- pread_exact(io, shard_size - 8, 8),
         {:ok, footer_start, footer} <- file_footer_table(io, shard_size, trailer) do
      fetch_file_from_footer(io, coord, footer_start, footer)
    end
  end

  defp validate_minimum_file_size(size) when size >= 8, do: :ok
  defp validate_minimum_file_size(_size), do: {:error, :invalid_footer}

  defp file_footer_table(
         io,
         shard_size,
         <<entry_count::unsigned-little-32, magic::binary-size(4)>>
       ) do
    if magic == @footer_magic do
      footer_size = entry_count * @entry_size
      footer_start = shard_size - 8 - footer_size

      if entry_count == 0 or footer_start < 0 do
        {:error, :invalid_footer_table}
      else
        with {:ok, footer} <- pread_exact(io, footer_start, footer_size) do
          {:ok, footer_start, footer}
        end
      end
    else
      {:error, :invalid_footer_magic}
    end
  end

  defp file_footer_table(_io, _shard_size, _trailer), do: {:error, :invalid_footer}

  defp fetch_file_from_footer(_io, _coord, _footer_start, <<>>), do: {:error, :not_found}

  defp fetch_file_from_footer(io, coord, footer_start, <<
         x::signed-little-32,
         y::signed-little-32,
         z::signed-little-32,
         offset::unsigned-little-64,
         size::unsigned-little-32,
         rest::binary
       >>) do
    if coord == {x, y, z} do
      if size == 0 or offset + size > footer_start do
        {:error, :invalid_payload_offset}
      else
        pread_exact(io, offset, size)
      end
    else
      fetch_file_from_footer(io, coord, footer_start, rest)
    end
  end

  defp pread_exact(_io, offset, _size) when offset < 0, do: {:error, :invalid_footer}

  defp pread_exact(io, offset, size) do
    case :file.pread(io, offset, size) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :short_read}
      :eof -> {:error, :short_read}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_footer_summary(footer, footer_start) do
    do_parse_footer_summary(footer, footer_start, 0, MapSet.new())
  end

  defp do_parse_footer_summary(<<>>, _footer_start, count, local_coords) do
    {:ok, %{entry_count: count, local_coords: local_coords}}
  end

  defp do_parse_footer_summary(
         <<
           x::signed-little-32,
           y::signed-little-32,
           z::signed-little-32,
           offset::unsigned-little-64,
           size::unsigned-little-32,
           rest::binary
         >>,
         footer_start,
         count,
         local_coords
       ) do
    coord = {x, y, z}

    cond do
      size == 0 or offset + size > footer_start ->
        {:error, {:invalid_payload_offset, coord}}

      MapSet.member?(local_coords, coord) ->
        {:error, {:duplicate_local_coord, coord}}

      true ->
        do_parse_footer_summary(rest, footer_start, count + 1, MapSet.put(local_coords, coord))
    end
  end

  defp do_parse_footer_summary(_footer, _footer_start, _count, _local_coords),
    do: {:error, :invalid_footer_table}

  defp fetch_from_footer(_shard, _coord, _footer_start, <<>>), do: {:error, :not_found}

  defp fetch_from_footer(shard, coord, footer_start, <<
         x::signed-little-32,
         y::signed-little-32,
         z::signed-little-32,
         offset::unsigned-little-64,
         size::unsigned-little-32,
         rest::binary
       >>) do
    if coord == {x, y, z} do
      if size == 0 or offset + size > footer_start do
        {:error, :invalid_payload_offset}
      else
        {:ok, binary_part(shard, offset, size)}
      end
    else
      fetch_from_footer(shard, coord, footer_start, rest)
    end
  end

  defp value(%{} = value, key), do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp value(value, key) when is_list(value) do
    Keyword.get(value, key) || list_key_value(value, Atom.to_string(key))
  end

  defp value(_value, _key), do: nil

  defp list_key_value(value, key) do
    case List.keyfind(value, key, 0) do
      {^key, found} -> found
      _other -> nil
    end
  end
end
