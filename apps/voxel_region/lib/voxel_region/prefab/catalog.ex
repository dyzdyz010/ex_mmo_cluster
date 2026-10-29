defmodule VoxelRegion.Prefab.Catalog do
  @moduledoc "Prefab唯一内容目录：常驻轻描述与原始字节位置，完整定义仅属于按id准备请求。"
  alias VoxelRegion.Prefab

  defmodule Descriptor do
    @moduledoc "已验证定义的轻描述；不含原字节、nodes或坐标列表。source只供服务端按id读取。"
    @enforce_keys [:id, :source, :source_bytes, :summary, :has_macro_cells, :presentation_bindings, :child_ids, :material_counts]
    defstruct @enforce_keys
  end

  @doc "沿原解析与发布算法建立轻目录；应在World启动调用方或准备进程执行。"
  def open(author_path, runtime_path) do
    runtime = if runtime_path != nil and File.exists?(runtime_path), do: read_directory(runtime_path), else: %{}
    inputs = Map.merge(read_directory(author_path), runtime)
    definitions = Map.new(inputs, fn {id, row} -> {id, row.definition} end)
    with {:ok, compiled} <- Prefab.publish(definitions) do
      {:ok, Map.new(compiled, fn {id, geometry} ->
        row = Map.fetch!(inputs, id)
        {id, descriptor(id, row.source, row.bytes, geometry)}
      end)}
    end
  end

  @doc "构造单条已验证描述；固定身份切片复制为独立小binary，不捕获原VXPD父对象。"
  def descriptor(id, source, bytes, geometry) do
    %Descriptor{id: :binary.copy(id), source: source, source_bytes: bytes,
      summary: geometry.summary, has_macro_cells: geometry.has_macro_cells,
      presentation_bindings: geometry.presentation_bindings,
      child_ids: geometry.child_ids,
      material_counts: geometry.material_counts}
  end

  @doc "对外目录不暴露文件位置或完整几何。"
  def public(catalog), do: Map.new(catalog, fn {id, entry} ->
    {id, Map.take(entry, [:summary, :has_macro_cells, :presentation_bindings, :material_counts])}
  end)

  @doc "发布顺序只保留id/cid/name；原字节通过按id请求取得，不常驻第二份目录。"
  def publications(path, catalog) do
    Path.wildcard(Path.expand("*.pub", path))
    |> Enum.map(fn file ->
      <<ordinal::32, publisher::64, name::binary>> = File.read!(file)
      {:ok, id} = file |> Path.basename(".pub") |> Base.decode16(case: :mixed)
      _ = Map.fetch!(catalog, id)
      {ordinal, %{id: :binary.copy(id), publisher: publisher, name: :binary.copy(name)}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "只读取指定已接纳id的原始字节；原版本与SHA身份不通过重新编码猜测。"
  def read(%Descriptor{id: id, source: path}) do
    with {:ok, bytes} <- File.read(path),
         true <- :crypto.hash(:sha256, bytes) == id do
      {:ok, bytes}
    else
      false -> {:error, :definition_content_mismatch}
      {:error, reason} -> {:error, {:definition_read, reason}}
    end
  end

  @doc "按目录已验证的子链接取得本请求闭包；不存在的id显式失败。"
  def closure(catalog, ids), do: visit(catalog, ids, MapSet.new())

  defp visit(_catalog, [], seen), do: {:ok, Enum.sort(seen)}
  defp visit(catalog, [id | rest], seen) do
    if MapSet.member?(seen, id) do
      visit(catalog, rest, seen)
    else
      case Map.fetch(catalog, id) do
        {:ok, entry} -> visit(catalog, entry.child_ids ++ rest, MapSet.put(seen, id))
        :error -> {:error, :definition_not_found}
      end
    end
  end

  defp read_directory(nil), do: %{}
  defp read_directory(path) do
      for name <- File.ls!(path), Path.extname(name) == ".vxpd", into: %{} do
        source = Path.expand(name, path)
        bytes = File.read!(source)
        {:ok, definition} = Prefab.decode(bytes)
        {:crypto.hash(:sha256, bytes), %{source: source, bytes: byte_size(bytes), definition: definition}}
      end
  end
end
