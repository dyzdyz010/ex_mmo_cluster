defmodule DataService.UidGenerator do
  @moduledoc """
  账号与角色主键的 64 位雪花 id 生成器（Twitter Snowflake `IdWorker` 的标准算法）。

  调用方：`DataService.CharacterStore.ensure_npc/1`（NPC 角色）与 `DataService.Worker`（注册账号、开发账号及其角色）。

  ## 位布局

      | 1 位符号（恒 0） | 41 位距纪元毫秒数 | 10 位 service_id | 12 位序号 |

  `id = (now_ms - 纪元) <<< 22 ||| service_id <<< 12 ||| 序号`。符号位恒 0，id 总是 PostgreSQL bigint 的非负值。
  时间段在最高位，所以同一 service 签发的 id 随签发时刻递增。`service_id` 取应用配置 `:service_id`（0..1023），
  同时运行的每个生成器必须各用一个，否则同毫秒会撞号。

  ## 纪元：固定 2021-01-01T00:00:00Z（Unix 毫秒 1_609_459_200_000）

  纪元是模块常量，不从应用配置取：它一变，已签发的 id 与新 id 就可能重叠。取值理由：

  - **新 id 大于旧实现签发过的全部 id。** 旧实现（2022-06-08 引入）把纪元取成进程启动时刻，时间段装的是
    “本次启动后的毫秒数”，位布局相同。任何旧进程启动时刻 `S` 都不早于 2022-06-08（晚于本纪元），
    在 `G` 时刻签发的旧 id 时间段 `G - S < G - 纪元`，因此小于此后任何新 id 的时间段，而时间段在最高位。
    纪元早于仓库首次提交（2021-02-26），没有更早的旧 id。
  - **可用年限。** 41 位最多表示 2^41 - 1 ms（约 69.7 年），最后一个可用毫秒是 2090-09-07T15:47:35.551Z；
    超出（或时钟早于纪元）时显式返回 `{:timestamp_out_of_range, ...}`，不回绕。

  ## 序号

  同一毫秒内序号从 0 起逐个 +1；4096 个用尽时等到下一毫秒再签发；进入新毫秒序号归 0
  （同 IdWorker.nextId 的 `sequence = (sequence + 1) & sequenceMask`、`tilNextMillis` 与 `sequence = 0`）。

  ## 时间源与时钟回拨

  时间源取 `System.system_time(:millisecond)`（`erlang:system_time/1`）。依据：

  - Twitter snowflake 仓库 tag `snowflake-2010` 的 `src/main/scala/com/twitter/service/snowflake/IdWorker.scala`：
    `timeGen()` 读墙钟（`System.currentTimeMillis()`），`lastTimestamp` 初值 `-1`；当前时刻早于上次签发时刻时记错误日志
    （"clock is moving backwards. Rejecting requests until %d."）并抛 `InvalidSystemClock`，拒绝签发直到时钟追回。
    同仓库 README「System Clock Dependency」：时钟回拨时拒绝生成 id，直到时刻晚于上次签发时刻。
  - Erlang/OTP 文档 “Time and Time Correction in Erlang”（`erts/time_correction`）：OTP 26 起默认 Multi-Time Warp Mode，
    该模式下 “Erlang system time can perform time warps both forwards and backwards at any time”；
    “How to Work with the New API” 规定取 Erlang 系统时间用 `erlang:system_time/1`。本仓未设 `+C`，
    生产镜像是 OTP 29（`Dockerfile`），所以系统时间会随 OS 时钟前后跳，必须显式处理回拨。

  不采用的做法：`System.os_time/1` 是未经运行时平滑的 OS 时间，同样会回拨，文档不推荐用它取系统时间。
  “单调时间 + 启动时偏移”在一次 VM 生命周期内不回退，但时间段会与真实时刻持续偏离，而且偏移在每次重启时按
  当时的 OS 时间重取：若上次运行期间时钟偏快、之后被校回，重启后会**静默**签出已用过的时间段，比显式拒绝更糟。

  回拨处理：`now_ms < 上次签发时刻` 时 `next/2` 返回 `{:clock_moved_backwards, %{last_ms:, now_ms:}}`，GenServer
  打 `data_service_uid_generate_failed` 错误日志、原样返回错误且**不改状态**，此后持续拒绝，直到时钟追回 `last_ms`。
  `last_ms` 只在进程内存里：跨重启的唯一性依赖时钟在重启前后不回拨（与 snowflake README 的假设相同）。

  ## 结构

  `new/1` 与 `next/2` 是纯函数（给定状态与 `now_ms`，结果确定）；GenServer 只负责读时钟、保存状态与记日志。
  """
  use GenServer

  import Bitwise

  require Logger

  @epoch_ms 1_609_459_200_000

  @timestamp_bits 41
  @service_bits 10
  @sequence_bits 12

  @max_elapsed_ms (1 <<< @timestamp_bits) - 1
  @max_service_id (1 <<< @service_bits) - 1
  @max_sequence (1 <<< @sequence_bits) - 1

  @service_shift @sequence_bits
  @timestamp_shift @sequence_bits + @service_bits

  @enforce_keys [:service_id]
  defstruct service_id: nil, last_ms: -1, sequence: 0

  @typedoc "生成器状态：`last_ms` 是上次签发时刻（Unix 毫秒，初值 -1 表示尚未签发），`sequence` 是该毫秒已用的最后一个序号。"
  @type t :: %__MODULE__{
          service_id: 0..1023,
          last_ms: integer(),
          sequence: 0..4095
        }

  @typedoc "签发失败原因：时钟回拨，或时刻早于纪元 / 超出 41 位时间段。"
  @type error ::
          {:clock_moved_backwards, %{last_ms: integer(), now_ms: integer()}}
          | {:timestamp_out_of_range, %{now_ms: integer()}}

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @doc """
  签发一个新 id：`{:ok, id}`（非负 64 位整数），或 `{:error, reason}`（见 `t:error/0`，已打错误日志）。

  `server` 默认是随 DataService 应用启动的注册进程。
  """
  @spec generate(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, error()}
  def generate(server \\ __MODULE__) do
    GenServer.call(server, :generate)
  end

  @doc "给定 `service_id`（0..1023）的初始状态：尚未签发，序号 0。"
  @spec new(0..1023) :: t()
  def new(service_id) when service_id in 0..@max_service_id do
    %__MODULE__{service_id: service_id}
  end

  @doc """
  纯函数：在 `now_ms`（Unix 毫秒）签发下一个 id。

  - `{:ok, id, state}`：同一毫秒序号 +1；新毫秒序号归 0。
  - `:sequence_exhausted`：本毫秒 4096 个序号已用完，须等到 `now_ms > state.last_ms` 再调用；状态不变。
  - `{:error, {:clock_moved_backwards, %{last_ms:, now_ms:}}}`：`now_ms` 早于上次签发时刻；状态不变。
  - `{:error, {:timestamp_out_of_range, %{now_ms:}}}`：`now_ms` 早于纪元或超出 41 位时间段；状态不变。
  """
  @spec next(t(), integer()) ::
          {:ok, non_neg_integer(), t()} | :sequence_exhausted | {:error, error()}
  def next(%__MODULE__{last_ms: last_ms, sequence: sequence} = state, now_ms)
      when is_integer(now_ms) do
    cond do
      now_ms < last_ms ->
        {:error, {:clock_moved_backwards, %{last_ms: last_ms, now_ms: now_ms}}}

      now_ms == last_ms and sequence == @max_sequence ->
        :sequence_exhausted

      now_ms == last_ms ->
        issue(state, now_ms, sequence + 1)

      true ->
        issue(state, now_ms, 0)
    end
  end

  defp issue(state, now_ms, sequence) do
    elapsed_ms = now_ms - @epoch_ms

    if elapsed_ms in 0..@max_elapsed_ms do
      id =
        elapsed_ms <<< @timestamp_shift ||| state.service_id <<< @service_shift ||| sequence

      {:ok, id, %{state | last_ms: now_ms, sequence: sequence}}
    else
      {:error, {:timestamp_out_of_range, %{now_ms: now_ms}}}
    end
  end

  ## Callbacks

  @impl true
  def init(_args) do
    {:ok, new(Application.get_env(:data_service, :service_id, 1))}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    case issue_at_current_time(state) do
      {:ok, id, next_state} ->
        {:reply, {:ok, id}, next_state}

      {:error, reason} = error ->
        Logger.error(
          "data_service_uid_generate_failed service_id=#{state.service_id} reason=#{inspect(reason)}"
        )

        {:reply, error, state}
    end
  end

  # 本毫秒序号用尽时重读时钟直到进入下一毫秒（同 IdWorker.tilNextMillis 的忙等，至多约 1 ms）。
  defp issue_at_current_time(state) do
    case next(state, System.system_time(:millisecond)) do
      :sequence_exhausted -> issue_at_current_time(state)
      result -> result
    end
  end
end
