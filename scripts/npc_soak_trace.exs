# 仅测试：沿用既有 trace 入口；不读取 endpoint，不保存请求内容，只保存身份、时钟、大小和用量。
path = "/demo/llm-requests.jsonl"
{:module, _} = Code.ensure_loaded(NpcServer.Http)
if old = Process.whereis(:run07_llm_tracer), do: Process.exit(old, :kill)
name = fn t -> Map.get(t, :name) || Map.get(t, "name") end
now = fn -> DateTime.utc_now() |> DateTime.to_iso8601() end

tracer = spawn(fn ->
  # 注册名是原采样器的探针接口，同一容器内唯一，不表示本次运行编号。
  Process.register(self(), :run07_llm_tracer)
  loop = fn loop, pending ->
    receive do
      {:trace, pid, :call, {NpcServer.Http, :request, [_endpoint, body]}} ->
        mono = System.monotonic_time(:microsecond)
        input = body.input
        items = if is_binary(input), do: [%{"content" => input}], else: input
        cid = if is_binary(input), do: get_in(Jason.decode!(input), ["self", "entity_id"]), else: nil
        tools = Enum.map(body.tools, name)
        size = fn item ->
          case item do
            %{"content" => text} when is_binary(text) -> byte_size(text)
            %{"output" => text} when is_binary(text) -> byte_size(text)
            _ -> nil
          end
        end
        row = %{pid: inspect(pid), cid: cid, t0: now.(), m0_us: mono,
                body_bytes: byte_size(Jason.encode!(body)), input_items: length(items),
                first_content_bytes: size.(List.first(items)), last_item_bytes: size.(List.last(items)),
                design: "publish" in tools, tools: length(tools), max_output_tokens: Map.get(body, :max_output_tokens)}
        loop.(loop, Map.put(pending, pid, row))

      {:trace, pid, :return_from, {NpcServer.Http, :request, 2}, result} ->
        row = Map.fetch!(pending, pid)
        {status, usage} = case result do
          {:ok, %{"usage" => usage}} when is_map(usage) ->
            {"ok", Map.take(usage, ["input_tokens", "output_tokens", "total_tokens"])}
          {:ok, _} -> {"ok", nil}
          {:error, reason} -> {inspect(reason, limit: 8, printable_limit: 160), nil}
        end
        line = Jason.encode!(Map.merge(row, %{t1: now.(), status: status, usage: usage}))
        File.write!(path, line <> "\n", [:append])
        loop.(loop, Map.delete(pending, pid))
    end
  end
  loop.(loop, %{})
end)

# 既有测试容器注册与 trace_pattern 的同步入口保持不变。
Process.sleep(100)
patterns = :erlang.trace_pattern({NpcServer.Http, :request, 2}, [{:_, [], [{:return_trace}]}], [:global])
procs = :erlang.trace(:all, true, [:call, {:tracer, tracer}])
Jason.encode!(%{tracer: inspect(tracer), registered: Process.whereis(:run07_llm_tracer) == tracer, patterns: patterns, procs: procs})
