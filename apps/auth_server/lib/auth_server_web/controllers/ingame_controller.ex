defmodule AuthServerWeb.IngameController do
  @moduledoc """
  HTTP façade for the in-game login flow.

  The controller keeps request handling thin: it renders the login page,
  converts POST parameters into signed claims, and redirects the browser to a
  success page that can hand the token to the game client.

  ## Route map

  - `GET /ingame/login` -> `login/2`
  - `POST /ingame/login_post` -> `login_post/2`
  - `GET /ingame/login_success` -> `login_success/2`
  """

  use AuthServerWeb, :controller
  require Logger

  @doc "Render the in-game login form."
  def login(conn, _params) do
    render(conn, :login)
  end

  @doc """
  Turn the submitted login form into a signed token and redirect to success.
  """
  def login_post(conn, params) do
    Logger.debug("login_post: #{inspect(params, pretty: true)}")

    username = params["username"] || "dev_user"
    account = resolve_account(username)

    code =
      username
      |> AuthServer.AuthWorker.build_session_claims(session_claim_options(params, account))
      |> AuthServer.AuthWorker.issue_token()

    redirect(conn, to: ~p"/ingame/login_success?#{[code: code]}")
  end

  @doc "Render the success page shown after a token is issued."
  def login_success(conn, _params) do
    render(conn, :login_success)
  end

  @doc """
  Demo JSON auto-login. Upserts account+character then returns a signed token.

  Gated by `config :auth_server, :dev_auto_login`. Responds 403 when disabled.
  """
  def auto_login(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_auto_login(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Demo JSON hook that prepares the default server-authoritative voxel lease.

  This is intentionally tied to `:dev_auto_login` because it exists for browser
  smoke runs and the shared online demo.
  """
  def voxel_dev_seed(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_dev_seed(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only skill hook: writes a target temperature into an exact world-macro voxel.
  The scene server derives the heat budget from voxel density/specific heat, treats
  the abnormal temperature as a local field source, and runs the normal
  FieldRegion kernel path.

  Accepts optional JSON params:
    * `logical_scene_id` (default 1)
    * `x`, `y`, `z`      world macro coord integers
    * `target_temperature_celsius` (default 800)
    * `max_ticks`        (default 600)
    * `radius`           (default 4)
  """
  def voxel_dev_heat_voxel(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_dev_heat_voxel(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only formal SetTemperature/Cool hook.

  Cooling is represented by `target_temperature_celsius` below ambient, never
  by negative `heat_energy_joules`. `restore_ambient=true` targets 20C.
  """
  def voxel_set_temperature(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_set_temperature(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only electric conduction hook.

  Creates a chunk-local `ConductionPathKernel` field from `source_*` to
  `target_*`. The scene server owns the field region; this controller only
  normalizes JSON parameters and returns a JSON-safe summary for browser CLI
  diagnostics.
  """
  def voxel_conduct(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_conduct(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only automatic circuit hook.

  Creates or refreshes a target-free circuit field on the selected chunk. The
  scene kernel decides whether current exists from source/load topology.
  """
  def voxel_auto_circuit(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_auto_circuit(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only readback hook for one voxel's authoritative combustion truth.

  The scene chunk remains the source of material, stage, fuel, oxygen, smoke,
  carbonization, and structural integrity. The controller only parses JSON
  coordinates and serializes the returned summary.
  """
  def voxel_combustion_probe(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_combustion_probe(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only readback hook for one voxel's authoritative contained-water phase
  truth.

  The scene chunk remains the source of material, phase_state, temperature,
  moisture, structural integrity, and chunk-local phase-change instance. The
  controller only parses JSON coordinates and serializes the returned summary.
  """
  def voxel_phase_change_probe(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_phase_change_probe(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Dev-only readback hook for one object's authoritative physical part state.

  The scene `ObjectRegistry` remains the source of object and part-health truth.
  The controller only parses the object id plus a route coordinate and
  serializes the returned summary.
  """
  def voxel_object_probe(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_object_probe(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  defp do_auto_login(conn, params) do
    username = params["username"] |> normalize_username()

    cond do
      username == nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_username"})

      true ->
        case AuthServer.Accounts.upsert_dev(username) do
          {:ok, %{account: account, character: character}} ->
            token =
              username
              |> AuthServer.AuthWorker.build_session_claims(
                source: "ingame_auto_login",
                account_id: account.id,
                cid: character.id
              )
              |> AuthServer.AuthWorker.issue_token()

            json(conn, %{token: token, cid: character.id, username: username})

          {:error, reason} ->
            Logger.warning("auto_login failed for #{username}: #{inspect(reason)}")

            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "auto_login_failed"})
        end
    end
  end

  defp do_voxel_dev_seed(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_default_region, [[logical_scene_id: logical_scene_id]]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel dev seed failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_dev_seed_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_dev_heat_voxel(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    world_macro = parse_world_macro(params)

    thermal_opts =
      if Map.has_key?(params, "heat_energy_joules") do
        [heat_energy_joules: parse_non_negative_number(params["heat_energy_joules"], 0.0)]
      else
        [
          target_temperature_celsius:
            parse_number(
              params["target_temperature_celsius"] || params["target_temperature"],
              800.0
            )
        ]
      end

    max_ticks = parse_non_negative_int(params["max_ticks"], 600)
    radius = parse_non_negative_int(params["radius"], 4)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_heat_voxel, [
             [
               logical_scene_id: logical_scene_id,
               world_macro: world_macro,
               max_ticks: max_ticks,
               radius: radius
             ] ++ thermal_opts
           ]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel dev heat voxel failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "dev_heat_voxel_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_set_temperature(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    world_macro = parse_world_macro(params)
    max_ticks = parse_non_negative_int(params["max_ticks"], 600)
    radius = parse_non_negative_int(params["radius"], 4)

    target_temperature =
      if parse_bool(params["restore_ambient"], false) do
        20.0
      else
        parse_number(params["target_temperature_celsius"] || params["target_temperature"], 800.0)
      end

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_set_temperature, [
             [
               logical_scene_id: logical_scene_id,
               world_macro: world_macro,
               target_temperature_celsius: target_temperature,
               restore_ambient: parse_bool(params["restore_ambient"], false),
               max_ticks: max_ticks,
               radius: radius
             ]
           ]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel set temperature failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "set_temperature_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_conduct(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    source_world_macro = parse_prefixed_world_macro(params, "source")
    target_world_macro = parse_prefixed_world_macro(params, "target")

    source_potential =
      parse_non_negative_number(params["source_potential"] || params["potential"], 120.0)

    max_ticks = parse_non_negative_int(params["max_ticks"], 120)
    ttl_ticks = parse_optional_non_negative_int(params["ttl_ticks"] || params["source_ttl_ticks"])
    radius = parse_non_negative_int(params["radius"], 1)
    max_frontier = parse_non_negative_int(params["max_frontier"], 512)
    owner_ref = parse_source_owner_ref(params)
    conduction_mode = params["conduction_mode"] || params["mode"] || params["electric_mode"]

    output_mode =
      params["output_mode"] || params["power_output_mode"] || params["source_output_mode"]

    voltage =
      parse_optional_non_negative_number(
        params["voltage"] || params["source_voltage"] || params["power_voltage"]
      )

    current_limit_amps =
      parse_optional_non_negative_number(
        params["current_limit_amps"] || params["current_limit"] ||
          params["power_current_limit_amps"]
      )

    load_current_amps =
      parse_optional_non_negative_number(
        params["load_current_amps"] || params["requested_current_amps"] ||
          params["current_amps"] || params["power_load_current_amps"]
      )

    frequency_hz =
      parse_optional_non_negative_number(params["frequency_hz"] || params["power_frequency_hz"])

    energy_budget_joules =
      parse_optional_non_negative_number(
        params["energy_budget_joules"] || params["source_energy_budget_joules"]
      )

    conduct_opts =
      [
        logical_scene_id: logical_scene_id,
        source_world_macro: source_world_macro,
        target_world_macro: target_world_macro,
        source_potential: source_potential,
        max_ticks: max_ticks,
        radius: radius,
        max_frontier: max_frontier
      ]
      |> maybe_put(:ttl_ticks, ttl_ticks)
      |> maybe_put(:conduction_mode, conduction_mode)
      |> maybe_put(:source_mode, params["source_mode"])
      |> maybe_put(:owner_ref, owner_ref)
      |> maybe_put(:output_mode, output_mode)
      |> maybe_put(:voltage, voltage)
      |> maybe_put(:current_limit_amps, current_limit_amps)
      |> maybe_put(:load_current_amps, load_current_amps)
      |> maybe_put(:frequency_hz, frequency_hz)
      |> maybe_put(:energy_budget_joules, energy_budget_joules)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <- apply(module, :ensure_conduction_path, [conduct_opts]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel conduction path failed: #{inspect(reason)}")

        conn
        |> put_status(voxel_conduct_error_status(reason))
        |> json(%{
          error: "voxel_conduct_failed",
          reason: inspect(reason),
          reason_code: voxel_conduct_reason_code(reason)
        })

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_auto_circuit(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    world_macro = parse_world_macro(params)
    max_ticks = parse_non_negative_int(params["max_ticks"], 600)

    voltage =
      parse_optional_non_negative_number(
        params["voltage"] || params["source_voltage"] || params["source_potential"]
      )

    current_limit_amps =
      parse_optional_non_negative_number(
        params["current_limit_amps"] || params["current_limit"] ||
          params["power_current_limit_amps"]
      )

    auto_opts =
      [
        logical_scene_id: logical_scene_id,
        world_macro: world_macro,
        max_ticks: max_ticks
      ]
      |> maybe_put(:voltage, voltage)
      |> maybe_put(:current_limit_amps, current_limit_amps)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <- apply(module, :ensure_auto_circuit, [auto_opts]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel auto circuit failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_auto_circuit_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_combustion_probe(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    world_macro = parse_world_macro(params)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_combustion_probe, [
             [
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             ]
           ]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel combustion probe failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_combustion_probe_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_phase_change_probe(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    world_macro = parse_world_macro(params)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_phase_change_probe, [
             [
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             ]
           ]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel phase change probe failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_phase_change_probe_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp do_voxel_object_probe(conn, params) do
    module = Module.concat([WorldServer, Voxel, DevFieldSeed])
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    object_id = parse_non_negative_int(params["object_id"], 0)
    world_macro = parse_world_macro(params)

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_object_probe, [
             [
               logical_scene_id: logical_scene_id,
               object_id: object_id,
               world_macro: world_macro
             ]
           ]) do
      voxel_json(conn, summary)
    else
      {:error, reason} ->
        Logger.warning("voxel object probe failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_object_probe_failed", reason: inspect(reason)})

      _other ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "world_server_unavailable"})
    end
  end

  defp parse_world_macro(params) do
    {
      parse_int(params["x"], 0),
      parse_int(params["y"], 0),
      parse_int(params["z"], 0)
    }
  end

  defp parse_prefixed_world_macro(params, prefix) do
    {
      parse_int(params["#{prefix}_x"], 0),
      parse_int(params["#{prefix}_y"], 0),
      parse_int(params["#{prefix}_z"], 0)
    }
  end

  defp voxel_conduct_error_status(
         {:conduction_path_failed, :cross_chunk_conduction_not_supported}
       ),
       do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :source_not_conductive}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :source_not_powered}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :current_limit_exceeded}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :energy_budget_exhausted}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :target_not_conductive}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :no_conductive_path}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:conduction_path_failed, :no_discharge_path}),
    do: :unprocessable_entity

  defp voxel_conduct_error_status({:source_chunk_route_unavailable, _reason}),
    do: :conflict

  defp voxel_conduct_error_status(_reason), do: :service_unavailable

  defp voxel_conduct_reason_code(
         {:conduction_path_failed, :cross_chunk_conduction_not_supported}
       ),
       do: "cross_chunk_conduction_not_supported"

  defp voxel_conduct_reason_code({:conduction_path_failed, :source_not_conductive}),
    do: "source_not_conductive"

  defp voxel_conduct_reason_code({:conduction_path_failed, :source_not_powered}),
    do: "source_not_powered"

  defp voxel_conduct_reason_code({:conduction_path_failed, :current_limit_exceeded}),
    do: "current_limit_exceeded"

  defp voxel_conduct_reason_code({:conduction_path_failed, :energy_budget_exhausted}),
    do: "energy_budget_exhausted"

  defp voxel_conduct_reason_code({:conduction_path_failed, :target_not_conductive}),
    do: "target_not_conductive"

  defp voxel_conduct_reason_code({:conduction_path_failed, :no_conductive_path}),
    do: "no_conductive_path"

  defp voxel_conduct_reason_code({:conduction_path_failed, :no_discharge_path}),
    do: "no_discharge_path"

  defp voxel_conduct_reason_code({:source_chunk_route_unavailable, _reason}),
    do: "source_chunk_route_unavailable"

  defp voxel_conduct_reason_code(_reason), do: "backend_unavailable"

  defp parse_int(value, _fallback) when is_integer(value), do: value

  defp parse_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> fallback
    end
  end

  defp parse_int(_value, fallback), do: fallback

  defp parse_non_negative_number(value, fallback) do
    value
    |> parse_number(fallback)
    |> case do
      parsed when is_number(parsed) and parsed >= 0 -> parsed
      _other -> fallback
    end
  end

  defp parse_optional_non_negative_number(nil), do: nil

  defp parse_optional_non_negative_number(value) do
    value
    |> parse_number(nil)
    |> case do
      parsed when is_number(parsed) and parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp normalize_username(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 32 -> nil
      true -> trimmed
    end
  end

  defp normalize_username(_), do: nil

  defp parse_non_negative_int(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> fallback
    end
  end

  defp parse_non_negative_int(_value, fallback), do: fallback

  defp parse_optional_non_negative_int(nil), do: nil
  defp parse_optional_non_negative_int(value), do: parse_non_negative_int(value, nil)

  defp parse_source_owner_ref(params) do
    owner_kind = params["source_owner_kind"] || params["owner_kind"]
    owner_id = params["source_owner_id"] || params["owner_id"]

    if is_binary(owner_kind) and String.trim(owner_kind) != "" and
         is_binary(owner_id) and String.trim(owner_id) != "" do
      %{kind: String.trim(owner_kind), id: String.trim(owner_id)}
    end
  end

  defp parse_number(value, _fallback) when is_integer(value), do: value * 1.0
  defp parse_number(value, _fallback) when is_float(value), do: value

  defp parse_number(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> fallback
    end
  end

  defp parse_number(_value, fallback), do: fallback

  defp parse_bool(value, _fallback) when is_boolean(value), do: value
  defp parse_bool(value, _fallback) when is_integer(value), do: value != 0

  defp parse_bool(value, fallback) when is_binary(value) do
    case String.downcase(value) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      _other -> fallback
    end
  end

  defp parse_bool(_value, fallback), do: fallback

  defp voxel_json(conn, summary), do: json(conn, json_safe(summary))

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&json_safe/1)
  end

  defp json_safe(atom) when is_atom(atom) and atom in [nil, true, false], do: atom
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp json_safe(value) when is_pid(value) or is_reference(value) or is_port(value),
    do: inspect(value)

  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key)

  defp session_claim_options(params, account) do
    []
    |> Keyword.put(:source, "ingame_login")
    |> maybe_put(:account_id, account_id(account))
    |> maybe_put(:cid, params["cid"])
    |> maybe_put(:allowed_cids, parse_allowed_cids(params["allowed_cids"]))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_allowed_cids(nil), do: nil

  defp parse_allowed_cids(values) when is_list(values), do: values

  defp parse_allowed_cids(values) when is_binary(values) do
    values
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp resolve_account(username) do
    case AuthServer.Accounts.find_by_username(username) do
      {:ok, account} -> account
      {:error, _reason} -> nil
    end
  end

  defp account_id(%{id: account_id}), do: account_id
  defp account_id(_), do: nil
end
