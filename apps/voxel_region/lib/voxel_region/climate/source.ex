defmodule VoxelRegion.Climate.Source do
  @moduledoc """
  已接纳世界生成描述符与显式作者气候参数构成的不可变气候源。

  构造时核对实际生成内核身份并冻结摘要；取样不读取Application.env、文件、材料或当前页面。
  本类型只负责新源，不迁移既有世界的背景初能量、热账或有限预算。
  """
  alias VoxelRegion.Native

  @schema "worldgen-temperature-v1"
  @enforce_keys [:identity, :content_version, :kernel_identity, :worldgen_config, :kelvin_config]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identity: String.t(), content_version: non_neg_integer(), kernel_identity: String.t(),
          worldgen_config: Native.config(), kelvin_config: {float(), float(), integer(), float()}
        }

  @doc "由已接纳世界描述符与显式作者参数构造新源；内核身份不匹配显式拒绝。"
  @spec new(map(), map()) :: {:ok, t()} | {:error, atom()}
  def new(%{content_version: cv, kernel_identity: kernel, config: config}, params)
      when is_integer(cv) and cv >= 0 and is_binary(kernel) and is_tuple(config) and tuple_size(config) == 8 do
    with true <- kernel == Native.kernel_identity() || {:error, :climate_kernel_mismatch},
         {:ok, kelvin} <- author_parameters(params) do
      identity = :crypto.hash(:sha256, :erlang.term_to_binary({@schema, cv, kernel, config, kelvin}, [:deterministic]))
        |> Base.encode16(case: :lower)
      {:ok, %__MODULE__{identity: identity, content_version: cv, kernel_identity: kernel,
        worldgen_config: config, kelvin_config: kelvin}}
    end
  end

  def new(_, _), do: {:error, :invalid_climate_descriptor}

  defp author_parameters(%{"cold_kelvin" => cold, "warm_kelvin" => warm,
      "sample_height_offset_m" => offset, "wind_mps" => wind})
      when is_number(cold) and is_number(warm) and is_integer(offset) and offset == 1 and is_number(wind) do
    try do
      cold = cold * 1.0
      warm = warm * 1.0
      wind = wind * 1.0
      if cold > 0 and warm > cold and wind >= 0,
        do: {:ok, {cold, warm, offset, wind}},
        else: {:error, :invalid_climate_parameters}
    rescue
      ArithmeticError -> {:error, :invalid_climate_parameters}
    end
  end

  defp author_parameters(_), do: {:error, :invalid_climate_parameters}
end
