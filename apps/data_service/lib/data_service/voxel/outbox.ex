defmodule DataService.Voxel.Outbox do
  # PERS-5:durable_authoritative(durable replication outbox)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  Durable replication outbox(梯队3 step3.9,AUTH-9/10)。

  每条 committed `ChunkDelta` 在落 truth(durable-before-ack)之后、fanout 给 subscribers 之前同步
  `append/2` 一行。供:

    * **可靠重投**(`read_since/4`):重连 / 丢包的 observer 重放错过的 delta(new_chunk_version >
      since_version),而非每次拉整 ChunkSnapshot。
    * **visibility_watermark**(`watermark/3`):该 chunk 已 committed 的 max `new_chunk_version`;
      复制只发 ≤ watermark(speculative 不下行,AUTH-8)。voxel 路径本就只在 commit 后推,此处 formalize。

  stateless module,直走 `DataService.Repo`(`opts[:repo]` 可覆盖)。成本:热路径每 committed delta
  一次 INSERT;表增长需后续 TTL/trim。
  """

  alias DataService.Repo

  @type chunk_coord :: {integer(), integer(), integer()}
  @type record :: %{
          base_chunk_version: non_neg_integer(),
          new_chunk_version: non_neg_integer(),
          reliability_class: String.t(),
          payload: binary()
        }

  @default_reliability_class "state"

  @doc """
  追加一条 committed delta 到 outbox。`attrs`:`logical_scene_id`、`chunk_coord`(`{x,y,z}`)、
  `base_chunk_version`、`new_chunk_version`、`payload`(delta wire 字节),可选 `reliability_class`。
  """
  @spec append(map(), keyword()) :: :ok
  def append(attrs, opts \\ []) when is_map(attrs) do
    {x, y, z} = coord!(Map.fetch!(attrs, :chunk_coord))

    sql = """
    INSERT INTO voxel_outbox
      (logical_scene_id, coord_x, coord_y, coord_z, base_chunk_version, new_chunk_version,
       reliability_class, payload, inserted_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
    """

    Ecto.Adapters.SQL.query!(repo(opts), sql, [
      Map.fetch!(attrs, :logical_scene_id),
      x,
      y,
      z,
      Map.fetch!(attrs, :base_chunk_version),
      Map.fetch!(attrs, :new_chunk_version),
      Map.get(attrs, :reliability_class, @default_reliability_class),
      Map.fetch!(attrs, :payload)
    ])

    :ok
  end

  @doc "读 `new_chunk_version > since_version` 的 committed delta,按版本升序(可靠重投)。"
  @spec read_since(non_neg_integer(), chunk_coord(), non_neg_integer(), keyword()) :: [record()]
  def read_since(logical_scene_id, chunk_coord, since_version, opts \\ []) do
    {x, y, z} = coord!(chunk_coord)

    sql = """
    SELECT base_chunk_version, new_chunk_version, reliability_class, payload
    FROM voxel_outbox
    WHERE logical_scene_id = $1 AND coord_x = $2 AND coord_y = $3 AND coord_z = $4
      AND new_chunk_version > $5
    ORDER BY new_chunk_version ASC
    """

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo(opts), sql, [logical_scene_id, x, y, z, since_version])

    Enum.map(rows, fn [base, new, reliability_class, payload] ->
      %{
        base_chunk_version: base,
        new_chunk_version: new,
        reliability_class: reliability_class,
        payload: payload
      }
    end)
  end

  @doc "该 chunk 的 visibility_watermark = 已 committed 的 max `new_chunk_version`(无则 0)。"
  @spec watermark(non_neg_integer(), chunk_coord(), keyword()) :: non_neg_integer()
  def watermark(logical_scene_id, chunk_coord, opts \\ []) do
    {x, y, z} = coord!(chunk_coord)

    sql = """
    SELECT COALESCE(MAX(new_chunk_version), 0)
    FROM voxel_outbox
    WHERE logical_scene_id = $1 AND coord_x = $2 AND coord_y = $3 AND coord_z = $4
    """

    %{rows: [[max_version]]} =
      Ecto.Adapters.SQL.query!(repo(opts), sql, [logical_scene_id, x, y, z])

    max_version
  end

  @doc "清空 outbox(test-only hatch / 后续 trim 基础)。"
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Ecto.Adapters.SQL.query!(repo(opts), "DELETE FROM voxel_outbox", [])
    :ok
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value),
    do: raise(ArgumentError, "expected chunk coord {x, y, z}, got: #{inspect(value)}")

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
