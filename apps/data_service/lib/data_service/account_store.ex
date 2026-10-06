defmodule DataService.AccountStore do
  @moduledoc "全局系统功能：账号身份持久化公共边界；注册、兑换和会话状态在 PostgreSQL 原子提交。"
  alias DataService.Repo
  alias DataService.Schema.{Account, Character}
  import Ecto.Query

  @doc "受控导入旧码摘要与原账号映射；禁止重新激活已消费的映射。"
  def import_legacy(records,now) do
    transaction(fn ->
      Enum.each(records, fn {digest,username} ->
        account=one("SELECT id,password_hash FROM accounts WHERE username=$1 FOR UPDATE",[username])
        if is_nil(account) or account.password_hash != nil,do: Repo.rollback(:invalid_legacy_account)
        sql("INSERT INTO auth_legacy_claims(digest,account_id) VALUES($1,$2) ON CONFLICT(digest) DO NOTHING",[digest,account.id])
        audit("console","legacy_import",Integer.to_string(account.id),%{},now)
      end)
      :ok
    end) |> done()
  end
  @doc "旧码的资格只用于邮箱认领，不用于游戏授权。"
  def legacy_account(digest) do
    one("SELECT a.id FROM auth_legacy_claims l JOIN accounts a ON a.id=l.account_id WHERE l.digest=$1 AND l.consumed_at IS NULL AND a.password_hash IS NULL AND a.disabled_at IS NULL",[digest])
  end
  @doc "独立邮箱证明加旧身份归属证明，在原账号绑定密码并消费该账号全部旧映射。"
  def claim_legacy(email,proof,legacy,hash,now) do
    transaction(fn ->
      challenge!(email,"legacy_claim",proof,now)
      old=legacy_account(legacy) || Repo.rollback(:invalid_legacy_claim)
      current=one("SELECT password_hash,disabled_at FROM accounts WHERE id=$1 FOR UPDATE",[old.id])
      if current.password_hash != nil or current.disabled_at != nil,do: Repo.rollback(:invalid_legacy_claim)
      if account(email),do: Repo.rollback(:registration_failed)
      sql("UPDATE accounts SET email=$2,password_hash=$3,email_verified_at=$4,updated_at=to_timestamp($4::bigint::double precision) AT TIME ZONE 'UTC' WHERE id=$1",[old.id,email,hash,now])
      sql("UPDATE auth_legacy_claims SET consumed_at=$2 WHERE account_id=$1",[old.id,now])
      sql("DELETE FROM auth_challenges WHERE email=$1 AND purpose='legacy_claim'",[email])
      audit(Integer.to_string(old.id),"legacy_claim",Integer.to_string(old.id),%{},now)
      revoke_all!(old.id,now)
    end)
  rescue
    e in [Ecto.ConstraintError,Postgrex.Error] -> if constraint?(e),do: {:error,:registration_failed},else: reraise(e,__STACKTRACE__)
  end

  @doc "查询注册策略。"
  def policy, do: one("SELECT invite_required FROM auth_registration_policy WHERE id=1", []).invite_required

  @doc "修改注册策略，和注册事务共用策略行锁。"
  def set_policy(required, actor, now) when is_boolean(required) do
    transaction(fn ->
      sql("UPDATE auth_registration_policy SET invite_required=$1 WHERE id=1", [required])
      audit(actor, "registration_policy", "1", %{invite_required: required}, now)
      :ok
    end) |> done()
  end

  @doc "保存一批随机邀请码的摘要，原码由 Auth 仅交付一次。"
  def create_invites(records, actor, batch, expires_at, now) do
    transaction(fn ->
      Enum.each(records, fn r ->
        result = sql("INSERT INTO auth_invites(id,digest,hint,batch,created_by,created_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(digest) DO NOTHING",
          [uuid(r.id), r.digest, r.hint, batch, actor, now, expires_at])
        if result.num_rows == 0, do: Repo.rollback(:invite_collision)
        audit(actor, "invite_created", r.id, %{batch: batch, expires_at: expires_at}, now)
      end)
      :ok
    end) |> done()
  end

  @doc "分页读取不含摘要的邀请记录，并关联当前邮箱和角色。"
  def invites(filters) do
    rows("""
    SELECT i.id::text, i.hint, i.batch, i.created_by, i.created_at, i.expires_at,
           i.revoked_at, i.deleted_at, i.used_by, i.used_at, a.email,
           (SELECT c.name FROM characters c WHERE c.account=i.used_by ORDER BY c.id LIMIT 1) AS character
    FROM auth_invites i LEFT JOIN accounts a ON a.id=i.used_by
    WHERE ($1::uuid IS NULL OR i.id=$1) AND ($2 OR i.deleted_at IS NULL)
      AND ($3::text IS NULL OR i.batch ILIKE $3 OR i.hint ILIKE $3 OR a.email ILIKE $3 OR i.used_by::text=$4)
    ORDER BY i.created_at DESC, i.id LIMIT 100 OFFSET $5
    """, [if(filters[:id], do: uuid(filters.id)), filters[:include_deleted] == true,
      if(filters[:search], do: "%#{filters.search}%"), filters[:search], max(filters[:offset] || 0, 0)])
  end

  @doc "停用或逻辑删除；兑换共用同一行锁，不影响已经创建的账号。"
  def retire_invite(id, action, actor, now) when action in [:delete, :revoke] do
    column = if action == :delete, do: "deleted_at", else: "revoked_at"
    transaction(fn ->
      result = sql("UPDATE auth_invites SET #{column}=COALESCE(#{column},$2) WHERE id=$1", [uuid(id), now])
      if result.num_rows == 0, do: Repo.rollback(:not_found)
      audit(actor, "invite_#{action}", id, %{}, now)
      :ok
    end) |> done()
  end

  @doc "注册发信前检查资格，不消费邀请码。"
  def admission(digest, now) do
    cond do
      not policy() -> :ok
      is_nil(digest) -> {:error, :invite_required}
      valid_invite(digest, now, false) -> :ok
      true -> {:error, :invalid_invite}
    end
  end

  @doc "写入限时邮箱证明摘要；重发替换旧证明。"
  def put_challenge(email, purpose, digest, expires_at) do
    sql("""
    INSERT INTO auth_challenges(email,purpose,digest,expires_at) VALUES($1,$2,$3,$4)
    ON CONFLICT(email,purpose) DO UPDATE SET digest=$3,expires_at=$4,attempts=0
    """, [email, purpose, digest, expires_at])
    :ok
  end

  @doc "先消耗一次验证尝试；失败尝试不会因后续业务事务回滚而清零。"
  def attempt_challenge(email, purpose, now) do
    sql("UPDATE auth_challenges SET attempts=attempts+1 WHERE email=$1 AND purpose=$2 AND expires_at>$3", [email,purpose,now])
    :ok
  end

  @doc "注册时原子消费邮箱证明、必要的邀请码，并创建唯一账号与角色。"
  def register(email, hash, proof, invite, now) do
    transaction(fn ->
      required = one("SELECT invite_required FROM auth_registration_policy WHERE id=1 FOR SHARE", []).invite_required
      challenge!(email, "registration", proof, now)
      redeemed = if required do
        if is_nil(invite), do: Repo.rollback(:invite_required)
        valid_invite(invite, now, true) || Repo.rollback(:invalid_invite)
      end
      if account(email), do: Repo.rollback(:registration_failed)
      id = one("SELECT nextval('auth_account_ids') AS id", []).id
      name = "u_#{id}"
      account = Repo.insert!(%Account{id: id, username: name, email: email, password_hash: hash, email_verified_at: now},log: false)
      cid = one("SELECT nextval('auth_character_ids') AS id", []).id
      Repo.insert!(%Character{id: cid, account: id, name: "旅人_#{cid}", title: "", base_attrs: %{}, battle_attrs: %{},
        position: %{"x" => 750.0, "y" => 750.0, "z" => 185.0}, hp: 500, sp: 100, mp: 100},log: false)
      if redeemed, do: sql("UPDATE auth_invites SET used_by=$2,used_at=$3 WHERE id=$1", [redeemed.id,id,now])
      sql("DELETE FROM auth_challenges WHERE email=$1 AND purpose='registration'", [email])
      account
    end)
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if constraint?(e), do: {:error, :registration_failed}, else: reraise(e, __STACKTRACE__)
  end

  @doc "查找登录邮箱；旧开发账户没有 password_hash，不因此获得密码登录资格。"
  def account(email), do: Repo.one(from(a in Account, where: fragment("lower(?)", a.email) == ^email),log: false)
  @doc "读取账号及首版唯一角色。"
  def account_with_character(id) do
    with %Account{} = a <- Repo.get(Account,id,log: false), %Character{} = c <- Repo.one(from(c in Character, where: c.account == ^id, order_by: c.id, limit: 1),log: false), do: {a,c}
  end

  @doc "建立账号会话与访问／刷新凭据。"
  def create_session(id, account_id, expected_hash, expires_at, tokens, now) do
    transaction(fn ->
      current=lock_account!(account_id)
      if current.password_hash != expected_hash, do: Repo.rollback(:invalid_credentials)
      sql("INSERT INTO auth_sessions(id,account_id,expires_at) VALUES($1,$2,$3)", [uuid(id),account_id,expires_at])
      Enum.each(tokens, &insert_token(id, &1, now))
      :ok
    end) |> done()
  end

  @doc "每次接纳时查询用途、期限、撤销和账号状态。"
  def authenticate(digest, purpose, now) do
    one("""
    SELECT s.id::text AS session_id,s.account_id,s.expires_at,a.username,a.auth_admin
    FROM auth_tokens t JOIN auth_sessions s ON s.id=t.session_id JOIN accounts a ON a.id=s.account_id
    WHERE t.digest=$1 AND t.purpose=$2 AND t.consumed_at IS NULL AND t.expires_at>$3
      AND s.expires_at>$3 AND s.revoked_at IS NULL AND a.disabled_at IS NULL
    """, [digest,purpose,now])
  end

  @doc "锁定会话后轮换；旧刷新凭据重用提交撤销，而不是回滚撤销。"
  def rotate(digest, tokens, now) do
    transaction(fn ->
      token = one("SELECT session_id,purpose,consumed_at,expires_at FROM auth_tokens WHERE digest=$1", [digest])
      if is_nil(token) or token.purpose != "refresh", do: Repo.rollback(:invalid_session)
      owner=one("SELECT account_id FROM auth_sessions WHERE id=$1",[token.session_id])
      lock_account!(owner.account_id)
      session = one("SELECT id::text AS session_id,account_id,expires_at,revoked_at FROM auth_sessions WHERE id=$1 FOR UPDATE", [token.session_id])
      # 持锁后重读，不能使用等待行锁前取得的 consumed_at。
      token = one("SELECT consumed_at,expires_at FROM auth_tokens WHERE digest=$1", [digest])
      cond do
        token.consumed_at != nil ->
          sql("UPDATE auth_sessions SET revoked_at=$2 WHERE id=$1", [uuid(session.session_id),now])
          {:reused,session.session_id}
        session.revoked_at != nil or session.expires_at <= now or token.expires_at <= now -> Repo.rollback(:invalid_session)
        true ->
          sql("UPDATE auth_tokens SET consumed_at=$2 WHERE digest=$1", [digest,now])
          Enum.each(tokens, &insert_token(session.session_id, Map.update!(&1,:expires_at,fn expiry -> min(expiry,session.expires_at) end),now))
          session
      end
    end)
  end

  @doc "撤销一个或全部会话，返回需关闭的连接所属会话 ID。"
  def revoke(account_id, session_id, now) do
    transaction(fn ->
      rows("UPDATE auth_sessions SET revoked_at=COALESCE(revoked_at,$3) WHERE account_id=$1 AND ($2::uuid IS NULL OR id=$2) RETURNING id::text AS id", [account_id, if(session_id,do: uuid(session_id)),now]) |> Enum.map(& &1.id)
    end)
  end

  @doc "受控命令授予账号管理权限，HTTP 调用方必须先经 Auth 管理权限验证。"
  def grant_admin(email, enabled, actor, now) do
    transaction(fn ->
      a = account(email) || Repo.rollback(:not_found)
      sql("UPDATE accounts SET auth_admin=$2 WHERE id=$1", [a.id,enabled])
      audit(actor,"admin_permission",Integer.to_string(a.id),%{enabled: enabled},now)
      :ok
    end) |> done()
  end

  @doc "访问令牌仍有效时签发绑定部署和目标 Scene 的票据。"
  def issue_ticket(access,digest,scene,hello,now) do
    transaction(fn ->
      c=authenticate(access,"access",now) || Repo.rollback(:invalid_session)
      lock_account!(c.account_id)
      live_session!(c.session_id,now)
      sql("INSERT INTO auth_tokens(digest,session_id,purpose,expires_at,scene_id,hello) VALUES($1,$2,'ticket',$3,$4,$5)",[digest,uuid(c.session_id),min(now+60,c.expires_at),scene,hello])
      c
    end)
  end

  @doc "原子消费票据，角色归属来自数据库，不信任 Join 自报身份。"
  def consume_ticket(digest,cid,username,scene,hello,now) do
    transaction(fn ->
      c=authenticate(digest,"ticket",now) || Repo.rollback(:invalid_ticket)
      lock_account!(c.account_id)
      live_session!(c.session_id,now)
      t=one("SELECT scene_id,hello,consumed_at FROM auth_tokens WHERE digest=$1 FOR UPDATE",[digest])
      character=Repo.get_by(Character,[id: cid,account: c.account_id],log: false)
      if t.scene_id != scene or t.hello != hello or t.consumed_at != nil or c.username != username or is_nil(character), do: Repo.rollback(:invalid_ticket)
      sql("UPDATE auth_tokens SET consumed_at=$2 WHERE digest=$1",[digest,now])
      Map.put(c,:character,character)
    end)
  end

  @doc "验证重置证明并原子改密、撤销全部账号会话。"
  def reset_password(email,proof,hash,now) do
    transaction(fn ->
      challenge!(email,"password_reset",proof,now)
      a=account(email) || Repo.rollback(:invalid_verification)
      update_password!(a.id,nil,hash,now)
      sql("DELETE FROM auth_challenges WHERE email=$1 AND purpose='password_reset'",[email])
      revoke_all!(a.id,now)
    end)
  end

  @doc "改密使用已经校验过的旧哈希，持锁后复核，防止旧密码竞争复活会话。"
  def change_password(id,expected,hash,now) do
    transaction(fn ->
      update_password!(id,expected,hash,now)
      revoke_all!(id,now)
    end)
  end
  @doc "停用账号并撤销全部会话；不修改角色数据。"
  def disable_account(id,actor,now) do
    transaction(fn ->
      sql("UPDATE accounts SET disabled_at=$2 WHERE id=$1",[id,now])
      audit(actor,"account_disabled",Integer.to_string(id),%{},now)
      revoke_all!(id,now)
    end)
  end

  defp update_password!(id,expected,hash,now) do
    row=one("SELECT password_hash FROM accounts WHERE id=$1 FOR UPDATE",[id])
    if is_nil(row) or (expected && row.password_hash != expected), do: Repo.rollback(:invalid_credentials)
    sql("UPDATE accounts SET password_hash=$2,updated_at=to_timestamp($3) AT TIME ZONE 'UTC' WHERE id=$1",[id,hash,now])
  end
  defp revoke_all!(id,now),do: rows("UPDATE auth_sessions SET revoked_at=COALESCE(revoked_at,$2) WHERE account_id=$1 RETURNING id::text AS id",[id,now]) |> Enum.map(& &1.id)
  defp live_session!(id,now) do
    row=one("SELECT expires_at,revoked_at FROM auth_sessions WHERE id=$1 FOR UPDATE",[uuid(id)])
    if is_nil(row) or row.revoked_at != nil or row.expires_at<=now,do: Repo.rollback(:invalid_session)
  end

  defp valid_invite(digest, now, lock) do
    one("SELECT id FROM auth_invites WHERE digest=$1 AND used_by IS NULL AND revoked_at IS NULL AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at>$2)" <> if(lock,do: " FOR UPDATE",else: ""), [digest,now])
  end
  defp challenge!(email,purpose,digest,now) do
    row = one("SELECT digest,expires_at,attempts FROM auth_challenges WHERE email=$1 AND purpose=$2 FOR UPDATE", [email,purpose])
    if is_nil(row) or row.expires_at <= now or row.attempts > 5 or not :crypto.hash_equals(row.digest,digest), do: Repo.rollback(:invalid_verification)
  end
  defp lock_account!(id) do
    case one("SELECT disabled_at,password_hash FROM accounts WHERE id=$1 FOR SHARE", [id]) do
      %{disabled_at: nil}=row -> row
      _ -> Repo.rollback(:invalid_session)
    end
  end
  defp insert_token(session_id,t,_now) do
    sql("INSERT INTO auth_tokens(digest,session_id,purpose,expires_at) VALUES($1,$2,$3,$4)", [t.digest,uuid(session_id),t.purpose,t.expires_at])
  end
  defp audit(actor, action, object, details, now), do: sql("INSERT INTO auth_audit(actor,action,object_id,details,at) VALUES($1,$2,$3,$4,$5)", [actor,action,object,details,now])
  defp transaction(fun), do: Repo.transaction(fun,log: false)
  defp done({:ok,:ok}), do: :ok
  defp done(error), do: error
  defp uuid(value), do: Ecto.UUID.dump!(value)
  defp sql(query,params), do: Ecto.Adapters.SQL.query!(Repo,query,params,log: false)
  defp rows(query,params) do
    %{columns: columns, rows: values} = sql(query,params)
    keys = Enum.map(columns,&String.to_atom/1)
    Enum.map(values, &Map.new(Enum.zip(keys,&1)))
  end
  defp one(query,params), do: List.first(rows(query,params))
  defp constraint?(%Ecto.ConstraintError{}), do: true
  defp constraint?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp constraint?(_), do: false
end
