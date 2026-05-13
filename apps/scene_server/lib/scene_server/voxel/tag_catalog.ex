defmodule SceneServer.Voxel.TagCatalog do
  @moduledoc """
  Phase 5.C in-memory tag catalog runtime。结构与
  `SceneServer.Voxel.AttributeCatalog` 对称但更简单（TagDefinition 仅 id + name，
  Phase 1.3 T-2 决策：不携带 value）。

  启动时从 `priv/catalogs/tag_catalog_v1.exs` 加载第一批 tag 定义，写入 private
  ETS，对外暴露 lookup_by_id / lookup_by_name / current_snapshot API。

  设计草案 `docs/plans/2026-05-13-phase5c-first-batch-catalog-seed.md`
  C-5 / C-6 / C-8 推荐方案。

  Phase 5.C 不做（推到 5.C.2 / 5.D）：
    * Catalog 持久化（跨进程重启从 DataService 恢复）。
    * 客户端 catalog 消费（web_client TS decoder for opcode 0x6D + UI）。

  ETS 表名规则：模块名 singleton（`name: __MODULE__`，默认）走固定表名
  `:scene_server_voxel_tag_catalog` / `:scene_server_voxel_tag_catalog_by_name`，
  允许 lookup_by_id / lookup_by_name 直接 `:ets.lookup` 旁路 GenServer。
  注册成其他原子名时表名加后缀；以 pid 注册（测试 ad-hoc）时 lookup 会经一次
  `GenServer.call` 拿到表 atom。
  """

  use GenServer

  alias SceneServer.Voxel.TagCatalogSnapshot
  alias SceneServer.Voxel.TagDefinition

  require Logger

  @default_seed_path "catalogs/tag_catalog_v1.exs"
  @table_name :scene_server_voxel_tag_catalog
  @name_table_name :scene_server_voxel_tag_catalog_by_name

  # ---- public API -------------------------------------------------------------

  @doc """
  Starts the TagCatalog GenServer.

  Options:
    * `:name` — registered name (default `__MODULE__`)
    * `:seed_path` — override seed file path (default
      `Application.app_dir(:scene_server, "priv/catalogs/tag_catalog_v1.exs")`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    init_opts = Keyword.put(init_opts, :registered_name, name)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Looks up a tag by catalog id. Returns `{:ok, %TagDefinition{}}` or
  `{:error, :not_found}`.
  """
  @spec lookup_by_id(GenServer.server(), non_neg_integer()) ::
          {:ok, TagDefinition.t()} | {:error, :not_found}
  def lookup_by_id(server \\ __MODULE__, id) when is_integer(id) and id >= 0 do
    table = id_table_for(server)

    case :ets.lookup(table, {:id, id}) do
      [{_key, defn}] -> {:ok, defn}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Looks up a tag by name. Returns `{:ok, id, %TagDefinition{}}` or
  `{:error, :not_found}`.
  """
  @spec lookup_by_name(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer(), TagDefinition.t()} | {:error, :not_found}
  def lookup_by_name(server \\ __MODULE__, name) when is_binary(name) do
    name_table = name_table_for(server)
    id_table = id_table_for(server)

    case :ets.lookup(name_table, {:name, name}) do
      [{_key, id}] ->
        case :ets.lookup(id_table, {:id, id}) do
          [{_key, defn}] -> {:ok, id, defn}
          [] -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the full catalog as a `%TagCatalogSnapshot{}` — the same wire type
  emitted on opcode `0x6D`. Definitions are sorted ascending by id.
  """
  @spec current_snapshot(GenServer.server()) :: TagCatalogSnapshot.t()
  def current_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :current_snapshot)
  end

  @doc """
  Returns the current `catalog_version` (monotonic u64).
  """
  @spec catalog_version(GenServer.server()) :: non_neg_integer()
  def catalog_version(server \\ __MODULE__) do
    GenServer.call(server, :catalog_version)
  end

  @doc """
  Force-reloads the seed file. Phase 5.C 不暴露给生产路径，仅供测试 / dev 使用。
  """
  @spec reload!(GenServer.server(), keyword()) :: :ok
  def reload!(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:reload, opts})
  end

  # ---- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    seed_path = Keyword.get(opts, :seed_path, default_seed_path())
    registered_name = Keyword.get(opts, :registered_name, __MODULE__)

    id_table = id_table_for_name(registered_name)
    name_table = name_table_for_name(registered_name)

    :ets.new(id_table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.new(name_table, [:set, :protected, :named_table, read_concurrency: true])

    snapshot = load_seed!(seed_path)
    populate_tables!(id_table, name_table, snapshot)

    Logger.info(
      "SceneServer.Voxel.TagCatalog loaded #{length(snapshot.definitions)} tags " <>
        "(catalog_version=#{snapshot.catalog_version}) from #{seed_path}"
    )

    {:ok,
     %{
       seed_path: seed_path,
       id_table: id_table,
       name_table: name_table,
       snapshot: snapshot
     }}
  end

  @impl true
  def handle_call(:current_snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call(:catalog_version, _from, state) do
    {:reply, state.snapshot.catalog_version, state}
  end

  def handle_call({:reload, opts}, _from, state) do
    seed_path = Keyword.get(opts, :seed_path, state.seed_path)
    snapshot = load_seed!(seed_path)

    :ets.delete_all_objects(state.id_table)
    :ets.delete_all_objects(state.name_table)
    populate_tables!(state.id_table, state.name_table, snapshot)

    {:reply, :ok, %{state | seed_path: seed_path, snapshot: snapshot}}
  end

  def handle_call({:__which_table__, :id_table}, _from, state),
    do: {:reply, state.id_table, state}

  def handle_call({:__which_table__, :name_table}, _from, state),
    do: {:reply, state.name_table, state}

  # ---- internals: seed loading ------------------------------------------------

  defp default_seed_path do
    Application.app_dir(:scene_server, Path.join("priv", @default_seed_path))
  end

  defp load_seed!(path) do
    {raw, _bindings} = Code.eval_file(path)

    unless is_map(raw) do
      raise ArgumentError,
            "TagCatalog seed at #{path} must evaluate to a map, got: #{inspect(raw)}"
    end

    catalog_version = Map.fetch!(raw, :catalog_version)
    raw_defs = Map.fetch!(raw, :definitions)

    unless is_list(raw_defs) do
      raise ArgumentError,
            "TagCatalog seed definitions must be a list, got: #{inspect(raw_defs)}"
    end

    definitions = Enum.map(raw_defs, &TagDefinition.normalize!/1)

    TagCatalogSnapshot.normalize!(%{
      catalog_version: catalog_version,
      definitions: definitions
    })
  end

  # ---- internals: ETS table management ----------------------------------------

  defp populate_tables!(id_table, name_table, %TagCatalogSnapshot{definitions: defs}) do
    Enum.each(defs, fn %TagDefinition{} = defn ->
      :ets.insert(id_table, {{:id, defn.id}, defn})
      :ets.insert(name_table, {{:name, defn.name}, defn.id})
    end)

    :ok
  end

  defp id_table_for_name(__MODULE__), do: @table_name

  defp id_table_for_name(name) when is_atom(name) do
    String.to_atom("#{@table_name}_#{name}")
  end

  defp name_table_for_name(__MODULE__), do: @name_table_name

  defp name_table_for_name(name) when is_atom(name) do
    String.to_atom("#{@name_table_name}_#{name}")
  end

  defp id_table_for(__MODULE__), do: @table_name
  defp id_table_for(name) when is_atom(name), do: id_table_for_name(name)
  defp id_table_for(pid) when is_pid(pid), do: lookup_table_via_call(pid, :id_table)

  defp name_table_for(__MODULE__), do: @name_table_name
  defp name_table_for(name) when is_atom(name), do: name_table_for_name(name)
  defp name_table_for(pid) when is_pid(pid), do: lookup_table_via_call(pid, :name_table)

  defp lookup_table_via_call(pid, which) do
    GenServer.call(pid, {:__which_table__, which})
  end
end
