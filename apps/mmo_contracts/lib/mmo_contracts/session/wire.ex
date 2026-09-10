defmodule MmoContracts.Session.Wire do
  @moduledoc "M1 共用大端字段读写；仅网络解码入口把不合法字节转为错误。无连接或输入槽状态。"
  import Bitwise
  alias MmoContracts.Session

  @profile_fields ~w(radius half_height speed acceleration braking air_braking friction braking_friction_factor air_control gravity jump_speed step_height snap_distance skin slope_radians)a
  @profile Enum.map(@profile_fields, &{&1, :profile_f64}) ++ [fixed_hz: {:constant, :u16, 60}]
  @identity [session_epoch: :u64, scene_id: :u64, scene_epoch: :u64]
  @state [position: :vec3, velocity: :vec3, grounded: :bool, yaw: :u16]

  @doc "合法不可变消息编码为完整 M1 envelope；不含 stream purpose/长度。"
  def encode(domain, messages, %{__struct__: module} = value) do
    {kind, {^module, fields}} = Enum.find(messages, fn {_, {m, _}} -> m == module end)

    body = IO.iodata_to_binary(write_fields(fields, value))
    {:ok, <<255, 1::16, domain, kind, byte_size(body)::32, body::binary>>}
  end

  @doc "一次网络边界解析；未知版本/领域/kind、长度或字段错误统一拒绝，不返回部分值。"
  def decode(domain, bytes, messages, accept) do
    try do
      <<255, 1::16, ^domain, kind, size::32, body::binary-size(size)>> = bytes
      {module, fields} = Map.fetch!(messages, kind)
      {value, <<>>} = read_fields(fields, body, module)
      accept.(value)
      {:ok, value}
    rescue
      _ in [MatchError, FunctionClauseError, KeyError, ArgumentError, ErlangError] ->
        {:error, :invalid_m1_message}
    end
  end

  @doc "15 个 profile f64 按声明顺序导出；两种零都规范为 +0，末尾固定 60Hz。"
  def encode_profile(%Session.Profile{} = profile) do
    IO.iodata_to_binary(write(:profile, profile))
  end

  @doc "profile 与阻挡元数据的 SHA256 身份；第二参为原始 32 字节。"
  def profile_id(profile, <<blocking_hash::binary-size(32)>>) do
    :crypto.hash(:sha256, ["voxim-profile-v1\n", encode_profile(profile), blocking_hash])
  end

  defp write_fields(fields, value),
    do: Enum.map(fields, fn {key, type} -> write(type, Map.fetch!(value, key)) end)

  defp read_fields(fields, bytes, module) do
    {pairs, rest} =
      Enum.map_reduce(fields, bytes, fn {key, type}, input ->
        {value, tail} = read(type, input)
        {{key, value}, tail}
      end)

    {struct!(module, pairs), rest}
  end

  defp write(:u8, value), do: <<value::unsigned-big-8>>
  defp write(:u16, value), do: <<value::unsigned-big-16>>
  defp write(:u32, value), do: <<value::unsigned-big-32>>
  defp write(:u64, value), do: <<value::unsigned-big-64>>
  defp write(:i32, value), do: <<value::signed-big-32>>
  defp write(:f64, value), do: <<value::float-big-64>>
  defp write(:profile_f64, value), do: write(:f64, if(value == 0, do: 0.0, else: value))
  defp write(:axis, value), do: <<value::signed-big-16>>
  defp write(:bool, value), do: <<value>>
  defp write(:seq, value), do: write(:u32, value)
  defp write(:reason, value), do: write(:u16, value)
  defp write({:constant, type, expected}, expected), do: write(type, expected)
  defp write(:hash, <<value::binary-size(32)>>), do: value
  defp write(:utf8, value), do: [<<byte_size(value)::16>>, value]
  defp write(:bytes, value), do: [<<byte_size(value)::32>>, value]
  defp write(:coord, {x, y, z}), do: [write(:i32, x), write(:i32, y), write(:i32, z)]
  defp write(:vec3, {x, y, z}), do: [write(:f64, x), write(:f64, y), write(:f64, z)]
  defp write({:struct, _module, fields}, value), do: write_fields(fields, value)
  defp write(:identity, value), do: write_fields(@identity, value)
  defp write(:state, value), do: write_fields(@state, value)
  defp write(:profile, value), do: write_fields(@profile, value)
  defp write(:region, {coord, bytes}), do: [write(:coord, coord), write(:bytes, bytes)]

  defp write({:array, count_type, type}, values),
    do: [write(count_type, length(values)), Enum.map(values, &write(type, &1))]

  defp read(:u8, <<value::unsigned-big-8, rest::binary>>), do: {value, rest}
  defp read(:u16, <<value::unsigned-big-16, rest::binary>>), do: {value, rest}
  defp read(:u32, <<value::unsigned-big-32, rest::binary>>), do: {value, rest}
  defp read(:u64, <<value::unsigned-big-64, rest::binary>>), do: {value, rest}
  defp read(:i32, <<value::signed-big-32, rest::binary>>), do: {value, rest}

  defp read(:f64, <<bits::64, rest::binary>>)
       when (bits &&& 0x7FF0000000000000) != 0x7FF0000000000000 do
    <<value::float-big-64>> = <<bits::64>>
    {value, rest}
  end

  defp read(:profile_f64, <<bits::64, _::binary>> = bytes) when bits != 0x8000000000000000,
    do: read(:f64, bytes)

  defp read(:axis, <<value::signed-big-16, rest::binary>>) when value >= -32767, do: {value, rest}
  defp read(:bool, <<value, rest::binary>>) when value in [0, 1], do: {value, rest}
  defp read(:seq, <<value::32, rest::binary>>) when value > 0, do: {value, rest}
  defp read(:reason, <<value::16, rest::binary>>) when value in 1..12, do: {value, rest}

  defp read({:constant, type, expected}, bytes) do
    {^expected, rest} = read(type, bytes)
    {expected, rest}
  end

  defp read(:hash, <<value::binary-size(32), rest::binary>>), do: {value, rest}

  defp read(:utf8, <<size::16, value::binary-size(size), rest::binary>>) do
    true = String.valid?(value)
    {value, rest}
  end

  defp read(:bytes, <<size::32, value::binary-size(size), rest::binary>>), do: {value, rest}

  defp read(:coord, <<x::signed-big-32, y::signed-big-32, z::signed-big-32, rest::binary>>),
    do: {{x, y, z}, rest}

  defp read(:vec3, bytes) do
    {x, bytes} = read(:f64, bytes)
    {y, bytes} = read(:f64, bytes)
    {z, bytes} = read(:f64, bytes)
    {{x, y, z}, bytes}
  end

  defp read({:struct, module, fields}, bytes), do: read_fields(fields, bytes, module)
  defp read(:identity, bytes), do: read_fields(@identity, bytes, Session.Identity)
  defp read(:state, bytes), do: read_fields(@state, bytes, Session.State)
  defp read(:profile, bytes), do: read_fields(@profile, bytes, Session.Profile)

  defp read(:region, bytes) do
    {coord, bytes} = read(:coord, bytes)
    {payload, rest} = read(:bytes, bytes)
    {{coord, payload}, rest}
  end

  defp read({:array, count_type, type}, bytes) do
    {count, bytes} = read(count_type, bytes)
    read_array(count, type, bytes, [])
  end

  defp read_array(0, _type, bytes, acc), do: {Enum.reverse(acc), bytes}

  defp read_array(count, type, bytes, acc) do
    {value, rest} = read(type, bytes)
    read_array(count - 1, type, rest, [value | acc])
  end

  @doc "?????????/????????????????"
  def ordered!(values),
    do: true = Enum.chunk_every(values, 2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)
end
