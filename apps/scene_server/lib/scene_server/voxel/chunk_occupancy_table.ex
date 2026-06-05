defmodule SceneServer.Voxel.ChunkOccupancyTable do
  @moduledoc """
  Per-chunk **只读 occupancy 快照**（读写分离的发布点）。

  阶段5.2（voxel-storage-1 / S2-S3 热路径去同步）：碰撞查询是移动权威解析的
  **最热读路径**，原本经 `ChunkDirectory` 串行 mailbox → `ChunkProcess`
  `GenServer.call` 两跳同步路由，落方块写与碰撞读在同一条 mailbox 上 head-of-line
  互相阻塞。本模块把碰撞读所需的 occupancy 真相**发布**到一张 per-chunk ETS 表，
  让读路径完全不经 chunk 进程的 mailbox。

  ## 谁拥有状态、谁只做发布/读取

  * **`ChunkProcess` 拥有 voxel 真相**（`Storage`）。它是唯一的写者：每次授权写
    收尾（`post_write_lifecycle/1`）后，把当前 storage 的 occupancy 投影**原子
    替换**进本表（一次 `:ets.insert`，O(1)）。表所有权归 chunk 进程：随 chunk
    `terminate` 一并消失（`ChunkProcess` 在 init 建表、在 terminate 删表），不存在
    跨进程孤儿表。
  * **读者（如 `Movement.VoxelCollision`）只读不写**：经 `read_snapshot/2` 拿到
    当前发布的 `%Snapshot{}`（ETS 读得到的是一份拷贝，与写者并发安全），在**读者
    自己的进程**里跑纯函数 `query/2` 解析碰撞命中——不触达 chunk mailbox，因此落
    方块写与碰撞读在数据结构层彻底分离：读不阻塞写、写不阻塞读。

  ## 单调版本 + 单主语义

  快照携带 `chunk_version`。同 `{logical_scene_id, chunk_coord}` 的权威只有一个
  （`ChunkRegistry` `:unique` 裁决），因此本表也只有一个写者；读者读到的 occupancy
  与权威 storage 的差异仅是“最近一次发布到下一次写之间”的窗口，且每个发布都是某个
  真实 `chunk_version` 的完整投影（不会读到半更新态）。碰撞解析对这点是收敛安全的：
  权威端在落账时已做 occupancy precheck，客户端读到的占用快照仅用于移动限幅。

  ## 命名

  表名经 `table_name/2` 从 `{logical_scene_id, chunk_coord}` 派生，写进 ETS 的
  `:named_table`，使读者无需经任何进程即可 `:ets.whereis` 定位（未建表 / chunk 未
  hot 时返回 `:not_published`，读者据此回退到经 facade 的 ensure+直达慢路）。
  """

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  defmodule Snapshot do
    @moduledoc """
    一个已发布的 occupancy 快照（某个 `chunk_version` 的完整投影）。

    `storage` 是带 accel 的只读 `Storage`，供 `ChunkOccupancyTable.query/2` 做
    O(1) 随机读。它是写者发布时的拷贝，读者并发读安全。
    """
    @enforce_keys [:logical_scene_id, :chunk_coord, :chunk_version, :storage]
    defstruct [:logical_scene_id, :chunk_coord, :chunk_version, :storage]

    @type t :: %__MODULE__{
            logical_scene_id: non_neg_integer(),
            chunk_coord: {integer(), integer(), integer()},
            chunk_version: non_neg_integer(),
            storage: Storage.t()
          }
  end

  @snapshot_key :occupancy_snapshot

  @doc """
  派生本 chunk 的 occupancy ETS 表名。

  同 `{logical_scene_id, chunk_coord}` 稳定派生同一个 atom，使读者无需经进程即可
  定位表。atom 取值域受限于实际 hot chunk 集合（有界），不存在 user input 注入。
  """
  @spec table_name(non_neg_integer(), {integer(), integer(), integer()}) :: atom()
  def table_name(logical_scene_id, {cx, cy, cz}) do
    :"voxel_occupancy_#{logical_scene_id}_#{cx}_#{cy}_#{cz}"
  end

  @doc """
  由 chunk 进程在 `init` 调用，建立本 chunk 的 occupancy 表（若尚不存在）。

  表是 `:public`（写者是 chunk 进程，读者是任意移动解析进程）、`read_concurrency:
  true`。**所有权归调用方进程**：进程退出表自动消失。返回表的引用 atom。
  """
  @spec ensure_table(non_neg_integer(), {integer(), integer(), integer()}) :: atom()
  def ensure_table(logical_scene_id, chunk_coord) do
    name = table_name(logical_scene_id, chunk_coord)

    case :ets.whereis(name) do
      :undefined ->
        create_named_table(name)

      _tid ->
        name
    end
  end

  # `:ets.new` 对同名 `:named_table` 会 badarg。正常情况下 `whereis` 已先排除，但
  # 旧 owner 进程刚死、ETS 自动回收命名表的窗口里仍可能撞上重名（whereis 命中 →
  # 删除 → 我们这里再建）。重名时再 whereis 一次复用既有表（旧 owner 仍持有它，
  # 单主语义下旧 owner 即将退出，本次复用是安全的；若它确实已删，下一拍 publish/
  # read 走 :not_published 兜底）。
  defp create_named_table(name) do
    :ets.new(name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: false
    ])

    name
  rescue
    # 重名（旧 owner 命名表尚未被 ETS 回收）。单主语义下旧 owner 即将退出；本次
    # 复用既有表名是安全的——publish/read 都按当前内容工作，旧 owner 退出后表内容
    # 由新 owner 的 publish 覆盖。
    ArgumentError -> name
  end

  @doc """
  由 chunk 进程在每次授权写收尾时调用：把当前 storage 的 occupancy 投影**原子
  替换**进表。一次 `:ets.insert` 覆盖单一 key，O(1)。

  storage 先 `ensure_accel/1`，使读者的 `query/2` 全部走 O(1) 随机读。发布的是
  一个完整 `chunk_version` 的投影，读者不会看到半更新态。
  """
  @spec publish(atom(), Storage.t()) :: :ok
  def publish(table, %Storage{} = storage) do
    snapshot = %Snapshot{
      logical_scene_id: storage.logical_scene_id,
      chunk_coord: storage.chunk_coord,
      chunk_version: storage.chunk_version,
      storage: Storage.ensure_accel(storage)
    }

    :ets.insert(table, {@snapshot_key, snapshot})
    :ok
  end

  @doc """
  由 chunk 进程在 `terminate` 调用，显式删表（兜底；进程退出 ETS 也会自动回收
  `:public` 表的 heir-less 表）。幂等。
  """
  @spec delete_table(atom()) :: :ok
  def delete_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _tid -> safe_delete(table)
    end
  end

  defp safe_delete(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  读路径入口：读取已发布的 occupancy 快照（不经任何进程 mailbox）。

  返回 `{:ok, %Snapshot{}}` 或 `:not_published`（表不存在或尚无发布——chunk 未
  hot / 刚起还没写过）。读者据此回退到经 facade 的 ensure+直达慢路（首帧之后即热
  路径直读）。
  """
  @spec read_snapshot(non_neg_integer(), {integer(), integer(), integer()}) ::
          {:ok, Snapshot.t()} | :not_published
  def read_snapshot(logical_scene_id, chunk_coord) do
    name = table_name(logical_scene_id, chunk_coord)

    case :ets.whereis(name) do
      :undefined ->
        :not_published

      _tid ->
        case safe_lookup(name) do
          [{@snapshot_key, %Snapshot{} = snapshot}] -> {:ok, snapshot}
          _ -> :not_published
        end
    end
  end

  defp safe_lookup(name) do
    :ets.lookup(name, @snapshot_key)
  rescue
    # 表在 whereis 与 lookup 之间被 chunk terminate 删除——视同未发布。
    ArgumentError -> []
  end

  @doc """
  纯函数：在读者进程里对快照 storage 解析碰撞命中。

  `samples` 是已规范化的 `[%{macro_index:, macro:, micro_slot:}]`。与原
  `ChunkProcess` 的 GenServer 内解析逻辑**逐位等价**（同 solid/refined 判定、同
  occupancy bit 读法），只是搬到读者进程跑、数据来自发布快照而非 chunk state。
  返回与 `ChunkProcess.collision_query/3` 一致的 `%{occupied:, occupied_count:,
  ...}` map。
  """
  @spec query(Snapshot.t(), [map()]) :: %{
          logical_scene_id: non_neg_integer(),
          chunk_coord: {integer(), integer(), integer()},
          chunk_version: non_neg_integer(),
          sample_count: non_neg_integer(),
          occupied_count: non_neg_integer(),
          occupied: [map()]
        }
  def query(%Snapshot{} = snapshot, samples) when is_list(samples) do
    occupied =
      snapshot.storage
      |> hits(samples)
      |> Enum.sort_by(fn hit -> {hit.macro_index, hit.micro_slot} end)

    %{
      logical_scene_id: snapshot.logical_scene_id,
      chunk_coord: snapshot.chunk_coord,
      chunk_version: snapshot.chunk_version,
      sample_count: length(samples),
      occupied_count: length(occupied),
      occupied: occupied
    }
  end

  # 与 ChunkProcess 的 collision_query_hits / _hit / _micro_slot_occupied? 逐位
  # 等价（阶段2.5 accel 随机读）。两处实现保持同形，确保 ETS 快照读与权威 storage
  # 读结果一致（测试 ③ 断言一致性）。
  defp hits(%Storage{} = storage, samples) do
    index = %{
      storage: Storage.ensure_accel(storage),
      solid_mode: MacroCellHeader.cell_mode_solid_block(),
      refined_mode: MacroCellHeader.cell_mode_refined()
    }

    Enum.flat_map(samples, fn sample ->
      case hit(index, sample) do
        nil -> []
        hit -> [hit]
      end
    end)
  end

  defp hit(index, sample) do
    header = Storage.fetch_macro_header(index.storage, sample.macro_index)

    cond do
      header.mode == index.solid_mode ->
        Map.put(sample, :mode, :solid)

      header.mode == index.refined_mode and
          micro_slot_occupied?(index, header.payload_index, sample.micro_slot) ->
        Map.put(sample, :mode, :refined)

      true ->
        nil
    end
  end

  defp micro_slot_occupied?(index, payload_index, micro_slot) do
    refined_cell = Storage.fetch_refined_cell(index.storage, payload_index)
    word_idx = div(micro_slot, 64)
    bit_idx = rem(micro_slot, 64)
    word = Enum.at(refined_cell.occupancy_words, word_idx)

    band(word, bsl(1, bit_idx)) != 0
  end

  @doc """
  规范化一个碰撞 sample（与 `ChunkProcess` 的 `normalize_collision_sample/1` 同形）。

  供读路径在不进 chunk 的情况下自行规范化 samples。接受 `{macro, micro_slot}` 或
  含 `:macro`/`:macro_index`/`:macro_coord` + `:micro_slot`/`:micro_slot_index`
  的 map。
  """
  @spec normalize_sample(term()) :: {:ok, map()} | {:error, term()}
  def normalize_sample({macro, micro_slot}) do
    normalize_sample(%{macro: macro, micro_slot: micro_slot})
  end

  def normalize_sample(%{} = attrs) do
    with macro_value when not is_nil(macro_value) <-
           fetch_first(attrs, [:macro, :macro_index, :macro_coord]),
         {:ok, macro_index} <- safe_macro_index(macro_value),
         slot when not is_nil(slot) <- fetch_first(attrs, [:micro_slot, :micro_slot_index]),
         {:ok, micro_slot} <- safe_micro_slot(slot) do
      {:ok,
       %{
         macro_index: macro_index,
         macro: Types.macro_coord!(macro_index),
         micro_slot: micro_slot
       }}
    else
      nil -> {:error, :invalid_collision_sample}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_sample(_sample), do: {:error, :invalid_collision_sample}

  @doc """
  规范化整个 samples 列表（去重、严格校验），与 `ChunkProcess.normalize_collision_query/1`
  的 samples 子句同形。返回 `{:ok, [normalized]}` 或 `{:error, reason}`。
  """
  @spec normalize_samples(term()) :: {:ok, [map()]} | {:error, term()}
  def normalize_samples(samples) when is_list(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
      case normalize_sample(sample) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        deduped =
          normalized
          |> Enum.reverse()
          |> Enum.uniq_by(fn sample -> {sample.macro_index, sample.micro_slot} end)

        {:ok, deduped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize_samples(_samples), do: {:error, :invalid_collision_query}

  defp fetch_first(attrs, keys) do
    Enum.find_value(keys, fn key -> Map.get(attrs, key) end)
  end

  defp safe_macro_index(value) do
    {:ok, Types.macro_index_or_coord!(value)}
  rescue
    _ -> {:error, :invalid_macro_index}
  end

  defp safe_micro_slot(value) when is_integer(value) and value >= 0 and value <= 511 do
    {:ok, value}
  end

  defp safe_micro_slot(_), do: {:error, :invalid_micro_slot}
end
