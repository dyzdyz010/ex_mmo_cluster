defmodule NpcServer.NpcHindsightTest do
  @moduledoc "只测试：Hindsight HTTP 信任边界；外部服务由隔离 TCP HTTP 替身代替，不验证模型质量。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.Life.Hindsight

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  @episodes [
    %{
      "id" => "npc-7-world-a-seq-2",
      "text" => "Brann destroyed my wall.",
      "at_ms" => 1_791_676_800_000,
      "seq" => 2
    },
    %{
      "id" => "npc-7-world-a-seq-3",
      "text" => "Mara repaired my wall.",
      "at_ms" => 1_791_676_860_000,
      "seq" => 3
    }
  ]

  test "retain submits one stable episode batch and proves facts for every document" do
    cfg =
      server(fn
        :post, "/v1/default/banks/probe/memories", body ->
          assert body == %{
                   "items" => [
                     %{
                       "document_id" => "npc-7-world-a-seq-2",
                       "content" => "Brann destroyed my wall.",
                       "timestamp" => "2026-10-11T00:00:00.000Z"
                     },
                     %{
                       "document_id" => "npc-7-world-a-seq-3",
                       "content" => "Mara repaired my wall.",
                       "timestamp" => "2026-10-11T00:01:00.000Z"
                     }
                   ],
                   "async" => false
                 }

          {200,
           %{
             "success" => true,
             "bank_id" => "probe",
             "items_count" => 2,
             "async" => false,
             "usage" => %{"input_tokens" => 120}
           }}

        :get, "/v1/default/banks/probe/documents/" <> id, _ ->
          {200, %{"id" => id, "memory_unit_count" => 1}}

        :get, "/v1/default/banks/probe/operations?limit=100&offset=0", _ ->
          {200, %{"operations" => [], "total" => 0}}
      end)

    assert {:ok, %{retained: 2, facts: 2, documents: ids, usage: %{"input_tokens" => 120}}} =
             Hindsight.retain(cfg, @episodes)

    assert ids == ["npc-7-world-a-seq-2", "npc-7-world-a-seq-3"]
    requests = requests(4)
    assert Enum.count(requests, fn {method, _, _} -> method == :post end) == 1
  end

  test "retain passes non-empty tags through to the item and omits the field otherwise" do
    cfg =
      server(fn
        :post, "/v1/default/banks/probe/memories", _ ->
          {200, %{"success" => true, "items_count" => 3, "async" => false}}

        :get, "/v1/default/banks/probe/documents/" <> id, _ ->
          {200, %{"id" => id, "memory_unit_count" => 1}}

        :get, "/v1/default/banks/probe/operations?limit=100&offset=0", _ ->
          {200, %{"operations" => [], "total" => 0}}
      end)

    episodes = [
      Map.put(Enum.at(@episodes, 0), "tags", ["actor:7", "place:hut"]),
      Map.put(Enum.at(@episodes, 1), "tags", []),
      %{
        "id" => "no-tags",
        "text" => "Nothing tagged.",
        "at_ms" => 1_791_676_920_000,
        "tags" => nil
      }
    ]

    assert {:ok, %{retained: 3}} = Hindsight.retain(cfg, episodes)
    assert [{:post, _, %{"items" => [first, second, third]}} | _] = requests(5)
    assert first["tags"] == ["actor:7", "place:hut"]
    refute Map.has_key?(second, "tags")
    refute Map.has_key?(third, "tags")
  end

  test "retain rejects malformed tags before any request" do
    cfg = server(fn _, _, _ -> flunk("must not be requested") end)

    for tags <- ["actor:7", [1], [""]] do
      episode = Map.put(Enum.at(@episodes, 0), "tags", tags)
      assert {:error, :invalid_episodes} = Hindsight.retain(cfg, [episode])
    end

    refute_receive {:http_request, _, _, _}, 30
  end

  test "retain rejects empty extracted facts even after HTTP success" do
    cfg =
      server(fn
        :post, _, _ -> {200, %{"success" => true, "items_count" => 1, "async" => false}}
        :get, _, _ -> {200, %{"memory_unit_count" => 0}}
      end)

    assert {:error, :empty_facts} = Hindsight.retain(cfg, Enum.take(@episodes, 1))
  end

  test "HTTP failures omit service error bodies and URLs" do
    cfg =
      server(fn _, _, _ -> {503, %{"detail" => "Bearer private-secret http://private-host"}} end)

    assert {:error, {:http_status, 503}} = Hindsight.recall(cfg, "Who helped me?", 0)
  end

  test "models only reads four cached documents without refreshing" do
    cfg =
      server(fn :get, "/v1/default/banks/probe/mental-models/" <> suffix, _ ->
        [id, "detail=content"] = String.split(suffix, "?")
        {200, %{"id" => id, "content" => "I remember " <> id, "is_stale" => true}}
      end)

    assert {:ok, %{models: models, truth: truth}} = Hindsight.models(cfg)
    assert map_size(models) == 4
    assert models["relationships"] == "I remember relationships"
    assert truth =~ "not current numeric world truth"

    assert Enum.all?(requests(4), fn {method, path, _} ->
             method == :get and not String.contains?(path, "refresh")
           end)
  end

  test "recall sends one mid-budget timestamped request and records latency" do
    cfg =
      server(fn :post, "/v1/default/banks/probe/memories/recall", body ->
        assert body == %{
                 "query" => "Who helped me?",
                 "budget" => "mid",
                 "max_tokens" => 2048,
                 "query_timestamp" => "2026-10-11T00:00:00.000Z"
               }

        {200,
         %{
           "results" => [
             %{"id" => "fact-1", "text" => "Mara repaired my wall.", "type" => "experience"}
           ]
         }}
      end)

    assert {:ok, %{results: [%{"id" => "fact-1"}], latency_ms: ms}} =
             Hindsight.recall(cfg, "Who helped me?", 1_791_676_800_000)

    assert ms >= 0
    requests(1)
    refute_receive {:http_request, _, _, _}, 30
  end

  test "recall description puts optional filters in the request only when given" do
    cfg =
      server(fn :post, "/v1/default/banks/probe/memories/recall", body ->
        _ = body
        {200, %{"results" => []}}
      end)

    description = %{
      query: "Who helped me?",
      tags: ["actor:920628760578"],
      tags_match: "any_strict",
      types: ["observation"],
      prefer_observations: false,
      max_tokens: 512
    }

    assert {:ok, %{results: []}} = Hindsight.recall(cfg, description, 1_791_676_800_000)
    assert [{:post, _, body}] = requests(1)

    assert body == %{
             "query" => "Who helped me?",
             "budget" => "mid",
             "max_tokens" => 512,
             "query_timestamp" => "2026-10-11T00:00:00.000Z",
             "tags" => ["actor:920628760578"],
             "tags_match" => "any_strict",
             "types" => ["observation"],
             "prefer_observations" => false
           }

    # nil 的键与缺省的键一样不进请求体，max_tokens 回到缺省值。
    nils = %{
      query: "q",
      tags: nil,
      tags_match: nil,
      types: nil,
      prefer_observations: nil,
      max_tokens: nil
    }

    assert {:ok, _} = Hindsight.recall(cfg, nils, 1_791_676_800_000)
    assert [{:post, _, body}] = requests(1)

    assert body == %{
             "query" => "q",
             "budget" => "mid",
             "max_tokens" => 2048,
             "query_timestamp" => "2026-10-11T00:00:00.000Z"
           }
  end

  test "recall rejects a description without a string query before any request" do
    cfg = server(fn _, _, _ -> flunk("must not be requested") end)

    assert {:error, :invalid_query} = Hindsight.recall(cfg, %{tags: ["a"]}, 0)
    assert {:error, :invalid_query} = Hindsight.recall(cfg, nil, 0)
    refute_receive {:http_request, _, _, _}, 30
  end

  test "recall normalizes each result once: at_ms from occurred_start, else mentioned_at, else nil" do
    cfg =
      server(fn :post, "/v1/default/banks/probe/memories/recall", _ ->
        {200,
         %{
           "results" => [
             %{
               "id" => "a",
               "text" => "I guarded the hut.",
               "type" => "experience",
               "occurred_start" => "2026-10-11T00:00:00Z",
               "mentioned_at" => "2026-10-12T00:00:00Z",
               "tags" => ["actor:1", "place:hut"],
               "context" => "dropped by normalization"
             },
             %{
               "id" => "b",
               "text" => "Mara repaired my wall.",
               "type" => "observation",
               "occurred_start" => nil,
               "mentioned_at" => "2026-10-11T00:01:00.500+00:00",
               "tags" => nil
             },
             %{"id" => "c", "text" => "No time at all.", "type" => "world"}
           ]
         }}
      end)

    assert {:ok, %{results: results}} = Hindsight.recall(cfg, "q", 0)

    assert results == [
             %{
               "id" => "a",
               "text" => "I guarded the hut.",
               "type" => "experience",
               "at_ms" => 1_791_676_800_000,
               "tags" => ["actor:1", "place:hut"]
             },
             %{
               "id" => "b",
               "text" => "Mara repaired my wall.",
               "type" => "observation",
               "at_ms" => 1_791_676_860_500,
               "tags" => []
             },
             %{
               "id" => "c",
               "text" => "No time at all.",
               "type" => "world",
               "at_ms" => nil,
               "tags" => []
             }
           ]
  end

  test "recall fails explicitly when a result carries an invalid time string" do
    cfg =
      server(fn :post, _, _ ->
        {200,
         %{
           "results" => [
             %{
               "id" => "ok",
               "text" => "fine",
               "type" => "world",
               "occurred_start" => "2026-10-11T00:00:00Z"
             },
             %{
               "id" => "bad",
               "text" => "broken",
               "type" => "world",
               "occurred_start" => "yesterday"
             }
           ]
         }}
      end)

    assert {:error, :invalid_response} = Hindsight.recall(cfg, "q", 0)
  end

  test "timeouts are explicit and sanitized" do
    cfg =
      server(fn _, _, _ ->
        Process.sleep(100)
        {200, %{"results" => []}}
      end)

    assert {:error, :timeout} = Hindsight.recall(Map.put(cfg, :timeout_ms, 10), "Who?", 0)
  end

  test "refresh waits for completed operations and propagates failed operations" do
    cfg =
      server(fn
        :post, "/v1/default/banks/probe/mental-models/" <> rest, _ ->
          {200, %{"operation_id" => String.replace(rest, "/refresh", ""), "status" => "pending"}}

        :get, "/v1/default/banks/probe/operations/self", _ ->
          {200,
           %{"operation_id" => "self", "status" => "failed", "error_message" => "private-secret"}}
      end)

    assert {:error, {:operation_failed, "failed"}} = Hindsight.refresh(cfg)
  end

  test "operation deadline bounds an in-flight poll request" do
    cfg =
      server(fn
        :post, _, _ ->
          {200, %{"operation_id" => "slow", "status" => "pending"}}

        :get, _, _ ->
          Process.sleep(200)
          {200, %{"operation_id" => "slow", "status" => "processing"}}
      end)

    task = Task.async(fn -> Hindsight.refresh(Map.put(cfg, :operation_timeout_ms, 10)) end)
    assert {:ok, {:error, :operation_timeout}} = Task.yield(task, 100)
  end

  test "ensure creates missing documents and observes their completion" do
    cfg =
      server(fn
        :put, _, _ ->
          {200, %{"bank_id" => "probe"}}

        :patch, "/v1/default/banks/probe/config", _ ->
          {200, %{"bank_id" => "probe"}}

        :get, "/v1/default/banks/probe/mental-models/" <> _, _ ->
          {404, %{"detail" => "absent"}}

        :post, "/v1/default/banks/probe/mental-models", body ->
          assert body["trigger"] == %{"refresh_after_consolidation" => false}
          assert body["source_query"] =~ "not current numeric world truth"
          {200, %{"operation_id" => body["id"]}}

        :get, "/v1/default/banks/probe/operations/" <> id, _ ->
          {200, %{"operation_id" => id, "status" => "completed"}}
      end)

    assert {:ok, %{bank: "probe"}} = Hindsight.ensure(cfg, "Lin")
    assert Enum.count(requests(14), fn {method, _, _} -> method == :post end) == 4
  end

  # 离线测过的两条 mission（S1-L）与产品里的唯一差异是 retain_mission 去掉了角色名；
  # 这里钉住文本，改动必须是有意的。
  test "ensure writes bank mission, then PATCHes retain and observations missions" do
    cfg =
      server(fn
        :put, "/v1/default/banks/probe", _ -> {200, %{"bank_id" => "probe"}}
        :patch, "/v1/default/banks/probe/config", _ -> {200, %{"bank_id" => "probe"}}
        :get, "/v1/default/banks/probe/mental-models/" <> id, _ -> {200, %{"id" => id}}
      end)

    assert {:ok, %{bank: "probe"}} = Hindsight.ensure(cfg, "Lin")
    assert [{:put, _, put}, {:patch, patch_path, patch} | _] = requests(6)
    assert put["mission"] =~ "My first-person builder journal."
    assert patch_path == "/v1/default/banks/probe/config"

    assert patch == %{
             "updates" => %{
               "retain_mission" =>
                 "These are the first-person memories of a character in a game world. " <>
                   "Write every fact in the first person (\"I\"), never as \"the user\" or \"the assistant\". " <>
                   "Keep people's names together with their actor id exactly as written, for example \"Corvin (actor 920628760578)\". " <>
                   "Keep counts and times. " <>
                   "Keep statements that something did not happen (for example \"nobody came near the hut\") as facts in their own right. " <>
                   "Do not treat me as a separate entity called \"assistant\" or \"user\". " <>
                   "Write in English.",
               "observations_mission" =>
                 "Consolidate my memories into first-person observations (\"I\"). " <>
                   "When several memories repeat the same activity, say how many times it happened and what did or did not happen during them. " <>
                   "Keep an event that happened only once or twice as its own observation; do not fold it into the majority. " <>
                   "Keep names with their actor ids. " <>
                   "Write in English."
             }
           }
  end

  test "ensure fails when the config PATCH fails and creates no mental models" do
    cfg =
      server(fn
        :put, _, _ -> {200, %{"bank_id" => "probe"}}
        :patch, _, _ -> {422, %{"detail" => "private-secret"}}
      end)

    assert {:error, {:http_status, 422}} = Hindsight.ensure(cfg, "Lin")
    assert [{:put, _, _}, {:patch, _, _}] = requests(2)
    refute_receive {:http_request, _, _, _}, 30
  end

  test "ensure keeps existing mental models and status reports token aggregates" do
    cfg =
      server(fn
        :put, "/v1/default/banks/probe", body ->
          assert body["name"] == "Lin"
          {200, %{"bank_id" => "probe"}}

        :patch, "/v1/default/banks/probe/config", _ ->
          {200, %{"bank_id" => "probe"}}

        :get, "/v1/default/banks/probe/mental-models/" <> id, _ ->
          {200, %{"id" => id, "content" => "Existing memory"}}

        :get, "/v1/default/banks/probe/stats", _ ->
          {200, %{"total_nodes" => 2}}

        :get, "/v1/default/banks/probe/operations?limit=100&offset=0", _ ->
          {200, %{"operations" => [], "total" => 0}}

        :get, "/v1/default/banks/probe/llm-requests?limit=200&offset=0", _ ->
          {200,
           %{
             "items" => [
               %{
                 "scope" => "retain",
                 "input_tokens" => 120,
                 "output_tokens" => 10,
                 "status" => "success"
               }
             ],
             "total" => 1
           }}
      end)

    assert {:ok, %{bank: "probe"}} = Hindsight.ensure(cfg, "Lin")

    assert {:ok,
            %{
              stats: %{"total_nodes" => 2},
              usage: %{"retain" => %{input_tokens: 120, output_tokens: 10, requests: 1}}
            }} = Hindsight.status(cfg)

    assert Enum.count(requests(9), fn {method, _, _} -> method == :put end) == 1
  end

  # 端口由 OS 分配，每个测试独占；替身只替代外部 HTTP，实际 :httpc 和 JSON 编解码仍运行。
  defp server(handler) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    pid = spawn(fn -> accept(listener, owner, handler) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(pid, :kill)
    end)

    %{url: "http://127.0.0.1:#{port}", bank: "probe", timeout_ms: 1000, poll_interval_ms: 1}
  end

  defp accept(listener, owner, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 1000)

        # Erlang 的 HTTP 解析器只把标准方法解成原子，PATCH 以二进制 "PATCH" 给出。
        method = %{:GET => :get, :PUT => :put, :POST => :post, "PATCH" => :patch}[method]
        size = headers(socket, 0)
        :ok = :inet.setopts(socket, packet: :raw)

        body =
          if size == 0,
            do: nil,
            else:
              with({:ok, bytes} <- :gen_tcp.recv(socket, size, 1000), do: Jason.decode!(bytes))

        send(owner, {:http_request, method, path, body})
        {status, data} = handler.(method, path, body)
        bytes = Jason.encode!(data)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n" <>
            bytes
        )

        :gen_tcp.close(socket)
        accept(listener, owner, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, size) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, :http_eoh} ->
        size

      {:ok, {:http_header, _, name, _, value}} ->
        next =
          if String.downcase(to_string(name)) == "content-length",
            do: String.to_integer(value),
            else: size

        headers(socket, next)
    end
  end

  defp requests(count),
    do:
      for(
        _ <- 1..count,
        do:
          receive do
            {:http_request, method, path, body} -> {method, path, body}
          after
            1000 -> flunk("missing HTTP request")
          end
      )
end
