defmodule DataService.UidGenerator do
  @moduledoc """
  Snowflake 风格的 64 位唯一 ID 生成器(单一权威序列源)。

  位布局(最高位恒为 0,保证生成的整数非负):

      <<0::1, timestamp::41, service_id::10, sequence::12>>

  - `timestamp`:相对 `base_time` 的毫秒偏移(41 位 ≈ 69.7 年)。
  - `service_id`:集群内服务实例标识(10 位,0..1023),保证跨节点 ID 不碰撞;
    集群内每个实例必须配置不同的 `:service_id`。
  - `sequence`:同一毫秒内的递增序列(12 位,0..4095)。

  ## 并发与权威模型

  本模块是 *唯一* 的权威序列源:所有 ID 由这个 GenServer 串行生成,state 中的
  `{last_timestamp, sequence}` 是该序列的唯一真相;调用方不得绕过本进程自行拼装 ID。

  - 同一毫秒内序列耗尽(达到 4095)时,自旋到下一毫秒并把序列重置为 0。
  - 检测到时钟回拨(now < last_timestamp)时,记 `Logger.error` 并自旋等待到严格的
    新毫秒,绝不复用已发出的时间戳,以此避免产生 <= 已发出 ID 的时间戳。

  决策逻辑被提纯为 `decide/4`(无副作用),取时钟与自旋等副作用留在 `handle_call`,
  便于对所有时序分支做确定性单测。
  """
  use GenServer
  require Logger
  import Bitwise

  @time_bits 41
  @service_bits 10
  @sequence_bits 12

  @max_timestamp (1 <<< @time_bits) - 1
  @max_service_id (1 <<< @service_bits) - 1
  @max_sequence (1 <<< @sequence_bits) - 1

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @doc "生成一个 64 位唯一 ID,返回 8 字节 big-endian bitstring。"
  def generate() do
    GenServer.call(__MODULE__, :generate)
  end

  ## Callbacks

  @impl true
  def init(_args) do
    base_time =
      Application.get_env(:data_service, :base_time, DateTime.utc_now())
      |> DateTime.to_unix(:millisecond)

    service_id = Application.get_env(:data_service, :service_id, 1)

    unless is_integer(service_id) and service_id >= 0 and service_id <= @max_service_id do
      raise ArgumentError,
            "DataService.UidGenerator service_id 必须是 0..#{@max_service_id} 的整数," <>
              "得到 #{inspect(service_id)};service_id 用于保证跨节点 ID 唯一," <>
              "集群内每个实例必须配置不同的值。"
    end

    # last_timestamp = -1 表示"尚未生成过",确保首次生成走"新毫秒"分支而非误判同毫秒/回拨。
    {:ok, %{base_time: base_time, last_timestamp: -1, service_id: service_id, sequence: 0}}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    %{base_time: base_time, last_timestamp: last_timestamp, sequence: last_sequence} = state

    now = current_timestamp(base_time)

    {timestamp, sequence} =
      case decide(now, last_timestamp, last_sequence, @max_sequence) do
        {:ok, ts, seq} ->
          {ts, seq}

        {:wait_next, last} ->
          # 同一毫秒序列耗尽:自旋到下一毫秒,序列重置。
          {wait_next_millis(base_time, last), 0}

        {:clock_backwards, last} ->
          Logger.error(
            "DataService.UidGenerator 检测到时钟回拨:now=#{now} < last=#{last}" <>
              "(均为相对 base_time 的毫秒),自旋等待至严格的新毫秒后再发号。"
          )

          {wait_next_millis(base_time, last), 0}
      end

    if timestamp > @max_timestamp do
      # 41 位时间戳溢出(base_time 之后约 69.7 年):宁可崩溃也不静默截断产生碰撞 ID。
      raise "DataService.UidGenerator timestamp 溢出 41 位(#{timestamp} > #{@max_timestamp})," <>
              "需调整 base_time 或扩展位宽。"
    end

    uid = <<0::1, timestamp::@time_bits, state.service_id::@service_bits, sequence::@sequence_bits>>

    {:reply, uid, %{state | last_timestamp: timestamp, sequence: sequence}}
  end

  @doc """
  纯决策函数:给定本次取到的相对时间戳 `now`、上次的 `last_timestamp` / `last_sequence`
  与序列上限 `max_sequence`,决定本次应使用的时间戳与序列号,或需要执行的副作用。

  - `{:ok, timestamp, sequence}`:可直接发号。
  - `{:wait_next, last_timestamp}`:同毫秒序列耗尽,需自旋到下一毫秒(序列重置为 0)。
  - `{:clock_backwards, last_timestamp}`:检测到时钟回拨,需告警并自旋至新毫秒。
  """
  @doc since: "2026-06-04"
  def decide(now, last_timestamp, last_sequence, max_sequence) do
    cond do
      now > last_timestamp ->
        # 新毫秒(含首次 last_timestamp = -1):序列重置为 0。
        {:ok, now, 0}

      now == last_timestamp and last_sequence < max_sequence ->
        # 同一毫秒:序列递增。
        {:ok, now, last_sequence + 1}

      now == last_timestamp ->
        # 同一毫秒且序列已达上限:需要自旋到下一毫秒。
        {:wait_next, last_timestamp}

      true ->
        # now < last_timestamp:时钟回拨。
        {:clock_backwards, last_timestamp}
    end
  end

  defp current_timestamp(base_time) do
    (DateTime.utc_now() |> DateTime.to_unix(:millisecond)) - base_time
  end

  # 自旋直到相对时间戳严格大于 last_timestamp。序列耗尽与时钟回拨共用此路径。
  defp wait_next_millis(base_time, last_timestamp) do
    ts = current_timestamp(base_time)
    if ts > last_timestamp, do: ts, else: wait_next_millis(base_time, last_timestamp)
  end
end
