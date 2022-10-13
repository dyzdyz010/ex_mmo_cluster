defmodule SceneServer.Native.SortedSet do
  use Rustler, otp_app: :scene_server, crate: "sorted_set"

  alias SceneServer.Native.SortedSet.Types

  # When your NIF is loaded, it will override this function.
  def add(_a, _b), do: error()

  @spec new_item(integer(), pid(), {number(), number(), number()}) :: {atom(), Types.sorted_set()}
  def new_item(_cid, _pid, _coord), do: error()

  @spec get_item_raw(Types.item()) :: {atom(), Types.item()} | {atom(), any()}
  def get_item_raw(_item), do: error()

  @spec new_bucket() :: {atom(), Types.bucket()}
  def new_bucket(), do: error()

  @spec add_item_to_bucket(Types.bucket(), integer(), pid(), {number(), number(), number()}) :: {atom(), any()}
  def add_item_to_bucket(_bucket, _cid, _pid, _coord), do: error()

  @spec get_bucket_raw(Types.bucket()) :: {atom(), Types.bucket()} | {atom(), any()}
  def get_bucket_raw(_bucket), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
