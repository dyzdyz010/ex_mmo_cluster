defmodule AuthServer.Identity do
  @moduledoc "全局系统功能：邮箱密码、注册资格与账号会话的唯一认证边界。"
  alias DataService.AccountStore, as: Store
  @password_options [argon2_type: 2, t_cost: 2, m_cost: 16, parallelism: 1]

  @doc "旧码需先由受控运维导入；独立邮箱证明不受新注册邀请码开关影响。"
  def send_claim_email(email,legacy,source) when is_binary(legacy) and byte_size(legacy)<=256 do
    with {:ok,email} <- normalize_email(email),
         :ok <- AuthServer.RateLimit.take({:mail_ip,source},20,3600),
         :ok <- AuthServer.RateLimit.take({:mail_email,email},1,60),
         %{id: id} <- Store.legacy_account(digest(legacy)) do
      code=random_token()
      Store.put_challenge(email,"legacy_claim",proof_digest(email,"legacy_claim",Integer.to_string(id)<>"/"<>code),now()+600)
      AuthServer.Mailer.deliver(email,:legacy_claim,code)
    else
      nil -> {:error,:invalid_legacy_claim}
      error -> error
    end
  end
  def send_claim_email(_,_,_),do: {:error,:invalid_legacy_claim}
  @doc "原 account_id/cid/角色数据不变，不覆盖已有正式凭据。"
  def claim_legacy(email,password,code,legacy) when is_binary(legacy) and byte_size(legacy)<=256 and is_binary(code) and byte_size(code)<=128 do
    with {:ok,email} <- normalize_email(email), :ok <- password_valid(password),
         :ok <- AuthServer.RateLimit.take({:claim,email},10,600),
         %{id: id} <- Store.legacy_account(digest(legacy)) do
      Store.attempt_challenge(email,"legacy_claim",now())
      with {:ok,sids} <- Store.claim_legacy(email,proof_digest(email,"legacy_claim",Integer.to_string(id)<>"/"<>code),digest(legacy),Argon2.hash_pwd_salt(password,@password_options),now()),do: AuthServer.Connections.close_sessions(sids)
    else
      nil -> {:error,:invalid_legacy_claim}
      error -> error
    end
  end
  def claim_legacy(_,_,_,_),do: {:error,:invalid_legacy_claim}

  @doc "当前注册界面所需的公开策略。"
  def registration_policy, do: %{invite_required: Store.policy()}

  @doc "验证格式和注册资格后发送限时邮箱证明；仅投递层可替换。"
  def send_registration_email(email, invite, source) do
    with {:ok,email} <- normalize_email(email),
         :ok <- AuthServer.RateLimit.take({:mail_ip,source},20,3600),
         :ok <- AuthServer.RateLimit.take({:mail_email,email},1,60),
         :ok <- Store.admission(invite_digest(invite),now()) do
      # 已有邮箱与新邮箱的公开响应一致，不替换现有凭据。
      if Store.account(email) do
        :ok
      else
        <<random::unsigned-64>> = :crypto.strong_rand_bytes(8)
        code = rem(random,1_000_000) |> Integer.to_string() |> String.pad_leading(6,"0")
        Store.put_challenge(email,"registration",proof_digest(email,"registration",code),now()+600)
        AuthServer.Mailer.deliver(email,:registration,code)
      end
    end
  end

  @doc "校验密码并提交唯一注册事务，不自动签发会话。"
  def register(email,password,code,invite) do
    with {:ok,email} <- normalize_email(email), :ok <- password_valid(password),
         true <- is_binary(code) and byte_size(code) <= 128,
         :ok <- AuthServer.RateLimit.take({:register,email},10,600) do
      Store.attempt_challenge(email,"registration",now())
      Store.register(email,Argon2.hash_pwd_salt(password,@password_options),proof_digest(email,"registration",code),invite_digest(invite),now())
    else
      false -> {:error,:invalid_verification}
      error -> error
    end
  end

  @doc "密码登录，确认身份由服务端返回；邮箱不作为游戏公开名称。"
  def login(email,password,remember) do
    with {:ok,email} <- normalize_email(email), true <- is_binary(password) and byte_size(password) <= 512,
         :ok <- AuthServer.RateLimit.take({:login,email},10,60) do
      account = Store.account(email)
      verified = if account && account.password_hash, do: Argon2.verify_pass(password,account.password_hash), else: Argon2.no_user_verify(@password_options)
      cond do
        not verified -> {:error,:invalid_credentials}
        account.disabled_at != nil -> {:error,:account_disabled}
        true ->
          sid = Ecto.UUID.generate()
          expiry = now()+if(remember == true,do: 30*86400,else: 86400)
          {public,tokens} = credentials(expiry)
          with :ok <- Store.create_session(sid,account.id,account.password_hash,expiry,tokens,now()), do: {:ok,session_result(account.id,sid,expiry,public)}
      end
    else
      false -> {:error,:invalid_credentials}
      {:error,:invalid_email} -> {:error,:invalid_credentials}
      error -> error
    end
  end

  @doc "访问令牌只能用于 HTTP，会话状态在服务端持续生效。"
  def authenticate(token) when is_binary(token) and byte_size(token) <= 256 do
    case Store.authenticate(digest(token),"access",now()) do
      nil -> {:error,:invalid_session}
      context -> {:ok,context}
    end
  end
  def authenticate(_), do: {:error,:invalid_session}

  @doc "刷新原子轮换；重放旧凭据使该会话失效。"
  def refresh(token) when is_binary(token) and byte_size(token) <= 256 do
    {public,tokens} = credentials(now()+30*86400)
    case Store.rotate(digest(token),tokens,now()) do
      {:ok,{:reused,sid}} ->
        AuthServer.Connections.close_sessions([sid])
        {:error,:invalid_session}
      {:ok,context} -> {:ok,session_result(context.account_id,context.session_id,context.expires_at,public)}
      error -> error
    end
  end
  def refresh(_), do: {:error,:invalid_session}

  @doc "退出本设备或全部设备，成功意味着登记的旧连接已经关闭。"
  def logout(token,all \\ false) do
    with {:ok,c} <- authenticate(token), do: AuthServer.Connections.revoke(c.account_id,if(all,do: nil,else: c.session_id))
  end

  @doc "每次管理操作均检查当前账号权限，普通访问令牌不带隐含管理权。"
  def administer(token,operation,args) do
    with {:ok,%{auth_admin: true}=context} <- authenticate(token) do
      AuthServer.Admin.execute(Integer.to_string(context.account_id),operation,args)
    else
      {:ok,_} -> {:error,:forbidden}
      error -> error
    end
  end

  @doc "申请一次性游戏入场票据；Hello 由服务器部署配置提供。"
  def game_ticket(access,scene,hello) when is_binary(access) and is_integer(scene) and scene>0 do
    ticket=random_token()
    with {:ok,c} <- Store.issue_ticket(digest(access),digest(ticket),scene,:erlang.term_to_binary(hello),now()) do
      {a,character}=Store.account_with_character(c.account_id)
      {:ok,%{token: ticket,cid: Integer.to_string(character.id),username: a.username}}
    end
  end
  def game_ticket(_,_,_),do: {:error,:invalid_session}
  @doc "由 Gate 的正常入场边界调用，消费与连接登记串行化。"
  def consume_ticket(ticket,cid,username,scene,hello,pid) when is_binary(ticket) do
    AuthServer.Connections.consume(digest(ticket),cid,username,scene,:erlang.term_to_binary(hello),pid)
  end
  def consume_ticket(_,_,_,_,_,_),do: {:error,:invalid_ticket}

  @doc "找回入口不泄露邮箱是否存在。"
  def forgot_password(email,source) do
    with {:ok,email} <- normalize_email(email),
         :ok <- AuthServer.RateLimit.take({:reset_ip,source},20,3600),
         :ok <- AuthServer.RateLimit.take({:reset_email,email},1,60) do
      case Store.account(email) do
        %{password_hash: hash} when is_binary(hash) ->
          code=random_token()
          Store.put_challenge(email,"password_reset",proof_digest(email,"password_reset",code),now()+1800)
          AuthServer.Mailer.deliver(email,:password_reset,code)
        _ -> :ok
      end
    end
  end
  @doc "通过独立用途重置码改密，成功后必须重新登录。"
  def reset_password(email,code,password) do
    with {:ok,email} <- normalize_email(email), :ok <- password_valid(password), true <- is_binary(code) and byte_size(code)<=128 do
      Store.attempt_challenge(email,"password_reset",now())
      with {:ok,ids} <- Store.reset_password(email,proof_digest(email,"password_reset",code),Argon2.hash_pwd_salt(password,@password_options),now()),do: AuthServer.Connections.close_sessions(ids)
    else
      false -> {:error,:invalid_verification}
      error -> error
    end
  end
  @doc "账号中心展示的身份摘要；调用方已通过 authenticate/1。"
  def profile(account_id) do
    {a,c}=Store.account_with_character(account_id)
    %{email: a.email, character: c.name}
  end
  @doc "网页顶栏的当前登录者；未登录或会话已失效时为 nil。"
  def viewer(token) do
    case authenticate(token) do
      {:ok,c} -> profile(c.account_id) |> Map.put(:admin,c.auth_admin)
      _ -> nil
    end
  end
  @doc "当前密码确认后更改密码，清除所有设备会话。"
  def change_password(access,current,password) do
    with {:ok,c} <- authenticate(access), :ok <- password_valid(password), true <- is_binary(current) and byte_size(current)<=512 do
      {a,_}=Store.account_with_character(c.account_id)
      if Argon2.verify_pass(current,a.password_hash) do
        with {:ok,ids} <- Store.change_password(a.id,a.password_hash,Argon2.hash_pwd_salt(password,@password_options),now()),do: AuthServer.Connections.close_sessions(ids)
      else
        {:error,:invalid_credentials}
      end
    else
      false -> {:error,:invalid_credentials}
      error -> error
    end
  end

  @doc false
  def normalize_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    if byte_size(normalized) <= 254 and Regex.match?(~r/\A[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+\z/u,normalized), do: {:ok,normalized}, else: {:error,:invalid_email}
  end
  def normalize_email(_), do: {:error,:invalid_email}
  @doc false
  def digest(value), do: :crypto.hash(:sha256,value)
  @doc false
  def random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  @doc false
  def invite_digest(nil), do: nil
  def invite_digest(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.upcase() |> String.replace("-","")
    if normalized == "", do: nil, else: digest(normalized)
  end
  def invite_digest(_), do: digest("invalid")
  @doc false
  def now, do: System.system_time(:second)
  @doc false
  def proof_digest(email,purpose,code) do
    secret = Application.fetch_env!(:auth_server,AuthServerWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)
    :crypto.mac(:hmac,:sha256,secret,purpose <> "\0" <> email <> "\0" <> code)
  end

  defp password_valid(value) when is_binary(value) do
    if byte_size(value) <= 512 and String.length(value) in 15..128 and String.downcase(value) not in ["passwordpassword","123456789012345","1234567890123456","qwertyuiopasdfgh"], do: :ok, else: {:error,:invalid_password}
  end
  defp password_valid(_), do: {:error,:invalid_password}
  defp credentials(expiry) do
    access = random_token()
    refresh = random_token()
    {%{access_token: access,refresh_token: refresh,access_expires_at: now()+900},
      [%{digest: digest(access),purpose: "access",expires_at: min(now()+900,expiry)},%{digest: digest(refresh),purpose: "refresh",expires_at: expiry}]}
  end
  defp session_result(account_id,sid,expiry,public) do
    {account,character} = Store.account_with_character(account_id)
    public = Map.update!(public,:access_expires_at,&min(&1,expiry))
    Map.merge(public,%{account_id: Integer.to_string(account_id),cid: Integer.to_string(character.id),username: account.username,session_id: sid,expires_at: expiry})
  end
end
