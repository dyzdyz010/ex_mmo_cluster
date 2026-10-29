defmodule VoxelRegion.World.Definitions do
  @moduledoc "Prefab按id准备的请求资源owner：复用PageLoad caller监控，共享Cache pin；几何只经本次结果运输，不入目录。"
  alias VoxelRegion.Prefab
  alias VoxelRegion.Prefab.Catalog
  alias VoxelRegion.World.{Cache, PageLoad}
  require Logger

  @doc "开始只读定义准备；工作进程只捕获本次操作，不捕获World或全目录。"
  def start(state, from, request, operation) do
    world = self()
    token = make_ref()
    {pid, monitor} = spawn_monitor(fn ->
      result = try do
        execute(world, token, operation)
      rescue
        error -> {:error, {:definition_prepare, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:definition_prepare_exit, reason}}
      end
      send(world, {:prefab_ready, token, result})
    end)
    input_bytes = operation_bytes(operation)
    row = %{from: from, pid: pid, monitor: monitor, ids: MapSet.new(), input_bytes: input_bytes, source_bytes: input_bytes,
      started: System.monotonic_time(:microsecond)}
    state = PageLoad.track(state, from, request)
    {:deferred, %{state | prefab_requests: Map.put(state.prefab_requests, token, row),
      prefab_source_bytes: state.prefab_source_bytes + input_bytes}}
  end

  @doc "向本请求worker提供指定子闭包的轻描述及已缓存原字节；不读磁盘。"
  def inputs(state, token, pid, {mode, roots}) when mode in [:exact, :closure] do
    with %{pid: ^pid} = request <- Map.get(state.prefab_requests, token),
         {:ok, ids} <- select(state.prefabs, roots, mode) do
      descriptors = Map.take(state.prefabs, ids)
      {cached, cache} = Enum.reduce(ids, {%{}, state.cache}, fn id, {values, cache} ->
        case Cache.get(cache, {:prefab, id}) do
          {:ok, entry, next} -> {Map.put(values, id, entry.bytes), next}
          {:miss, next} -> {values, next}
        end
      end)
      with {:ok, cache} <- Cache.pin(cache, Enum.map(Map.keys(cached), &{:prefab, &1}), token) do
        size = request.input_bytes + Enum.sum(for {_, entry} <- descriptors, do: entry.source_bytes)
        row = %{request | ids: MapSet.new(ids), source_bytes: size}
        {{:ok, descriptors, cached}, %{state | cache: cache,
          prefab_source_bytes: state.prefab_source_bytes + size - request.source_bytes,
          prefab_requests: Map.put(state.prefab_requests, token, row)}}
      else
        {:error, reason, _} -> {{:error, {:definition_cache, reason}}, state}
      end
    else
      nil -> {{:error, :definition_request_expired}, state}
      {:error, reason} -> {{:error, reason}, state}
      _ -> {{:error, :definition_request_owner}, state}
    end
  end

  @doc "接纳该worker已校验身份的原字节；缓存容量不足显式失败，不另造永久定义表。"
  def loaded(state, token, pid, id, bytes) do
    with %{pid: ^pid} = request <- Map.get(state.prefab_requests, token),
         true <- MapSet.member?(request.ids, id),
         {:ok, cache} <- Cache.put(state.cache, {:prefab, id}, bytes, id),
         {:ok, cache} <- Cache.pin(cache, [{:prefab, id}], token) do
      {:ok, %{state | cache: cache}}
    else
      {:error, reason, _} -> {{:error, {:definition_cache, reason}}, state}
      _ -> {{:error, :definition_request_expired}, state}
    end
  end

  @doc "只投影目标已接纳的定义描述；已知作者定义不重新进入玩家草稿边界。"
  def known(state, token, pid, ids) do
    case Map.get(state.prefab_requests, token) do
      %{pid: ^pid} -> {:ok, Map.take(state.prefabs, ids)}
      _ -> {:error, :definition_request_expired}
    end
  end

  @doc "准备完成后回复原caller并退休pin/计量；编译结果不写入state。"
  def finish(state, token, result) do
    case Map.fetch(state.prefab_requests, token) do
      {:ok, request} ->
        Logger.info("voxel_prefab_prepared source_bytes=#{request.source_bytes} result_bytes=#{:erlang.external_size(result)} elapsed_us=#{System.monotonic_time(:microsecond) - request.started}")
        GenServer.reply(request.from, result)
        retire(state, token, request)
      :error -> state
    end
  end

  @doc "worker异常显式完成请求；正常结果已退休的DOWN不重新生效。"
  def down(state, monitor, reason) do
    case Enum.find(state.prefab_requests, fn {_, row} -> row.monitor == monitor end) do
      {token, _} -> {:handled, finish(state, token, {:error, {:definition_prepare_exit, reason}})}
      nil -> :unknown
    end
  end

  @doc "复用唯一caller取消事实，停止其worker并退休全部引用。"
  def cancel(state, from) do
    Enum.reduce(state.prefab_requests, state, fn {token, row}, acc ->
      if row.from == from do
        Process.exit(row.pid, :kill)
        retire(acc, token, row)
      else
        acc
      end
    end)
  end

  @doc "owner关闭时停止尚未完成的本地准备。"
  def stop(state), do: Enum.each(state.prefab_requests, fn {_, row} -> Process.exit(row.pid, :kill) end)

  defp retire(state, token, row) do
    Process.demonitor(row.monitor, [:flush])
    state = PageLoad.accepted(state, row.from)
    %{state | cache: Cache.release(state.cache, token),
      prefab_source_bytes: state.prefab_source_bytes - row.source_bytes,
      prefab_requests: Map.delete(state.prefab_requests, token)}
  end

  defp execute(world, token, {:definition, id}) do
    with {:ok, _descriptors, bytes} <- bytes(world, token, [id], :exact), do: {:ok, Map.fetch!(bytes, id)}
  end
  defp execute(world, token, {:definitions, ids}) do
    with {:ok, _descriptors, bytes} <- bytes(world, token, ids, :exact), do: {:ok, bytes}
  end
  defp execute(world, token, {:geometry, id}) do
    with {:ok, _descriptors, bytes} <- bytes(world, token, [id]),
         {:ok, definitions} <- decode(bytes),
         {:ok, geometry} <- Prefab.compile_id(definitions, id), do: {:ok, compact(geometry)}
  end
  defp execute(world, token, {kind, binary}) when kind in [:compile, :preview] do
    with {:ok, id, draft} <- Prefab.runtime_input(binary),
         {:ok, descriptors, bytes} <- bytes(world, token, Enum.map(draft.children, & &1.definition_id)),
         {:ok, definitions} <- decode(bytes) do
      case Prefab.compile_input(id, draft, descriptors, definitions, kind) do
        {:ok, id, geometry} -> {:ok, id, compact(geometry)}
        {:ok, id, geometry, diagnostics} -> {:ok, id, compact(geometry), diagnostics}
        error -> error
      end
    end
  end

  defp execute(world, token, {:import, incoming}) when is_map(incoming) do
    with {:ok, known} <- GenServer.call(world, {:prefab_known, token, Map.keys(incoming)}, :infinity) do
    unknown = Map.drop(incoming, Map.keys(known))
    decoded = Enum.reduce_while(unknown, {:ok, %{}}, fn {id, binary}, {:ok, inputs} ->
      case Prefab.runtime_input(binary) do
        {:ok, ^id, definition} -> {:cont, {:ok, Map.put(inputs, id, definition)}}
        {:ok, _, _} -> {:halt, {:error, :definition_content_mismatch}}
        error -> {:halt, error}
      end
    end)
    with {:ok, inputs} <- decoded,
         external = for({_, definition} <- inputs, child <- definition.children,
           not Map.has_key?(inputs, child.definition_id), uniq: true, do: child.definition_id),
         {:ok, descriptors, raw} <- bytes(world, token, external),
         {:ok, definitions} <- decode(raw) do
      compile_import(inputs, unknown, descriptors, definitions, %{})
    end
    end
  end

  defp compile_import(pending, _incoming, _descriptors, _definitions, prepared) when map_size(pending) == 0,
    do: {:ok, prepared}
  defp compile_import(pending, incoming, descriptors, definitions, prepared) do
    ready = Enum.filter(pending, fn {_, definition} ->
      Enum.all?(definition.children, &Map.has_key?(descriptors, &1.definition_id))
    end)
    if ready == [] do
      {:error, :definition_dependencies}
    else
      Enum.reduce_while(ready, {:ok, descriptors, definitions, prepared}, fn {id, definition}, {:ok, desc, defs, out} ->
        case Prefab.compile_input(id, definition, desc, defs, :compile) do
          {:ok, ^id, geometry} ->
            row = Catalog.descriptor(id, nil, byte_size(incoming[id]), geometry)
            {:cont, {:ok, Map.put(desc, id, row), Map.put(defs, id, definition), Map.put(out, id, row)}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, desc, defs, out} -> compile_import(Map.drop(pending, Enum.map(ready, &elem(&1,0))), incoming, desc, defs, out)
        error -> error
      end
    end
  end

  defp bytes(world, token, roots, mode \\ :closure) do
    with {:ok, descriptors, cached} <- GenServer.call(world, {:prefab_inputs, token, {mode, roots}}, :infinity) do
      Enum.reduce_while(descriptors, {:ok, descriptors, cached}, fn {id, entry}, {:ok, desc, values} ->
        if Map.has_key?(values, id) do
          {:cont, {:ok, desc, values}}
        else
          with {:ok, binary} <- Catalog.read(entry),
               :ok <- GenServer.call(world, {:prefab_loaded, token, id, binary}, :infinity) do
            {:cont, {:ok, desc, Map.put(values, id, binary)}}
          else
            error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp select(catalog, ids, :closure), do: Catalog.closure(catalog, ids)
  defp select(catalog, ids, :exact) do
    if Enum.all?(ids, &Map.has_key?(catalog, &1)),
      do: {:ok, Enum.uniq(ids)}, else: {:error, :definition_not_found}
  end

  defp decode(bytes), do: Enum.reduce_while(bytes, {:ok, %{}}, fn {id, binary}, {:ok, definitions} ->
    case Prefab.decode(binary) do
      {:ok, definition} -> {:cont, {:ok, Map.put(definitions, id, definition)}}
      error -> {:halt, error}
    end
  end)

  defp compact(geometry), do: Map.put(geometry, :definition, Map.take(geometry.definition, [:presentation_bindings]))

  defp operation_bytes({kind, bytes}) when kind in [:compile, :preview] and is_binary(bytes), do: byte_size(bytes)
  defp operation_bytes({:import, incoming}) when is_map(incoming), do: Enum.sum(for {_, bytes} <- incoming, do: byte_size(bytes))
  defp operation_bytes(_), do: 0
end
