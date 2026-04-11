defmodule Demo.Runner do
  @moduledoc """
  Orchestrates the local bidirectional demo.
  """

  use GenServer

  require Logger

  @await_timeout_ms 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run(opts) do
    {:ok, pid} = start_link(opts)
    GenServer.call(pid, :run, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    result =
      try do
        execute_demo(state.opts)
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      end

    {:stop, :normal, result, state}
  end

  defp execute_demo(opts) do
    scenario =
      opts
      |> build_scenario()
      |> bootstrap_runtime()
      |> Demo.Seeds.apply_seeded_identities!()

    files = Demo.ConfigWriter.write!(scenario, output_dir(opts))

    Mix.shell().info("Demo human config written to:")
    Mix.shell().info("  PowerShell: #{files.powershell}")
    Mix.shell().info("  POSIX shell: #{files.shell}")
    Mix.shell().info("  JSON: #{files.json}")
    Mix.shell().info("  Manifest: #{files.manifest}")

    Enum.each(files.clients, fn client ->
      Mix.shell().info(
        "  human slot #{client.slot}: #{client.username} cid=#{client.cid} -> #{client.powershell}"
      )
    end)

    Mix.shell().info("")

    Mix.shell().info(
      "Launch each Bevy client in a separate shell after importing a different human-client-*.ps1/.env.sh file."
    )

    if Keyword.get(opts, :dry_run, false) do
      {:ok, %{scenario: scenario, files: files, mode: :dry_run}}
    else
      start_bots!(scenario)

      Mix.shell().info(
        "Started #{length(scenario.bots)} demo bots against #{scenario.gate_addr}."
      )

      case smoke_seconds(opts) do
        seconds when is_integer(seconds) and seconds > 0 ->
          await_smoke!(seconds)
          {:ok, %{scenario: scenario, files: files, mode: :smoke}}

        _ ->
          Mix.shell().info("Demo is running. Press Ctrl+C twice to stop.")
          Process.sleep(:infinity)
      end
    end
  end

  defp build_scenario(opts) do
    Demo.Scenario.build(
      bot_count: Keyword.get(opts, :bot_count, 3),
      human_count: Keyword.get(opts, :human_count, 2),
      gate_addr: Keyword.get(opts, :gate_addr),
      auth_url: Keyword.get(opts, :auth_url),
      human_username: Keyword.get(opts, :human_username),
      human_cid: Keyword.get(opts, :human_cid)
    )
  end

  defp bootstrap_runtime(scenario) do
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.put_env(:tzdata, :autoupdate, :disabled)
    Application.put_env(:libcluster, :topologies, [])
    Demo.Seeds.ensure_storage_and_migrations!()
    ensure_auth_endpoint_config!()
    Mix.Task.run("app.start")
    await_service!(:gate_server)
    await_service!(:scene_server)
    await_service!(:auth_server)
    scenario
  end

  defp await_service!(resource) do
    start = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      case BeaconServer.Client.lookup(resource) do
        {:ok, node} -> {:ok, node}
        :error -> :pending
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:ok, node}, _acc ->
        {:halt, node}

      :pending, _acc ->
        if System.monotonic_time(:millisecond) - start > @await_timeout_ms do
          raise "demo runtime timed out waiting for #{inspect(resource)}"
        else
          Process.sleep(250)
          {:cont, nil}
        end
    end)
  end

  defp start_bots!(scenario) do
    Enum.map(scenario.bots, fn bot ->
      {:ok, _pid} = Demo.Bot.start_link(actor: bot, gate_addr: scenario.gate_addr, notify: self())
    end)
  end

  defp await_smoke!(seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1_000

    smoke_loop(
      %{
        fast_lane_attached?: false,
        udp_movement_ack?: false,
        chat_seen?: false,
        skill_seen?: false,
        aoi_seen?: false
      },
      deadline
    )
  end

  defp smoke_loop(checks, deadline) do
    if checks.fast_lane_attached? and checks.udp_movement_ack? and checks.chat_seen? and
         checks.skill_seen? and checks.aoi_seen? do
      Mix.shell().info("Demo smoke passed: fast lane + AOI/chat/skill traffic observed.")
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise "demo smoke timed out with incomplete observations: #{inspect(checks)}"
      else
        receive do
          {:demo_bot_event, _username, :fast_lane_attached} ->
            smoke_loop(%{checks | fast_lane_attached?: true}, deadline)

          {:demo_bot_event, _username, {:movement_ack, :udp}} ->
            smoke_loop(%{checks | udp_movement_ack?: true}, deadline)

          {:demo_bot_event, _username, {:chat_message, _cid, _from, _text}} ->
            smoke_loop(%{checks | chat_seen?: true}, deadline)

          {:demo_bot_event, _username, {:skill_event, _cid, _skill_id, _location}} ->
            smoke_loop(%{checks | skill_seen?: true}, deadline)

          {:demo_bot_event, _username, {:player_enter, _cid, _location}} ->
            smoke_loop(%{checks | aoi_seen?: true}, deadline)

          {:demo_bot_event, _username, {:player_move, _cid, _location, _transport}} ->
            smoke_loop(%{checks | aoi_seen?: true}, deadline)

          _other ->
            smoke_loop(checks, deadline)
        after
          500 ->
            smoke_loop(checks, deadline)
        end
      end
    end
  end

  defp output_dir(opts) do
    Keyword.get(opts, :output_dir, ".demo")
  end

  defp ensure_auth_endpoint_config! do
    endpoint_config =
      Application.get_env(:auth_server, AuthServerWeb.Endpoint, [])
      |> Keyword.put_new(
        :secret_key_base,
        "demo-secret-key-base-change-me-000000000000000000000000000000000000000000"
      )

    Application.put_env(:auth_server, AuthServerWeb.Endpoint, endpoint_config)
  end

  defp smoke_seconds(opts) do
    exit_after = Keyword.get(opts, :exit_after)

    cond do
      is_integer(exit_after) and exit_after > 0 ->
        exit_after

      Keyword.get(opts, :smoke, false) ->
        12

      true ->
        0
    end
  end
end
