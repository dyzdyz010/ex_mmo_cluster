defmodule NpcServer.SpendFixtures do
  @moduledoc """
  只测试：花费额度用例共用的运行环境（`NpcServer.SpendBudget.Config.load!/1` 的输入）与时刻换算。

  价目是 DeepSeek 官方价目页 2026-11-19 核对的 deepseek-flash（每百万 token，美元）：高峰入未命中 0.3 / 命中 0.006 / 出 1.2，
  非高峰各取一半。非高峰时段按北京时间写：官方高峰是 UTC 01:00–04:00 与 06:00–10:00（北京 09:00–12:00 与 14:00–18:00），
  其余为非高峰。
  """

  @prices %{
    "deepseek-flash" => %{
      "peak" => %{"miss" => 0.3, "hit" => 0.006, "out" => 1.2},
      "off_peak" => %{"miss" => 0.15, "hit" => 0.003, "out" => 0.6}
    }
  }

  @doc "合法的一组运行环境（上限 65 美元、停止线 90%）；`overrides` 覆盖或增删键（值为 nil 即删掉这个键）。"
  def env(overrides \\ %{}) do
    %{
      "NPC_LIFE_HINDSIGHT_URL" => "http://127.0.0.1:9",
      "NPC_SPEND_LIMIT_USD" => "65",
      "NPC_SPEND_STOP_RATIO" => "0.9",
      "NPC_SPEND_PRICES" => Jason.encode!(@prices),
      "NPC_SPEND_OFF_PEAK" => "00:00-09:00,12:00-14:00,18:00-24:00",
      "NPC_JEV_API" => "openai",
      "NPC_JEV_MODEL" => "deepseek-flash",
      "NPC_REFLECT_MODEL" => "deepseek-flash"
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_, value} -> value == nil end)
  end

  @doc "ISO 8601（带时区）→ Unix 毫秒。"
  def ms(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end
end
