defmodule DataService.Password do
  @moduledoc """
  Password hashing helpers backed by OTP crypto primitives.
  """

  @digest :sha256
  @iterations 120_000
  @key_length 32
  @salt_bytes 16

  @spec hash_password(binary()) :: {:ok, binary(), binary()}
  def hash_password(password) when is_binary(password) do
    salt = generate_salt()
    {:ok, hash_password(password, salt), salt}
  end

  @spec hash_password(binary(), binary()) :: binary()
  def hash_password(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(@digest, password, salt, @iterations, @key_length)
    |> Base.url_encode64(padding: false)
  end

  @spec verify_password(binary(), binary(), binary()) :: boolean()
  def verify_password(password, expected_hash, salt)
      when is_binary(password) and is_binary(expected_hash) and is_binary(salt) do
    derived_hash = hash_password(password, salt)
    secure_compare(derived_hash, expected_hash)
  end

  defp generate_salt do
    :crypto.strong_rand_bytes(@salt_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, acc ->
      Bitwise.bor(acc, Bitwise.bxor(left_byte, right_byte))
    end) == 0
  end

  defp secure_compare(_, _), do: false
end
