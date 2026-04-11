defmodule Demo.Seeds do
  @moduledoc """
  Database seeding helpers for the local demo flow.
  """

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

  @dummy_password "demo-password"
  @dummy_salt "demo-salt"

  def ensure_demo_targets!(scenario) do
    scenario
    |> Demo.Scenario.as_seed_targets()
    |> Enum.map(&ensure_identity!/1)
  end

  def apply_seeded_identities!(scenario) do
    identities = ensure_demo_targets!(scenario)

    human =
      identities
      |> Enum.find(fn identity -> identity.username == scenario.human.username end)
      |> identity_to_actor()

    bots =
      scenario.bots
      |> Enum.map(fn bot ->
        identities
        |> Enum.find(fn identity -> identity.username == bot.username end)
        |> identity_to_actor(bot)
      end)

    %{scenario | human: human, bots: bots}
  end

  def ensure_storage_and_migrations! do
    repo_config = Repo.config()

    case Ecto.Adapters.Postgres.storage_up(repo_config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    migrations_path = Path.expand("../../../../data_service/priv/repo/migrations", __DIR__)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    :ok
  end

  defp ensure_identity!(%{
         account_id: desired_account_id,
         username: username,
         character: character
       }) do
    account =
      Repo.get(Account, desired_account_id) ||
        Repo.get_by(Account, username: username) ||
        %Account{id: desired_account_id}

    {:ok, persisted_account} =
      account
      |> Account.changeset(%{
        id: Map.get(account, :id, desired_account_id),
        username: username,
        password: @dummy_password,
        salt: @dummy_salt,
        email: "#{username}@demo.local"
      })
      |> Repo.insert_or_update()

    persisted_character =
      Repo.get(Character, character.cid) ||
        Repo.get_by(Character, name: character.name) ||
        %Character{id: character.cid}

    {:ok, persisted_character} =
      persisted_character
      |> Character.changeset(%{
        id: Map.get(persisted_character, :id, character.cid),
        account: persisted_account.id,
        name: character.name,
        title: "demo",
        base_attrs: %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20},
        battle_attrs: %{"hp" => 100, "mp" => 50},
        position: tuple_position_map(character.position),
        hp: 100,
        sp: 50,
        mp: 50
      })
      |> Repo.insert_or_update()

    %{
      account_id: persisted_account.id,
      username: username,
      cid: persisted_character.id,
      character_name: persisted_character.name,
      position: map_to_tuple_position(persisted_character.position)
    }
  end

  defp identity_to_actor(nil), do: raise("missing seeded demo identity")

  defp identity_to_actor(identity) do
    Map.merge(identity, %{token: Demo.Scenario.issue_token(identity)})
  end

  defp identity_to_actor(identity, bot) do
    identity
    |> identity_to_actor()
    |> Map.merge(%{
      slot: bot.slot,
      movement_points: bot.movement_points,
      chat_lines: bot.chat_lines,
      skill_id: bot.skill_id,
      heartbeat_interval_ms: bot.heartbeat_interval_ms,
      time_sync_interval_ms: bot.time_sync_interval_ms,
      movement_interval_ms: bot.movement_interval_ms,
      chat_interval_ms: bot.chat_interval_ms,
      skill_interval_ms: bot.skill_interval_ms
    })
  end

  defp tuple_position_map({x, y, z}), do: %{"x" => x, "y" => y, "z" => z}

  defp map_to_tuple_position(%{} = position) do
    {
      read_position_component(position, ["x", :x], 1_000.0),
      read_position_component(position, ["y", :y], 1_000.0),
      read_position_component(position, ["z", :z], 90.0)
    }
  end

  defp map_to_tuple_position(_position), do: {1_000.0, 1_000.0, 90.0}

  defp read_position_component(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
