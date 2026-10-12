defmodule NpcServer.Life.Hindsight do
  @moduledoc """
  全局系统功能：固定 Hindsight 0.10.3 的无状态 HTTP 适配器。

  config 为 `%{url: 服务根 URL, bank: NPC 独立库}`；可覆盖 `timeout_ms`（单请求，
  缺省 300 秒）、`operation_timeout_ms`（每个后台 operation 总预算，缺省 600 秒）。
  调用由 Life 慢 worker 承担，不阻塞 Body。模型和记忆只是主观派生文档，不能接管 World 数值真值。
  retain 的同步抽取后逐文档检查真实 fact 数；consolidation 的待办在 operations/status 中可见。
  原始 HTTP 错误体、URL、异常信息和 LLM trace 都不进入返回值或日志。
  """
  require Logger

  @truth "Subjective memory; not current numeric world truth."
  @queries [
    {"self", "What kind of builder am I, and what lessons have I learned from my experiences?"},
    {"relationships",
     "Who helped or harmed me, how has my trust in each person changed, and why?"},
    {"world",
     "What do I remember about places and construction sites I depend on? Historical coordinates are memories, not current world truth."},
    {"commitments", "What promises have I made or received, and which are open or fulfilled?"}
  ]

  @doc "建立 bank 与缺失的四份认识文档；已有文档不重建、不刷新。"
  def ensure(config, name) do
    with {:ok, _} <-
           request(config, :put, "", %{
             name: name,
             mission:
               "My first-person builder journal. Preserve event history and evolving subjective beliefs. " <>
                 @truth
           }),
         {:ok, _} <- collect(@queries, fn {id, query} -> ensure_model(config, id, query) end) do
      {:ok, %{bank: config.bank}}
    end
  end

  @doc "把纯心智经历 id/text/at_ms 映射为稳定文档，单次批量抽取后检查每份文档的 facts。"
  def retain(config, episodes) when is_list(episodes) and episodes != [] do
    with {:ok, items} <- collect(episodes, &episode/1),
         {:ok, %{"success" => true} = response} <-
           request(config, :post, "/memories", %{items: items, async: false}),
         {:ok, documents} <- collect(items, fn item -> document(config, item.document_id) end),
         {:ok, operations} <- operations(config) do
      {:ok,
       %{
         status: :retained,
         retained: length(items),
         facts: Enum.sum(documents),
         documents: Enum.map(items, & &1.document_id),
         usage: response["usage"] || %{},
         operations: operations
       }}
    else
      {:ok, _} -> failure(:invalid_response)
      error -> error
    end
  end

  def retain(_, _), do: failure(:invalid_episodes)

  @doc "显式后台刷新四份认识并等 operation 完成；决策热路径禁止调用。"
  def refresh(config) do
    with {:ok, operations} <-
           collect(@queries, fn {id, _} ->
             with {:ok, response} <- request(config, :post, "/mental-models/#{id}/refresh", %{}),
                  {:ok, operation} <- completion(config, response),
                  do: {:ok, operation}
           end),
         {:ok, cached} <- models(config) do
      {:ok, Map.put(cached, :operations, operations)}
    end
  end

  @doc "只读四份缓存认识，不触发 refresh；保留 staleness 与刷新时间。"
  def models(config) do
    with {:ok, rows} <-
           collect(@queries, fn {id, _} ->
             with {:ok, row} <- request(config, :get, "/mental-models/#{id}?detail=content"),
                  do: {:ok, {id, row}}
           end) do
      {:ok,
       %{
         models: Map.new(rows, fn {id, row} -> {id, row["content"]} end),
         metadata:
           Map.new(rows, fn {id, row} ->
             {id, Map.take(row, ["is_stale", "last_refreshed_at", "last_refresh_failed_at"])}
           end),
         truth: @truth
       }}
    end
  end

  @doc "对当前情境恰好发一次 mid budget 召回，时间锚来自调用方；返回毫秒耗时。"
  def recall(config, query, now_ms) do
    started = System.monotonic_time(:millisecond)

    with {:ok, timestamp} <- timestamp(now_ms),
         {:ok, %{"results" => results}} when is_list(results) <-
           request(config, :post, "/memories/recall", %{
             query: query,
             budget: "mid",
             max_tokens: 2048,
             query_timestamp: timestamp
           }) do
      {:ok,
       %{
         results: results,
         latency_ms: System.monotonic_time(:millisecond) - started,
         truth: @truth
       }}
    else
      {:ok, _} -> failure(:invalid_response)
      error -> error
    end
  end

  @doc "只读 facts、最近 100 个后台操作和按操作聚合的 token，用于 CLI/observe；不返回原始 trace。"
  def status(config) do
    with {:ok, stats} <- request(config, :get, "/stats"),
         {:ok, operations} <- operations(config),
         {:ok, usage} <- page(config, "/llm-requests", "items", 200) do
      totals =
        Enum.reduce(usage, %{}, fn item, acc ->
          key = item["scope"] || item["operation"] || "unknown"

          Map.update(acc, key, usage(item), fn previous ->
            Map.merge(previous, usage(item), fn _, a, b -> a + b end)
          end)
        end)

      {:ok, %{stats: stats, operations: operations, usage: totals}}
    end
  end

  defp usage(item),
    do: %{
      requests: 1,
      input_tokens: item["input_tokens"] || 0,
      output_tokens: item["output_tokens"] || 0,
      failed: if(item["status"] in [nil, "success"], do: 0, else: 1)
    }

  defp episode(%{"id" => id, "text" => text, "at_ms" => at})
       when is_binary(id) and id != "" and is_binary(text) and text != "" do
    with {:ok, at} <- timestamp(at), do: {:ok, %{document_id: id, content: text, timestamp: at}}
  end

  defp episode(_), do: failure(:invalid_episodes)

  defp timestamp(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, DateTime.to_iso8601(at)}
      _ -> failure(:invalid_timestamp)
    end
  end

  defp timestamp(_), do: failure(:invalid_timestamp)

  defp document(config, id) do
    with {:ok, response} <- request(config, :get, "/documents/" <> segment(id)) do
      case response["memory_unit_count"] do
        n when is_integer(n) and n > 0 -> {:ok, n}
        0 -> failure(:empty_facts)
        _ -> failure(:invalid_response)
      end
    end
  end

  defp ensure_model(config, id, query) do
    case request(config, :get, "/mental-models/#{id}?detail=content") do
      {:ok, row} ->
        {:ok, row}

      {:error, {:http_status, 404}} ->
        with {:ok, response} <-
               request(config, :post, "/mental-models", %{
                 id: id,
                 name: id,
                 source_query: query <> " " <> @truth,
                 max_tokens: 800,
                 trigger: %{refresh_after_consolidation: false}
               }),
             {:ok, operation} <- completion(config, response),
             do: {:ok, operation}

      error ->
        error
    end
  end

  defp completion(config, %{"operation_id" => id}) when is_binary(id) do
    deadline =
      System.monotonic_time(:millisecond) + Map.get(config, :operation_timeout_ms, 600_000)

    poll(config, id, deadline)
  end

  defp completion(_, _), do: failure(:invalid_response)

  defp poll(config, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      failure(:operation_timeout)
    else
      bounded =
        Map.put(config, :timeout_ms, min(remaining, Map.get(config, :timeout_ms, 300_000)))

      poll_response(config, id, deadline, request(bounded, :get, "/operations/" <> segment(id)))
    end
  end

  defp poll_response(config, id, deadline, {:ok, operation}) do
    case operation["status"] do
      "completed" ->
        {:ok, Map.take(operation, ["operation_id", "status", "completed_at"])}

      status when status in ["pending", "processing"] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          failure(:operation_timeout)
        else
          Process.sleep(min(remaining, Map.get(config, :poll_interval_ms, 1000)))
          poll(config, id, deadline)
        end

      status when status in ["failed", "cancelled", "not_found"] ->
        failure({:operation_failed, status})

      _ ->
        failure(:invalid_response)
    end
  end

  defp poll_response(_, _, deadline, {:error, :timeout}) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: failure(:operation_timeout),
      else: failure(:timeout)
  end

  defp poll_response(_, _, _, error), do: error

  defp operations(config) do
    with {:ok, %{"operations" => rows}} when is_list(rows) <-
           request(config, :get, "/operations?limit=100&offset=0") do
      {:ok,
       Enum.map(
         rows,
         &Map.take(&1, [
           "id",
           "operation_id",
           "status",
           "task_type",
           "operation_type",
           "created_at",
           "completed_at"
         ])
       )}
    else
      {:ok, _} -> failure(:invalid_response)
      error -> error
    end
  end

  defp page(config, path, field, limit, offset \\ 0, acc \\ []) do
    with {:ok, %{^field => rows, "total" => total}} when is_list(rows) and is_integer(total) <-
           request(config, :get, "#{path}?limit=#{limit}&offset=#{offset}") do
      next = offset + length(rows)

      cond do
        next >= total -> {:ok, acc ++ rows}
        rows == [] -> failure(:invalid_response)
        true -> page(config, path, field, limit, next, acc ++ rows)
      end
    else
      {:ok, _} -> failure(:invalid_response)
      error -> error
    end
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp request(config, method, path, body \\ nil) do
    url =
      String.trim_trailing(config.url, "/") <>
        "/v1/default/banks/" <> segment(config.bank) <> path

    request =
      if body == nil,
        do: {String.to_charlist(url), []},
        else: {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    timeout = Map.get(config, :timeout_ms, 300_000)

    case :httpc.request(
           method,
           request,
           [timeout: timeout, connect_timeout: timeout, ssl: ssl, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 ->
        case Jason.decode(response) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> failure(:invalid_response)
        end

      {:ok, {{_, status, _}, _, _}} ->
        failure({:http_status, status})

      {:error, :timeout} ->
        failure(:timeout)

      {:error, _} ->
        failure(:transport_error)
    end
  end

  defp failure(reason) do
    Logger.warning("npc_hindsight_failed reason=#{inspect(reason)}")
    {:error, reason}
  end
end
