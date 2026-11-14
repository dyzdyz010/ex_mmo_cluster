defmodule NpcServer.ReflectionFixtures do
  @moduledoc """
  只测试：反思用例共用的真实夹具读法（`test/support/fixtures/reflection/`，来源与重新生成见该目录的 README）。
  只读文件与做适配器边界上已有的规范化，不计算被测规则。
  """

  @dir Path.expand("fixtures/reflection", __DIR__)

  @doc "夹具原文。"
  def fixture(name), do: File.read!(Path.join(@dir, name))

  @doc "JSON 夹具。"
  def json(name), do: name |> fixture() |> Jason.decode!()

  @doc "ISO 8601（带时区）→ Unix 毫秒，同 `Life.Hindsight` 召回规范化的取法。"
  def iso_ms(iso) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end

  @doc """
  S1-X2 第 4 轮 Q_place 某一次召回（`"raw"` 原始经历 / `"observation"` 认识）的真实条目，按 `Life.Hindsight.recall/3`
  规范化后的形状 `%{"id", "text", "type", "at_ms", "tags"}`（`at_ms` 取离线脚本的 `occurred_start or mentioned_at`，
  即材料里记下的 `at`），原次序。
  """
  def recalled(kind) do
    for %{"kind" => ^kind} = row <- json("round4-recalled-Q_place.json"),
        do: %{
          "id" => row["id"],
          "text" => row["text"],
          "type" => row["type"],
          "at_ms" => row["at"] && iso_ms(row["at"]),
          "tags" => row["tags"]
        }
  end

  @doc "上面那些条目在离线材料里渲染出的正文（`body`：多久以前 + 去掉后缀的原文），原次序（先原始经历、后认识）。"
  def recalled_bodies, do: Enum.map(json("round4-recalled-Q_place.json"), & &1["body"])

  @doc "第 k 轮“此刻”用的原始观察导出还原成观察（导出是 `inspect` 出的字面量，不含 pid / 函数）。"
  def rawobs(k) do
    {%{observation: observation}, _} = Code.eval_string(fixture("round#{k}-rawobs.txt"))
    observation
  end
end
