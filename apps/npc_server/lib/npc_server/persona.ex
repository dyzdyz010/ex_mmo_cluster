defmodule NpcServer.Persona do
  @moduledoc """
  全局系统功能：人格卡（纯函数）。卡是 NPC 唯一的人格来源，分两段：

      traits   标准特质：{高标记形容词 => 1..9}。键只能取自下面的 52 对形容词表，级别是整数；没写的形容词不出现在描述里。
      personal 自由文本（英文）：偏好、承诺、目标、对重复的态度等标准表覆盖不了的内容；可以是空串。

  词表与英文转写只有这一处实现。写法取自 Serapio-García 等的人格塑造方法（arXiv 2307.00184 表 13、附录 K.1）：
  52 对低 / 高标记形容词对应大五人格 5 个维度，9 级为 `extremely / very /（不加）/ a bit 低词`、`neither 低词 nor 高词`、
  `a bit /（不加）/ very / extremely 高词`。写卡规则与实测依据见
  docs/10-active/cross-cutting/2026-11-11-npc-jev-decision-research.md 的“人格卡”一节；
  `docs/10-active/cross-cutting/tools/jev/big5.py` 是同一写法的离线脚本，现在只作对照。

  信任边界在 `new/1`（注册表登记与读回时各调一次）：JSON 形的卡校验一次，构造成合法的卡
  `%{traits: [{高标记形容词, 级别}], personal: 文本}`；之后的模块直接消费，不再校验。
  特质在卡里按词表次序排列：注册参数是 JSON 对象，键的次序不可依赖，渲染次序由词表这一个有序结构承载
  （`big5.py` 按字典插入次序渲染，对照时先把卡排成词表次序）。
  """

  # 有序：{低标记, 高标记}，按 EXT、AGR、CON、NEU、OPE 五个维度排列。次序即卡里特质的次序。
  @pairs [
    # EXT 外向性
    {"unfriendly", "friendly"},
    {"introverted", "extraverted"},
    {"silent", "talkative"},
    {"timid", "bold"},
    {"unassertive", "assertive"},
    {"inactive", "active"},
    {"unenergetic", "energetic"},
    {"unadventurous", "adventurous and daring"},
    {"gloomy", "cheerful"},
    # AGR 宜人性
    {"distrustful", "trustful"},
    {"immoral", "moral"},
    {"dishonest", "honest"},
    {"unkind", "kind"},
    {"stingy", "generous"},
    {"unaltruistic", "altruistic"},
    {"uncooperative", "cooperative"},
    {"self-important", "humble"},
    {"unsympathetic", "sympathetic"},
    {"selfish", "unselfish"},
    {"disagreeable", "agreeable"},
    # CON 尽责性
    {"unsure", "self-efficacious"},
    {"messy", "orderly"},
    {"irresponsible", "responsible"},
    {"lazy", "hardworking"},
    {"undisciplined", "self-disciplined"},
    {"impractical", "practical"},
    {"extravagant", "thrifty"},
    {"disorganized", "organized"},
    {"negligent", "conscientious"},
    {"careless", "thorough"},
    # NEU 神经质
    {"relaxed", "tense"},
    {"at ease", "nervous"},
    {"easygoing", "anxious"},
    {"calm", "angry"},
    {"patient", "irritable"},
    {"happy", "depressed"},
    {"unselfconscious", "self-conscious"},
    {"level-headed", "impulsive"},
    {"contented", "discontented"},
    {"emotionally stable", "emotionally unstable"},
    # OPE 开放性
    {"unimaginative", "imaginative"},
    {"uncreative", "creative"},
    {"artistically unappreciative", "artistically appreciative"},
    {"unaesthetic", "aesthetic"},
    {"unreflective", "reflective"},
    {"emotionally closed", "emotionally aware"},
    {"uninquisitive", "curious"},
    {"predictable", "spontaneous"},
    {"unintelligent", "intelligent"},
    {"unanalytical", "analytical"},
    {"unsophisticated", "sophisticated"},
    {"socially conservative", "socially progressive"}
  ]
  # 只作按键查找：高标记 => 低标记。
  @low Map.new(@pairs, fn {low, high} -> {high, low} end)

  @type card :: %{traits: [{String.t(), 1..9}], personal: String.t()}

  @doc "52 对形容词 `{低标记, 高标记}`，按词表次序。"
  def pairs, do: @pairs

  @doc """
  JSON 形的卡 → `{:ok, 卡}`。显式拒绝并说明原因：

    * `{:error, {:unknown_trait, 键}}`：键不是词表里的高标记形容词；
    * `{:error, {:invalid_level, 键, 值}}`：级别不是 1..9 的整数；
    * `{:error, :personal_not_text}`：`personal` 不是字符串；
    * `{:error, :invalid_card}`：不是恰好含 `traits`（对象）与 `personal` 两个键的对象。
  """
  @spec new(term()) :: {:ok, card()} | {:error, term()}
  def new(%{"traits" => traits, "personal" => personal} = json)
      when map_size(json) == 2 and is_map(traits) do
    unknown = Enum.find(Map.keys(traits), &(not is_map_key(@low, &1)))

    bad_level =
      Enum.find(traits, fn {_, level} -> not (is_integer(level) and level >= 1 and level <= 9) end)

    cond do
      unknown != nil ->
        {:error, {:unknown_trait, unknown}}

      bad_level != nil ->
        {:error, Tuple.insert_at(bad_level, 0, :invalid_level)}

      not is_binary(personal) ->
        {:error, :personal_not_text}

      true ->
        ordered = for {_low, high} <- @pairs, is_map_key(traits, high), do: {high, traits[high]}
        {:ok, %{traits: ordered, personal: personal}}
    end
  end

  def new(_json), do: {:error, :invalid_card}

  @doc "一个特质的 9 级写法：1 extremely 低 … 4 a bit 低，5 neither 低 nor 高，6 a bit 高 … 9 extremely 高。"
  @spec phrase(String.t(), 1..9) :: String.t()
  def phrase(high, 5), do: "neither #{Map.fetch!(@low, high)} nor #{high}"
  def phrase(high, level) when level < 5, do: modifier(5 - level) <> Map.fetch!(@low, high)
  def phrase(high, level), do: modifier(level - 5) <> high

  defp modifier(1), do: "a bit "
  defp modifier(2), do: ""
  defp modifier(3), do: "very "
  defp modifier(4), do: "extremely "

  @doc """
  整张卡的英文人格描述：`<who>. Personality: <各特质，逗号分隔>.`，`personal` 非空时再接 ` Personal: <personal>`。
  `who` 是角色的英文自称（名字与身份，如 `Lin, a builder`），不属于卡。
  """
  @spec describe(String.t(), card()) :: String.t()
  def describe(who, %{traits: traits, personal: personal}) do
    text =
      "#{who}. Personality: #{Enum.map_join(traits, ", ", fn {high, level} -> phrase(high, level) end)}."

    if personal == "", do: text, else: text <> " Personal: " <> personal
  end
end
