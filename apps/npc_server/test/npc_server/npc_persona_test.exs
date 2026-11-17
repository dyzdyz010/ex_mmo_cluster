defmodule NpcServer.NpcPersonaTest do
  @moduledoc """
  只测试：人格卡 `NpcServer.Persona` 的校验与英文转写（纯函数，不启动任何依赖）。

  期望值的来源：
  - 9 级写法的句子按调研稿“人格卡”一节的规则手写（`extremely / very /（不加）/ a bit 低词`、`neither 低词 nor 高词`、
    `a bit /（不加）/ very / extremely 高词`）；
  - 词表与三张整卡的描述是 `docs/10-active/cross-cutting/tools/jev/big5.py` 在 2026-11-12 的输出（冻结对照，独立实现）：
    `PAIRS` 展平成 `[低, 高]` 列表；`describe(card)` 取 `CARDS` 的 lin / garrick / hask，特质先排成词表次序
    （服务端按词表次序渲染，`big5.py` 按字典插入次序）。
  """
  use ExUnit.Case, async: true
  alias NpcServer.Persona

  # big5.py 的 PAIRS（EXT、AGR、CON、NEU、OPE），冻结。
  @big5_pairs [
    ["unfriendly", "friendly"],
    ["introverted", "extraverted"],
    ["silent", "talkative"],
    ["timid", "bold"],
    ["unassertive", "assertive"],
    ["inactive", "active"],
    ["unenergetic", "energetic"],
    ["unadventurous", "adventurous and daring"],
    ["gloomy", "cheerful"],
    ["distrustful", "trustful"],
    ["immoral", "moral"],
    ["dishonest", "honest"],
    ["unkind", "kind"],
    ["stingy", "generous"],
    ["unaltruistic", "altruistic"],
    ["uncooperative", "cooperative"],
    ["self-important", "humble"],
    ["unsympathetic", "sympathetic"],
    ["selfish", "unselfish"],
    ["disagreeable", "agreeable"],
    ["unsure", "self-efficacious"],
    ["messy", "orderly"],
    ["irresponsible", "responsible"],
    ["lazy", "hardworking"],
    ["undisciplined", "self-disciplined"],
    ["impractical", "practical"],
    ["extravagant", "thrifty"],
    ["disorganized", "organized"],
    ["negligent", "conscientious"],
    ["careless", "thorough"],
    ["relaxed", "tense"],
    ["at ease", "nervous"],
    ["easygoing", "anxious"],
    ["calm", "angry"],
    ["patient", "irritable"],
    ["happy", "depressed"],
    ["unselfconscious", "self-conscious"],
    ["level-headed", "impulsive"],
    ["contented", "discontented"],
    ["emotionally stable", "emotionally unstable"],
    ["unimaginative", "imaginative"],
    ["uncreative", "creative"],
    ["artistically unappreciative", "artistically appreciative"],
    ["unaesthetic", "aesthetic"],
    ["unreflective", "reflective"],
    ["emotionally closed", "emotionally aware"],
    ["uninquisitive", "curious"],
    ["predictable", "spontaneous"],
    ["unintelligent", "intelligent"],
    ["unanalytical", "analytical"],
    ["unsophisticated", "sophisticated"],
    ["socially conservative", "socially progressive"]
  ]

  test "the adjective table is the 52 pairs of big5.py, in the same order" do
    assert 52 == length(@big5_pairs)
    assert @big5_pairs == Enum.map(Persona.pairs(), &Tuple.to_list/1)
  end

  test "the nine levels of one pair, written out by hand" do
    assert [
             "extremely timid",
             "very timid",
             "timid",
             "a bit timid",
             "neither timid nor bold",
             "a bit bold",
             "bold",
             "very bold",
             "extremely bold"
           ] == Enum.map(1..9, &Persona.phrase("bold", &1))

    assert "neither unfriendly nor friendly" == Persona.phrase("friendly", 5)
    assert "very relaxed" == Persona.phrase("tense", 2)
    assert "extremely adventurous and daring" == Persona.phrase("adventurous and daring", 9)
  end

  test "a JSON card becomes a valid card whose traits follow the table order, not the JSON key order" do
    # JSON 对象的键没有次序；卡里的次序取词表：friendly（EXT 第 1）、bold（EXT 第 4）、tense（NEU 第 1）。
    json = %{
      "traits" => %{"tense" => 2, "bold" => 8, "friendly" => 5},
      "personal" => "Keeps promises."
    }

    assert {:ok, card} = Persona.new(json)

    assert %{traits: [{"friendly", 5}, {"bold", 8}, {"tense", 2}], personal: "Keeps promises."} ==
             card

    assert "Tam, a guard. Personality: neither unfriendly nor friendly, very bold, very relaxed. " <>
             "Personal: Keeps promises." == Persona.describe("Tam, a guard", card)
  end

  test "an empty personal section leaves the sentence without the Personal part" do
    {:ok, card} = Persona.new(%{"traits" => %{"friendly" => 5}, "personal" => ""})
    assert "Mute. Personality: neither unfriendly nor friendly." == Persona.describe("Mute", card)
  end

  # big5.py describe() 的冻结输出。
  for {who, traits, personal, expected} <- [
        {"Lin, a builder",
         %{
           "impulsive" => 2,
           "thrifty" => 8,
           "organized" => 8,
           "thorough" => 8,
           "responsible" => 9,
           "extraverted" => 3,
           "talkative" => 3
         }, "Dislikes crowds and noise. Always keeps the promises she makes.",
         "Lin, a builder. Personality: introverted, silent, extremely responsible, very thrifty, very organized, " <>
           "very thorough, very level-headed. Personal: Dislikes crowds and noise. Always keeps the promises she makes."},
        {"Garrick, a hunter",
         %{
           "bold" => 8,
           "adventurous and daring" => 9,
           "impulsive" => 8,
           "energetic" => 8,
           "thrifty" => 3
         }, "Loves meat, strong drink and a good fight. Gets bored by routine.",
         "Garrick, a hunter. Personality: very bold, very energetic, extremely adventurous and daring, extravagant, " <>
           "very impulsive. Personal: Loves meat, strong drink and a good fight. Gets bored by routine."},
        {"Hask, a farmhand",
         %{
           "hardworking" => 2,
           "active" => 2,
           "adventurous and daring" => 3,
           "anxious" => 3,
           "tense" => 3
         }, "Does the least that lets him get by.",
         "Hask, a farmhand. Personality: very inactive, unadventurous, very lazy, relaxed, easygoing. " <>
           "Personal: Does the least that lets him get by."}
      ] do
    test "frozen big5.py description: #{who}" do
      {:ok, card} =
        Persona.new(%{"traits" => unquote(Macro.escape(traits)), "personal" => unquote(personal)})

      assert unquote(expected) == Persona.describe(unquote(who), card)
    end
  end

  test "bad cards are rejected with the reason" do
    card = fn traits -> %{"traits" => traits, "personal" => ""} end

    # 键不在词表里；低标记词不是键（键只能是高标记形容词）。
    assert {:error, {:unknown_trait, "brave"}} == Persona.new(card.(%{"brave" => 8}))
    assert {:error, {:unknown_trait, "timid"}} == Persona.new(card.(%{"timid" => 2}))

    # 级别必须是 1..9 的整数。
    assert {:error, {:invalid_level, "bold", 0}} == Persona.new(card.(%{"bold" => 0}))
    assert {:error, {:invalid_level, "bold", 10}} == Persona.new(card.(%{"bold" => 10}))
    assert {:error, {:invalid_level, "bold", 8.0}} == Persona.new(card.(%{"bold" => 8.0}))
    assert {:error, {:invalid_level, "bold", "8"}} == Persona.new(card.(%{"bold" => "8"}))

    assert {:error, :personal_not_text} ==
             Persona.new(%{"traits" => %{"bold" => 8}, "personal" => nil})

    assert {:error, :personal_not_text} ==
             Persona.new(%{"traits" => %{"bold" => 8}, "personal" => 3})

    # 不是恰好两段的对象。
    assert {:error, :invalid_card} == Persona.new(%{"traits" => %{"bold" => 8}})
    assert {:error, :invalid_card} == Persona.new(%{"traits" => [], "personal" => ""})

    assert {:error, :invalid_card} ==
             Persona.new(%{"traits" => %{}, "personal" => "", "who" => "Lin"})

    assert {:error, :invalid_card} == Persona.new("very bold")
  end
end
