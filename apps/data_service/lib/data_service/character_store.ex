defmodule DataService.CharacterStore do
  @moduledoc """
  玩法 loop · 玩家运行态持久化(Phase 0)。

  把一个活跃角色的**运行态**(位置、HP/SP/MP)写回 `characters` 行,使会话有连续性:
  登出落库、下次登录由现成加载路径(gate `build_character_profile` 读 DB `position`)恢复。

  与体素持久化(`DataService.Voxel.ChunkSnapshotStore`)同范式:**直接走 `DataService.Repo`
  的模块函数**(非 Worker/Dispatcher poolboy 身份路径)——运行态是高频写的游戏态,贴体素
  存储而非身份读。`save_runtime_state/2` 仅 patch 给定字段(`position` 存为 `%{"x"/"y"/"z"}`
  map,与 schema + gate 读取约定一致),不动 name/account 等身份字段。
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Repo
  alias DataService.Schema.Character

  @type vec3 :: {number(), number(), number()}

  @doc """
  把角色 `character_id` 的运行态 patch 落库。`attrs` 可含:
    * `:position` —— `{x, y, z}` tuple(存为 `%{"x"=>,"y"=>,"z"=>}` map),
    * `:hp` / `:sp` / `:mp` —— 整数。
  返回 `{:ok, %Character{}}` / `{:error, reason}`;角色不存在 → `{:error, :not_found}`。
  """
  @spec save_runtime_state(integer(), map()) :: {:ok, Character.t()} | {:error, term()}
  def save_runtime_state(character_id, attrs) when is_integer(character_id) and is_map(attrs) do
    case Repo.get(Character, character_id) do
      nil ->
        {:error, :not_found}

      %Character{} = character ->
        character
        |> Character.changeset(runtime_patch(attrs))
        |> Repo.update()
    end
  end

  def save_runtime_state(_character_id, _attrs), do: {:error, :invalid_args}

  @doc "读回角色(供测试/恢复路径直接取 DB 运行态);不存在 → nil。"
  @spec get_character(integer()) :: Character.t() | nil
  def get_character(character_id) when is_integer(character_id) do
    Repo.get(Character, character_id)
  end

  def get_character(_character_id), do: nil

  @doc "角色当前持久化的位置 `{x,y,z}`(float),无角色/无位置 → nil。"
  @spec persisted_position(integer()) :: vec3() | nil
  def persisted_position(character_id) do
    case Repo.one(from(c in Character, where: c.id == ^character_id, select: c.position)) do
      %{} = pos -> position_to_tuple(pos)
      _other -> nil
    end
  end

  # --- internal -------------------------------------------------------------

  # 只保留 runtime 字段(身份字段不在此路径改);position tuple → map。
  defp runtime_patch(attrs) do
    patch = %{}

    patch =
      case Map.fetch(attrs, :position) do
        {:ok, {x, y, z}} ->
          Map.put(patch, :position, %{"x" => x * 1.0, "y" => y * 1.0, "z" => z * 1.0})

        _other ->
          patch
      end

    [:hp, :sp, :mp]
    |> Enum.reduce(patch, fn key, acc ->
      case Map.fetch(attrs, key) do
        {:ok, value} when is_integer(value) -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp position_to_tuple(%{} = pos) do
    x = pos["x"] || pos[:x]
    y = pos["y"] || pos[:y]
    z = pos["z"] || pos[:z]

    if is_number(x) and is_number(y) and is_number(z) do
      {x * 1.0, y * 1.0, z * 1.0}
    else
      nil
    end
  end
end
