defmodule GateServer.NpcLifeRegistryTest do
  @moduledoc "只测试：JSON 登记 Life 选项及决策预算；既有关闭档案由 npc_registry_test 的精确期望覆盖。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Registry, Brain}

  test "life is a separately selectable backend with the already verified runtime composition" do
    llm_env()
    params = %{"goal" => "继续生活", "tools" => %{}, "life" => %{"url" => "http://life.test.invalid"}}

    assert {Brain.Llm, profile} = Registry.brain("life", params)
    assert profile.life == %{url: "http://life.test.invalid"}
    assert profile.max_requests_per_hour == 60
    assert "set_plan" in Enum.map(GateServer.Npc.Abilities.tools(profile), & &1.name)
    assert Registry.brain("llm", params) == {Brain.Llm, profile}

    assert_raise ArgumentError, ~r/1\.\.60/, fn ->
      Registry.brain("life", Map.put(params, "max_requests_per_hour", 61))
    end
  end

  test "life requires its memory service and cannot be silently disabled" do
    llm_env()
    params = %{"goal" => "继续生活", "tools" => %{}}
    previous = System.get_env("NPC_LIFE_HINDSIGHT_URL")
    on_exit(fn ->
      if previous,
        do: System.put_env("NPC_LIFE_HINDSIGHT_URL", previous),
        else: System.delete_env("NPC_LIFE_HINDSIGHT_URL")
    end)

    System.delete_env("NPC_LIFE_HINDSIGHT_URL")
    assert_raise System.EnvError, fn -> Registry.brain("life", params) end
    System.put_env("NPC_LIFE_HINDSIGHT_URL", "http://life.test.invalid")
    assert {Brain.Llm, %{life: %{url: "http://life.test.invalid"}}} = Registry.brain("life", params)

    assert_raise ArgumentError, ~r/life.*false/, fn ->
      Registry.brain("life", Map.put(params, "life", false))
    end
  end

  test "life without explicit service URL is a configuration error" do
    previous = System.get_env("NPC_LIFE_HINDSIGHT_URL")
    System.delete_env("NPC_LIFE_HINDSIGHT_URL")
    on_exit(fn -> if previous, do: System.put_env("NPC_LIFE_HINDSIGHT_URL", previous) end)

    params = %{
      "definition" => String.duplicate("2A", 32),
      "sites" => [],
      "revisit_ticks" => 60,
      "tools" => %{},
      "life" => true
    }

    assert_raise System.EnvError, fn -> Registry.brain("settler", params) end
  end

  test "only life settlers wrap Tree and life llm defaults to sixty hourly decisions" do
    settler = %{
      "definition" => String.duplicate("2A", 32),
      "sites" => [],
      "revisit_ticks" => 60,
      "tools" => %{}
    }

    assert {Brain.Tree, base} = Registry.brain("settler", settler)

    assert {Brain.Social, enabled} =
             Registry.brain(
               "settler",
               Map.put(settler, "life", %{"url" => "http://life.test.invalid"})
             )

    assert Map.delete(enabled, :life) == base
    assert enabled.life == %{url: "http://life.test.invalid"}

    llm_env()

    llm = %{"goal" => "build", "tools" => %{}, "life" => %{"url" => "http://life.test.invalid"}}

    assert {Brain.Llm, %{max_requests_per_hour: 60, life: %{url: "http://life.test.invalid"}}} =
             Registry.brain("llm", llm)

    assert {Brain.Llm, %{max_requests_per_hour: 1}} =
             Registry.brain("llm", Map.put(llm, "max_requests_per_hour", 1))

    assert {Brain.Llm, disabled} = Registry.brain("llm", Map.delete(llm, "life"))
    refute Map.has_key?(disabled, :life)
    refute Map.has_key?(disabled, :max_requests_per_hour)
  end

  @tag :final_fix
  test "life llm rejects explicit hourly budgets above sixty and keeps boundary and disabled profiles" do
    llm_env()
    llm = %{"goal" => "build", "tools" => %{}, "life" => %{"url" => "http://life.test.invalid"}}

    for limit <- [61, 600] do
      assert_raise ArgumentError, ~r/max_requests_per_hour.*1\.\.60/, fn ->
        Registry.brain("llm", Map.put(llm, "max_requests_per_hour", limit))
      end
    end

    for limit <- [1, 60] do
      assert {Brain.Llm, %{max_requests_per_hour: ^limit}} =
               Registry.brain("llm", Map.put(llm, "max_requests_per_hour", limit))
    end

    assert {Brain.Llm, %{max_requests_per_hour: 60}} = Registry.brain("llm", llm)
    disabled = Map.put(llm, "life", false)
    assert {Brain.Llm, profile} = Registry.brain("llm", disabled)
    refute Map.has_key?(profile, :max_requests_per_hour)

    assert {Brain.Llm, %{max_requests_per_hour: 600}} =
             Registry.brain("llm", Map.put(disabled, "max_requests_per_hour", 600))
  end

  defp llm_env do
    env = %{
      "NPC_LLM_URL" => "http://127.0.0.1:9/responses",
      "NPC_LLM_KEY" => "test-key",
      "NPC_LLM_MODEL" => "test"
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)

    on_exit(fn ->
      for {key, value} <- previous,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)
  end
end
