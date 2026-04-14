defmodule Demo.Scenario do
  @moduledoc """
  Stable demo identity and choreography definitions.
  """

  @default_gate_addr "127.0.0.1:29000"
  @default_auth_url "http://127.0.0.1:4000/ingame/login"
  @default_skill_id 1

  @human_defaults [
    %{
      slot: 1,
      account_id: 91_001,
      username: "demo_human",
      cid: 42_001,
      character_name: "Demo Human",
      position: {1_000.0, 1_000.0, 90.0}
    },
    %{
      slot: 2,
      account_id: 91_002,
      username: "demo_human_2",
      cid: 42_002,
      character_name: "Demo Human Two",
      position: {1_008.0, 1_000.0, 90.0}
    },
    %{
      slot: 3,
      account_id: 91_003,
      username: "demo_human_3",
      cid: 42_003,
      character_name: "Demo Human Three",
      position: {992.0, 1_000.0, 90.0}
    }
  ]

  @bot_defaults [
    %{
      slot: 1,
      account_id: 91_101,
      username: "demo_bot_alpha",
      cid: 42_101,
      character_name: "Demo Bot Alpha",
      position: {1_012.0, 1_004.0, 90.0},
      chat_lines: ["alpha online", "alpha sees server AOI"],
      movement_points: [
        {1_015.0, 1_004.0, 90.0},
        {1_015.0, 1_009.0, 90.0},
        {1_010.0, 1_009.0, 90.0},
        {1_010.0, 1_004.0, 90.0}
      ]
    },
    %{
      slot: 2,
      account_id: 91_102,
      username: "demo_bot_bravo",
      cid: 42_102,
      character_name: "Demo Bot Bravo",
      position: {996.0, 1_006.0, 90.0},
      chat_lines: ["bravo attached", "bravo casts via real gate"],
      movement_points: [
        {998.0, 1_008.0, 90.0},
        {1_003.0, 1_008.0, 90.0},
        {1_003.0, 1_003.0, 90.0},
        {998.0, 1_003.0, 90.0}
      ]
    },
    %{
      slot: 3,
      account_id: 91_103,
      username: "demo_bot_charlie",
      cid: 42_103,
      character_name: "Demo Bot Charlie",
      position: {1_004.0, 992.0, 90.0},
      chat_lines: ["charlie confirms tcp+udp split", "charlie pulses skill 1"],
      movement_points: [
        {1_006.0, 994.0, 90.0},
        {1_011.0, 994.0, 90.0},
        {1_011.0, 999.0, 90.0},
        {1_006.0, 999.0, 90.0}
      ]
    }
  ]

  @doc """
  Builds the stable demo scenario from defaults plus targeted overrides.
  """
  def build(opts \\ []) do
    human_count =
      opts
      |> Keyword.get(:human_count, 2)
      |> max(1)
      |> min(length(@human_defaults))

    bot_count =
      opts
      |> Keyword.get(:bot_count, length(@bot_defaults))
      |> max(0)
      |> min(length(@bot_defaults))

    humans =
      @human_defaults
      |> Enum.take(human_count)
      |> with_primary_human_overrides(opts)

    bots =
      @bot_defaults
      |> Enum.take(bot_count)
      |> Enum.map(fn bot ->
        Map.merge(bot, %{
          skill_id: @default_skill_id,
          heartbeat_interval_ms: 2_000,
          time_sync_interval_ms: 5_000,
          movement_interval_ms: 750,
          chat_interval_ms: 3_500,
          skill_interval_ms: 4_500
        })
      end)

    %{
      gate_addr: Keyword.get(opts, :gate_addr) || @default_gate_addr,
      auth_url: Keyword.get(opts, :auth_url) || @default_auth_url,
      human: hd(humans),
      humans: humans,
      bots: bots
    }
  end

  @doc """
  Issues a token for one demo actor using the real auth worker.
  """
  def issue_token(%{username: username, account_id: account_id, cid: cid}) do
    username
    |> AuthServer.AuthWorker.build_session_claims(
      source: "demo.run",
      account_id: account_id,
      cid: cid,
      allowed_cids: [cid]
    )
    |> AuthServer.AuthWorker.issue_token()
  end

  @doc """
  Projects the scenario into the seed targets expected by `Demo.Seeds`.
  """
  def as_seed_targets(%{humans: humans, bots: bots}) do
    humans ++ bots
    |> Enum.map(fn spec ->
      %{
        account_id: spec.account_id,
        username: spec.username,
        character: %{
          cid: spec.cid,
          name: spec.character_name,
          position: spec.position
        }
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp with_primary_human_overrides([primary | rest], opts) do
    updated_primary =
      primary
      |> maybe_put(:username, Keyword.get(opts, :human_username))
      |> maybe_put(:cid, Keyword.get(opts, :human_cid))
      |> maybe_put(:character_name, Keyword.get(opts, :human_character_name))

    [updated_primary | rest]
  end
end
