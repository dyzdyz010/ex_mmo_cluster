defmodule DataService.UidGenerator do
  use GenServer

  @time_bits 41
  @service_bits 10
  @sequence_bits 12

  ## API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

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

    {:ok, %{base_time: base_time, last_time: base_time, service_id: service_id, last_sequence: 0}}
  end

  @impl true
  def handle_call(
        :generate,
        _from,
        state = %{
          base_time: base_time,
          last_time: last_time,
          service_id: service_id,
          last_sequence: last_sequence
        }
      ) do
    timestamp = get_timestamp(last_time, base_time)
    sequence = get_sequence(timestamp, last_time, last_sequence)

    uid =
      <<0::1, (<<timestamp::@time_bits>>)::bitstring, <<service_id::@service_bits>>::bitstring,
        <<sequence::@sequence_bits>>::bitstring>>

    {:reply, uid, %{state | last_time: timestamp, last_sequence: sequence}}
  end

  defp get_timestamp(last_time, base_time) do
    now_time = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    timestamp = now_time - last_time

    if timestamp > 0 do
      now_time - base_time
    else
      # 时钟回拨
      get_timestamp(last_time, base_time)
    end
  end

  defp get_sequence(timestamp, last_time, last_sequence) do
    case timestamp > last_time do
      false -> 0
      true -> last_sequence + 1
    end
  end
end
