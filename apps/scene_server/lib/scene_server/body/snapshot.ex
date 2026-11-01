defmodule SceneServer.Body.Snapshot do
  @moduledoc "全局系统功能：完整身体的版本化存档；不保存会话位置、碰撞或派生生命值。"
  alias SceneServer.Body
  @fields [:body, :body_heat, :body_exchange_j, :life_generation, :food_cursors]

  @doc "从身体 owner 提取不可变存档数据。"
  def take(state), do: Map.take(state, @fields ++ [:effect_receipts])

  @doc "身体、作用回执与消费游标同笔编码，避免重启后重复吸收食物或重复结算同一作用。"
  def encode(state), do: :erlang.term_to_binary({:body, if(Map.has_key?(state, :effect_receipts), do: 3, else: 1), take(state)})

  @doc "持久化加载边界：只接受已知版本；损坏存档不得冒充新角色。版本 2 的投射物收据按原 key 并入作用回执。"
  def decode!(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {:body, 3, %{effect_receipts: receipts} = saved} when is_map(receipts) ->
        with_receipts(saved, :effect_receipts, receipts)

      {:body, 2, %{projectile_hits: hits} = saved} when is_map(hits) ->
        with_receipts(saved, :projectile_hits, hits)

      {:body, 1,
       %{
         body: %Body{},
         body_heat: heat,
         body_exchange_j: exchange,
         life_generation: life,
         food_cursors: cursors
       } = saved}
      when is_map(heat) and is_number(exchange) and is_integer(life) and is_map(cursors) and
             map_size(saved) == length(@fields) ->
        saved

      _ ->
        raise ArgumentError, "invalid body snapshot"
    end
  end

  defp with_receipts(saved, field, receipts) do
    base = saved |> Map.delete(field) |> then(&:erlang.term_to_binary({:body, 1, &1})) |> decode!()
    Map.put(base, :effect_receipts, receipts)
  end
end
