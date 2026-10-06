defmodule AuthServer.Admin do
  @moduledoc "全局系统功能：受控本机管理命令；网页入口必须通过 Identity.administer 鉴权。"
  alias DataService.AccountStore, as: Store
  alias AuthServer.Identity
  @invite_alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  @doc "受控控制台导入现有摘要→username 文件；原码不入库。"
  def import_legacy(path) do
    records=File.read!(path) |> Jason.decode!() |> Enum.map(fn {hex,user} -> {Base.decode16!(hex,case: :mixed),user} end)
    Store.import_legacy(records,Identity.now())
  end

  @doc "运维控制台签发邀请码，原码仅在返回值出现一次。"
  def generate_invites(count,batch,expiry), do: execute("console",:generate,{count,batch,expiry})
  @doc "运维控制台读取邀请历史。"
  def list_invites(filters \\ %{}), do: Store.invites(filters)
  @doc "运维控制台切换注册策略。"
  def set_invite_required(value), do: execute("console",:policy,value)
  @doc "运维控制台逻辑删除，保留使用历史。"
  def delete_invite(id), do: execute("console",:delete,id)
  @doc "只通过受控发布控制台授予／撤销后台权限。"
  def grant(email,enabled \\ true) do
    with {:ok,email} <- Identity.normalize_email(email), do: Store.grant_admin(email,enabled,"console",Identity.now())
  end
  @doc "受控命令停用账号并关闭游戏连接。"
  def disable(account_id) do
    with {:ok,ids} <- Store.disable_account(account_id,"console",Identity.now()),do: AuthServer.Connections.close_sessions(ids)
  end

  @doc false
  def execute(actor,:generate,{count,batch,expiry}) when is_integer(count) and count in 1..100 and is_binary(batch) and byte_size(batch) <= 160 do
    if is_nil(expiry) or (is_integer(expiry) and expiry > Identity.now()) do
      records = for _ <- 1..count do
        code = invitation_code()
        %{id: Ecto.UUID.generate(),code: code,digest: Identity.invite_digest(code),hint: String.first(code) <> "…" <> String.last(code)}
      end
      case Store.create_invites(records,actor,batch,expiry,Identity.now()) do
        :ok -> {:ok,Enum.map(records,&Map.take(&1,[:id,:code,:hint]))}
        {:error,:invite_collision} -> execute(actor,:generate,{count,batch,expiry})
        error -> error
      end
    else
      {:error,:invalid_request}
    end
  end
  def execute(actor,:policy,value) when is_boolean(value), do: Store.set_policy(value,actor,Identity.now())
  def execute(_actor,:list,filters), do: {:ok,Store.invites(filters)}
  def execute(actor,operation,id) when operation in [:delete,:revoke] do
    case Ecto.UUID.cast(id) do
      {:ok,id} -> Store.retire_invite(id,operation,actor,Identity.now())
      _ -> {:error,:invalid_request}
    end
  end
  def execute(_,_,_), do: {:error,:invalid_request}

  # 32 个可区分字符均匀抽样；只接受同时包含数字和字母的五位码。
  defp invitation_code do
    <<bits::bitstring-size(25),_::7>> = :crypto.strong_rand_bytes(4)
    code = for <<index::5 <- bits>>, into: "", do: <<:binary.at(@invite_alphabet,index)>>
    if code =~ ~r/[A-Z]/ and code =~ ~r/[2-9]/, do: code, else: invitation_code()
  end
end
