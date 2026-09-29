defmodule MmoContracts.Action do
  @moduledoc "Global system：现有施法与工具共用的会话内行为身份。身体生命代次独立于会话 identity。"
  @doc "绑定 Gate 已鉴权的完整 identity 与客户端意图序号，不能由角色 ID 单独替代。"
  def key(identity, client_intent_seq), do: {identity, client_intent_seq}
end
