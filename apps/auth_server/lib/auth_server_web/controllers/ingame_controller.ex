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
  - `GET /ingame/voxel/world_manifest` -> `voxel_world_manifest/2`
  - `GET /ingame/voxel/world_pack` -> `voxel_world_pack/2`
  - `GET /ingame/voxel/world_diff` -> `voxel_world_diff/2`
  """

  use AuthServerWeb, :controller
  require Logger

  alias MmoContracts.WorldPackIndex

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
  Read-only pre-scene terrain baseline manifest.

  This endpoint is the client-visible boundary between launcher/update data and
  scene runtime. It reports whether a trusted local world pack is expected to be
  present before entering the scene, plus diagnostic coverage for the current
  development materialization. It never generates terrain and never treats
  runtime snapshots as a baseline fallback.
  """
  def voxel_world_manifest(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_world_manifest(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  读取启动阶段使用的紧凑 world-pack 索引。

  这个端点只服务已校验的 `world_pack_index_v1` baseline 目录，不通过
  `world_diff` 枚举或合成缺失 chunk。
  """
  def voxel_world_pack(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_world_pack(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc """
  Read-only pre-scene voxel baseline diff page.

  This endpoint is for launcher/client startup synchronization. It pages over
  canonical persisted chunk snapshots for a configured world-pack
  `content_version`; it never invokes WorldGen and never repairs missing data.
  """
  def voxel_world_diff(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_world_diff(conn, params)
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
    seed_terrain? = parse_bool(params["seed_terrain"], true)
    rebuild_lod_projection? = parse_bool(params["rebuild_lod_projection"], false)
    baseline_materializer = parse_baseline_materializer(params["baseline_materializer"])

    baseline_radius =
      case parse_optional_non_negative_int(params["baseline_radius"]) do
        nil when baseline_materializer == :worldgen -> 3
        other -> other
      end

    baseline_opts =
      case baseline_radius do
        nil ->
          []

        radius ->
          center =
            {
              parse_int(params["baseline_center_x"], 0),
              parse_int(params["baseline_center_y"], 0),
              parse_int(params["baseline_center_z"], 0)
            }

          [baseline_footprint_chunks: active_window_chunk_coords(center, radius)]
      end

    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, summary} <-
           apply(module, :ensure_default_region, [
             [
               logical_scene_id: logical_scene_id,
               seed_terrain?: seed_terrain?,
               rebuild_lod_projection?: rebuild_lod_projection?,
               baseline_materializer: baseline_materializer
             ] ++ baseline_opts
           ]) do
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

  defp do_voxel_world_manifest(conn, params) do
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    stride = parse_non_negative_int(params["stride"], 16)
    pack_config = Application.get_env(:auth_server, :voxel_world_pack, [])
    world_macro_extent = Keyword.get(pack_config, :world_macro_extent, 32_768)
    pack_status = Keyword.get(pack_config, :status, :missing)
    pack_version = Keyword.get(pack_config, :version, "worldgen-v1")
    content_version = Keyword.get(pack_config, :content_version, pack_version)
    generated = Keyword.get(pack_config, :generated)
    pack_index = Keyword.get(pack_config, :pack_index)

    snapshot_summary =
      case DataService.Voxel.ChunkSnapshotStore.summary(logical_scene_id) do
        {:ok, summary} -> summary
        {:error, reason} -> %{status: :error, reason: inspect(reason)}
      end

    lod_summary =
      case DataService.Voxel.LodHeightmapStore.summary(logical_scene_id, stride: stride) do
        {:ok, summary} -> summary
        {:error, reason} -> %{status: :error, reason: inspect(reason)}
      end

    pack_ready? = pack_status_ready?(pack_status)

    pack_integrity =
      world_pack_integrity(
        generated,
        snapshot_summary,
        pack_index,
        logical_scene_id,
        content_version
      )

    pack_verified? = pack_ready? and pack_integrity.status == :ready
    dev_ready? = dev_materialization_ready?(snapshot_summary, lod_summary)
    baseline_format = world_pack_baseline_format(pack_integrity)

    manifest = %{
      schema_version: 1,
      logical_scene_id: logical_scene_id,
      phase_contract: %{
        launcher_stage: "world_pack_download_and_hash_validation",
        pre_scene_stage: "manifest_and_baseline_validation",
        scene_stage: "runtime_diff_streaming",
        runtime_snapshot_is_baseline_fallback: false
      },
      world: %{
        generator: "SceneServer.Voxel.WorldGen",
        generator_role: "one_time_materialization",
        macro_extent_xz: world_macro_extent,
        chunk_size_in_macro: 16,
        approximate_extent_km: world_macro_extent / 1000.0
      },
      world_pack: %{
        required: true,
        status: pack_status,
        version: pack_version,
        content_version: content_version,
        diff_endpoint: "/ingame/voxel/world_diff",
        diff_format: "chunk_snapshot_pages_v1",
        baseline_endpoint: startup_sync_endpoint(pack_integrity),
        baseline_format: baseline_format,
        generated: generated,
        integrity: pack_integrity,
        scene_entry_allowed: pack_verified?
      },
      startup_sync: %{
        required: true,
        local_cache_key: "logical_scene:#{logical_scene_id}:#{content_version}",
        client_must_persist_before_scene: true,
        endpoint: startup_sync_endpoint(pack_integrity),
        format: baseline_format,
        target_content_version: content_version,
        page_limit_default: 64,
        page_limit_max: 512
      },
      dev_materialization: %{
        status: if(dev_ready?, do: :ready, else: :incomplete),
        diagnostic_only: true,
        scene_entry_allowed: false,
        chunk_snapshots: snapshot_summary,
        lod_projection: lod_summary
      },
      scene_entry_allowed: pack_verified?,
      reject_reason: world_pack_reject_reason(pack_ready?, pack_integrity)
    }

    voxel_json(conn, manifest)
  end

  defp do_voxel_world_pack(conn, params) do
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    pack_config = Application.get_env(:auth_server, :voxel_world_pack, [])
    pack_status = Keyword.get(pack_config, :status, :missing)
    pack_version = Keyword.get(pack_config, :version, "worldgen-v1")
    content_version = Keyword.get(pack_config, :content_version, pack_version)
    generated = Keyword.get(pack_config, :generated)
    pack_index = Keyword.get(pack_config, :pack_index)
    pack_ready? = pack_status_ready?(pack_status)

    snapshot_summary =
      case DataService.Voxel.ChunkSnapshotStore.summary(logical_scene_id) do
        {:ok, summary} -> summary
        {:error, reason} -> %{status: :error, reason: inspect(reason)}
      end

    pack_integrity =
      world_pack_integrity(
        generated,
        snapshot_summary,
        pack_index,
        logical_scene_id,
        content_version
      )

    cond do
      not pack_ready? ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_not_ready",
          logical_scene_id: logical_scene_id,
          status: pack_status,
          required_stage: "launcher_worldgen_materialization"
        })

      is_nil(pack_index) ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_index_missing",
          logical_scene_id: logical_scene_id,
          status: pack_status,
          required_stage: "launcher_world_pack_index_download"
        })

      pack_integrity.status != :ready ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_incomplete",
          logical_scene_id: logical_scene_id,
          status: pack_status,
          integrity: pack_integrity,
          required_stage: "launcher_worldgen_materialization"
        })

      true ->
        case world_pack_index_for_response(
               pack_index,
               generated,
               logical_scene_id,
               content_version
             ) do
          {:ok, index} ->
            voxel_json(conn, world_pack_index_response(index, pack_integrity))

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "world_pack_index_invalid",
              logical_scene_id: logical_scene_id,
              reason: inspect(reason),
              required_stage: "launcher_world_pack_index_download"
            })
        end
    end
  end

  defp do_voxel_world_diff(conn, params) do
    logical_scene_id = parse_non_negative_int(params["logical_scene_id"], 1)
    cursor = parse_non_negative_int(params["cursor"], 0)
    limit = params["limit"] |> parse_non_negative_int(64) |> min(512)
    base_version = params["base_version"] || ""
    pack_config = Application.get_env(:auth_server, :voxel_world_pack, [])
    pack_status = Keyword.get(pack_config, :status, :missing)
    pack_version = Keyword.get(pack_config, :version, "worldgen-v1")
    content_version = Keyword.get(pack_config, :content_version, pack_version)
    pack_index = Keyword.get(pack_config, :pack_index)
    pack_ready? = pack_status_ready?(pack_status)

    pack_integrity =
      case DataService.Voxel.ChunkSnapshotStore.summary(logical_scene_id) do
        {:ok, snapshot_summary} ->
          world_pack_integrity(
            Keyword.get(pack_config, :generated),
            snapshot_summary,
            pack_index,
            logical_scene_id,
            content_version
          )

        {:error, reason} ->
          %{status: :error, reason: inspect(reason)}
      end

    cond do
      not pack_ready? ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_not_ready",
          logical_scene_id: logical_scene_id,
          status: pack_status,
          required_stage: "launcher_worldgen_materialization"
        })

      pack_integrity.status != :ready ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_incomplete",
          logical_scene_id: logical_scene_id,
          status: pack_status,
          integrity: pack_integrity,
          required_stage: "launcher_worldgen_materialization"
        })

      Map.get(pack_integrity, :source) == :pack_index and base_version != content_version ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "world_pack_baseline_not_served_by_world_diff",
          logical_scene_id: logical_scene_id,
          target_content_version: content_version,
          baseline_endpoint: startup_sync_endpoint(pack_integrity),
          baseline_format: world_pack_baseline_format(pack_integrity),
          required_stage: "launcher_world_pack_index_download"
        })

      base_version == content_version ->
        voxel_json(conn, %{
          schema_version: 1,
          logical_scene_id: logical_scene_id,
          base_content_version: base_version,
          target_content_version: content_version,
          cursor: cursor,
          next_cursor: nil,
          complete: true,
          chunk_count: 0,
          chunks: []
        })

      true ->
        case DataService.Voxel.ChunkSnapshotStore.list_page(logical_scene_id, cursor, limit) do
          {:ok, snapshots} ->
            next_cursor = cursor + length(snapshots)

            voxel_json(conn, %{
              schema_version: 1,
              logical_scene_id: logical_scene_id,
              base_content_version: base_version,
              target_content_version: content_version,
              cursor: cursor,
              next_cursor: if(length(snapshots) < limit, do: nil, else: next_cursor),
              complete: length(snapshots) < limit,
              chunk_count: length(snapshots),
              chunks: Enum.map(snapshots, &world_diff_chunk/1)
            })

          {:error, reason} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "world_diff_unavailable", reason: inspect(reason)})
        end
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

  defp parse_baseline_materializer("worldgen"), do: :worldgen
  defp parse_baseline_materializer("WorldGen"), do: :worldgen
  defp parse_baseline_materializer(:worldgen), do: :worldgen
  defp parse_baseline_materializer(_value), do: :empty

  defp active_window_chunk_coords({center_x, center_y, center_z}, radius)
       when is_integer(radius) and radius >= 0 do
    for cx <- (center_x - radius)..(center_x + radius),
        cy <- (center_y - radius)..(center_y + radius),
        cz <- (center_z - radius)..(center_z + radius) do
      {cx, cy, cz}
    end
  end

  defp parse_source_owner_ref(params) do
    owner_kind = params["source_owner_kind"] || params["owner_kind"]
    owner_id = params["source_owner_id"] || params["owner_id"]

    if is_binary(owner_kind) and String.trim(owner_kind) != "" and
         is_binary(owner_id) and String.trim(owner_id) != "" do
      %{kind: String.trim(owner_kind), id: String.trim(owner_id)}
    end
  end

  defp dev_materialization_ready?(%{status: status, chunk_count: count}, %{
         status: lod_status,
         total_cell_count: cells
       })
       when status in [:ready, "ready"] and lod_status in [:ready, "ready"] and count > 0 and
              cells > 0 do
    true
  end

  defp dev_materialization_ready?(_snapshot_summary, _lod_summary), do: false

  defp pack_status_ready?(status), do: status in [:ready, "ready"]

  defp world_pack_reject_reason(false, _pack_integrity), do: "world_pack_missing_or_unverified"
  defp world_pack_reject_reason(true, %{status: :ready}), do: nil
  defp world_pack_reject_reason(true, _pack_integrity), do: "world_pack_incomplete"

  defp world_pack_baseline_format(%{source: :pack_index}), do: "world_pack_index_v1"
  defp world_pack_baseline_format(_pack_integrity), do: "chunk_snapshot_pages_v1"

  defp startup_sync_endpoint(%{source: :pack_index}), do: "/ingame/voxel/world_pack"
  defp startup_sync_endpoint(_pack_integrity), do: "/ingame/voxel/world_diff"

  defp world_pack_index_for_response(pack_index, generated, logical_scene_id, content_version) do
    WorldPackIndex.new(
      logical_scene_id: map_value(pack_index, :logical_scene_id) || logical_scene_id,
      content_version: map_value(pack_index, :content_version) || content_version,
      chunk_min: map_value(pack_index, :chunk_min) || map_value(generated, :chunk_min),
      chunk_max: map_value(pack_index, :chunk_max) || map_value(generated, :chunk_max),
      payload_layout: map_value(pack_index, :payload_layout),
      regions: map_value(pack_index, :regions) || []
    )
  end

  defp world_pack_index_response(%WorldPackIndex{} = index, pack_integrity) do
    %{
      schema_version: 1,
      format: "world_pack_index_v1",
      logical_scene_id: index.logical_scene_id,
      content_version: index.content_version,
      chunk_min: Tuple.to_list(index.chunk_min),
      chunk_max: Tuple.to_list(index.chunk_max),
      chunk_count: WorldPackIndex.chunk_count(index),
      world_diff_baseline_fallback_allowed: false,
      payload_layout: world_pack_payload_layout(index.payload_layout),
      regions: Enum.map(index.regions, &world_pack_index_region/1),
      integrity: pack_integrity,
      sliding_window_contract: %{
        radius: 3,
        chunk_shape: [7, 7, 7],
        chunk_count: WorldPackIndex.sliding_window({0, 0, 0}, 3).chunk_count
      },
      index_hash: world_pack_index_hash(index)
    }
  end

  defp world_pack_payload_layout(nil), do: nil

  defp world_pack_payload_layout(layout) do
    %{
      layout: layout.layout,
      chunk_payload_format: layout.chunk_payload_format,
      shard_chunk_shape: Tuple.to_list(layout.shard_chunk_shape),
      shard_origin: Tuple.to_list(layout.shard_origin),
      file_template: layout.file_template,
      footer_format: layout.footer_format,
      compression: layout.compression
    }
  end

  defp world_pack_index_region(region) do
    %{
      id: region.id,
      chunk_min: Tuple.to_list(region.chunk_min),
      chunk_max: Tuple.to_list(region.chunk_max),
      chunk_count: region.chunk_count,
      hash: region.hash
    }
  end

  defp world_pack_index_hash(%WorldPackIndex{} = index) do
    canonical =
      {:world_pack_index_v1, index.logical_scene_id, index.content_version, index.chunk_min,
       index.chunk_max, world_pack_hash_payload_layout(index.payload_layout),
       Enum.map(index.regions, fn region ->
         {region.id, region.chunk_min, region.chunk_max, region.chunk_count, region.hash}
       end)}

    hash = :crypto.hash(:sha256, :erlang.term_to_binary(canonical))
    "sha256:" <> Base.encode16(hash, case: :lower)
  end

  defp world_pack_hash_payload_layout(nil), do: nil

  defp world_pack_hash_payload_layout(layout) do
    {layout.layout, layout.chunk_payload_format, layout.shard_chunk_shape, layout.shard_origin,
     layout.file_template, layout.footer_format, layout.compression}
  end

  defp world_pack_integrity(
         generated,
         snapshot_summary,
         pack_index,
         logical_scene_id,
         content_version
       )
       when not is_nil(pack_index) do
    expected_count = generated_chunk_count(generated)
    expected_min = generated_chunk_bound(generated, :chunk_min)
    expected_max = generated_chunk_bound(generated, :chunk_max)

    with {:ok, index} <-
           WorldPackIndex.new(
             logical_scene_id: map_value(pack_index, :logical_scene_id) || logical_scene_id,
             content_version: map_value(pack_index, :content_version) || content_version,
             chunk_min: map_value(pack_index, :chunk_min) || map_value(generated, :chunk_min),
             chunk_max: map_value(pack_index, :chunk_max) || map_value(generated, :chunk_max),
             payload_layout: map_value(pack_index, :payload_layout),
             regions: map_value(pack_index, :regions) || []
           ),
         :ok <- pack_index_matches_generated(index, expected_count, expected_min, expected_max),
         {:ok, summary} <- WorldPackIndex.verify(index) do
      summary
      |> Map.put(:source, :pack_index)
      |> Map.put(:reason, nil)
      |> Map.put(:generated_bounds, %{min: expected_min, max: expected_max})
      |> Map.put(:index_bounds, %{
        min: Tuple.to_list(index.chunk_min),
        max: Tuple.to_list(index.chunk_max)
      })
      |> Map.put(:persisted_chunk_count, map_value(snapshot_summary, :chunk_count))
    else
      {:error, %{status: status} = summary} ->
        summary
        |> Map.put_new(:status, status)
        |> Map.put(:source, :pack_index)
        |> Map.put_new(:expected_chunk_count, expected_count)
        |> Map.put_new(:generated_bounds, %{min: expected_min, max: expected_max})
        |> Map.put_new(:persisted_chunk_count, map_value(snapshot_summary, :chunk_count))

      {:error, reason} ->
        %{
          status: :invalid,
          source: :pack_index,
          reason: inspect(reason),
          expected_chunk_count: expected_count,
          persisted_chunk_count: map_value(snapshot_summary, :chunk_count),
          generated_bounds: %{min: expected_min, max: expected_max}
        }
    end
  end

  defp world_pack_integrity(
         generated,
         snapshot_summary,
         _pack_index,
         _logical_scene_id,
         _content_version
       ) do
    expected_count = generated_chunk_count(generated)
    persisted_count = map_value(snapshot_summary, :chunk_count)
    expected_min = generated_chunk_bound(generated, :chunk_min)
    expected_max = generated_chunk_bound(generated, :chunk_max)
    persisted_min = chunk_bound(snapshot_summary, :min_chunk)
    persisted_max = chunk_bound(snapshot_summary, :max_chunk)

    cond do
      expected_count == nil ->
        %{
          status: :not_declared,
          reason: "world_pack_generated_chunk_count_missing",
          expected_chunk_count: nil,
          persisted_chunk_count: persisted_count,
          generated_bounds: %{min: expected_min, max: expected_max},
          persisted_bounds: %{min: persisted_min, max: persisted_max}
        }

      persisted_count != expected_count ->
        %{
          status: :incomplete,
          reason: "snapshot_count_mismatch",
          expected_chunk_count: expected_count,
          persisted_chunk_count: persisted_count,
          generated_bounds: %{min: expected_min, max: expected_max},
          persisted_bounds: %{min: persisted_min, max: persisted_max}
        }

      expected_min != nil and persisted_min != nil and expected_min != persisted_min ->
        %{
          status: :incomplete,
          reason: "snapshot_min_bound_mismatch",
          expected_chunk_count: expected_count,
          persisted_chunk_count: persisted_count,
          generated_bounds: %{min: expected_min, max: expected_max},
          persisted_bounds: %{min: persisted_min, max: persisted_max}
        }

      expected_max != nil and persisted_max != nil and expected_max != persisted_max ->
        %{
          status: :incomplete,
          reason: "snapshot_max_bound_mismatch",
          expected_chunk_count: expected_count,
          persisted_chunk_count: persisted_count,
          generated_bounds: %{min: expected_min, max: expected_max},
          persisted_bounds: %{min: persisted_min, max: persisted_max}
        }

      true ->
        %{
          status: :ready,
          reason: nil,
          expected_chunk_count: expected_count,
          persisted_chunk_count: persisted_count,
          generated_bounds: %{min: expected_min, max: expected_max},
          persisted_bounds: %{min: persisted_min, max: persisted_max}
        }
    end
  end

  defp pack_index_matches_generated(_index, nil, _expected_min, _expected_max),
    do: {:error, :world_pack_generated_chunk_count_missing}

  defp pack_index_matches_generated(index, expected_count, expected_min, expected_max) do
    index_min = Tuple.to_list(index.chunk_min)
    index_max = Tuple.to_list(index.chunk_max)

    cond do
      WorldPackIndex.chunk_count(index) != expected_count ->
        {:error, :pack_index_chunk_count_mismatch}

      expected_min != nil and index_min != expected_min ->
        {:error, :pack_index_min_bound_mismatch}

      expected_max != nil and index_max != expected_max ->
        {:error, :pack_index_max_bound_mismatch}

      true ->
        :ok
    end
  end

  defp generated_chunk_count(generated) do
    case map_value(generated, :chunk_count) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp generated_chunk_bound(generated, key), do: chunk_bound(generated, key)

  defp chunk_bound(value, key) do
    case map_value(value, key) do
      {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) -> [x, y, z]
      [x, y, z] when is_integer(x) and is_integer(y) and is_integer(z) -> [x, y, z]
      _other -> nil
    end
  end

  defp map_value(nil, _key), do: nil

  defp map_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp map_value(value, key) when is_list(value) do
    Keyword.get(value, key) || list_key_value(value, Atom.to_string(key))
  end

  defp map_value(_value, _key), do: nil

  defp list_key_value(value, key) do
    case List.keyfind(value, key, 0) do
      {^key, found} -> found
      _other -> nil
    end
  end

  defp world_diff_chunk(snapshot) do
    %{
      chunk_coord: Tuple.to_list(snapshot.chunk_coord),
      chunk_version: snapshot.chunk_version,
      schema_version: snapshot.schema_version,
      chunk_size_in_macro: snapshot.chunk_size_in_macro,
      micro_resolution: snapshot.micro_resolution,
      chunk_hash_b64: Base.encode64(snapshot.chunk_hash),
      snapshot_payload_b64: Base.encode64(snapshot.data)
    }
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
