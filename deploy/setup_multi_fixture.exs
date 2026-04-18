alias DataService.{Repo, Schema.Account, Schema.Character}

Application.load(:data_service)
{:ok, _} = Application.ensure_all_started(:plug_crypto)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Repo, fn _repo ->
    secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

    upsert_account = fn username ->
      case Repo.get_by(Account, username: username) do
        nil ->
          uid = :rand.uniform(1_000_000_000_000)
          salt = Bcrypt.Base.gen_salt()
          hash = Bcrypt.Base.hash_password("testpw", salt)

          Repo.insert!(%Account{
            id: uid,
            username: username,
            password: hash,
            salt: salt,
            email: "#{username}@example.com",
            phone: "138#{:rand.uniform(99_999_999) |> Integer.to_string() |> String.pad_leading(8, "0")}"
          })

        existing ->
          existing
      end
    end

    upsert_character = fn account_id, cid, name, x ->
      case Repo.get(Character, cid) do
        nil ->
          %Character{}
          |> Character.changeset(%{
            id: cid,
            account: account_id,
            name: name,
            title: "tester",
            base_attrs: %{},
            battle_attrs: %{},
            position: %{"x" => x, "y" => 1000.0, "z" => 100.0},
            hp: 500,
            sp: 100,
            mp: 100
          })
          |> Repo.insert!()

        existing ->
          existing
      end
    end

    mint_token = fn username, account_id, cid ->
      claims = %{
        "username" => username,
        "source" => "local_docker_test",
        "session_id" => Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
        "account_id" => account_id,
        "cid" => cid
      }

      Phoenix.Token.sign(secret_key_base, "ingame-auth", claims)
    end

    acc1 = upsert_account.("alice")
    acc2 = upsert_account.("bob")

    upsert_character.(acc1.id, 42, "alice_char", 1000.0)
    upsert_character.(acc2.id, 43, "bob_char", 1050.0)

    token1 = mint_token.("alice", acc1.id, 42)
    token2 = mint_token.("bob", acc2.id, 43)

    IO.puts("=== FIXTURE READY ===")
    IO.puts("USER1=alice CID1=42 TOKEN1=#{token1}")
    IO.puts("USER2=bob CID2=43 TOKEN2=#{token2}")
    IO.puts("=== END ===")

    {:ok, :done}
  end)
