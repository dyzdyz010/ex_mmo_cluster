defmodule NpcServer.Life.EmotionVocabulary do
  @moduledoc "经典 OCC 22 类的唯一词表；只描述主观评价语义，不指定动作或权限。"
  @entries [
    {"joy", "喜悦：已发生的事情符合自己的目标"},
    {"distress", "痛苦：已发生的事情损害自己的目标"},
    {"happy_for", "替人高兴：为他人的好际遇高兴"},
    {"sorry_for", "同情：为他人的坏际遇难过"},
    {"gloating", "幸灾乐祸：为他人的坏际遇高兴"},
    {"resentment", "不平：因他人的好际遇不快"},
    {"hope", "希望：期待尚未确定的有利结果"},
    {"fear", "恐惧：担忧尚未确定的不利结果"},
    {"satisfaction", "如愿满足：先前期待的有利结果得到确认"},
    {"fears_confirmed", "担忧成真：先前担忧的不利结果得到确认"},
    {"relief", "宽慰：先前担忧的不利结果没有发生"},
    {"disappointment", "失望：先前期待的有利结果没有发生"},
    {"pride", "自豪：认可自己已发生的行为"},
    {"shame", "羞愧：否定自己已发生的行为"},
    {"admiration", "钦佩：认可他人已发生的行为"},
    {"reproach", "责难：否定他人已发生的行为"},
    {"love", "喜爱：当下被对象本身吸引，不等同长期关系"},
    {"hate", "厌恶：当下排斥对象本身，不等同长期关系"},
    {"gratitude", "感激：认可他人给自己带来有利结果的行为"},
    {"anger", "愤怒：责难他人给自己带来不利结果的行为"},
    {"gratification", "自我嘉许：认可自己带来有利结果的行为"},
    {"remorse", "懊悔：否定自己带来不利结果的行为"}
  ]
  @doc "持久状态使用的词表身份；语义变化须显式迁移。"
  def id, do: "occ22-v1"
  @doc "稳定类别标识。"
  def names, do: Enum.map(@entries, &elem(&1, 0))
  @doc "上下文与展示共用的类别释义。"
  def entries, do: Enum.map(@entries, fn {id, meaning} -> %{id: id, meaning: meaning} end)
end
