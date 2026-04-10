defmodule AuthServer.AuthWorker do
  @moduledoc """
  Stateless auth token issuer/verifier shared by the web login surface and
  gate-side verification calls.

  Tokens are signed with Phoenix.Token so gate verification can remain a simple
  remote module call to the auth node instead of depending on a missing GenServer.
  """

  @token_salt "ingame-auth"
  @max_age 86_400

  @spec build_session_claims(binary(), keyword()) :: map()
  def build_session_claims(username, opts \\ []) when is_binary(username) do
    base_claims = %{
      "username" => username,
      "source" => Keyword.get(opts, :source, "ingame_login"),
      "session_id" => Keyword.get(opts, :session_id, generate_session_id())
    }

    base_claims
    |> maybe_put_claim("cid", Keyword.get(opts, :cid))
    |> maybe_put_claim("allowed_cids", normalize_allowed_cids(Keyword.get(opts, :allowed_cids)))
  end

  @spec issue_token(map()) :: String.t()
  def issue_token(claims) when is_map(claims) do
    Phoenix.Token.sign(AuthServerWeb.Endpoint, @token_salt, claims)
  end

  @spec verify_token(term()) :: {:ok, map()} | {:error, :mismatch}
  def verify_token(token) when is_binary(token) do
    case Phoenix.Token.verify(AuthServerWeb.Endpoint, @token_salt, token, max_age: @max_age) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> {:error, :mismatch}
    end
  end

  def verify_token(_token), do: {:error, :mismatch}

  @spec validate_username(map(), term()) :: :ok | {:error, :username_mismatch}
  def validate_username(claims, username) when is_map(claims) and is_binary(username) do
    case claim_username(claims) do
      ^username -> :ok
      _ -> {:error, :username_mismatch}
    end
  end

  def validate_username(_claims, _username), do: {:error, :username_mismatch}

  @spec validate_cid(map(), term()) :: :ok | {:error, :cid_mismatch}
  def validate_cid(claims, cid) when is_map(claims) and is_integer(cid) do
    cond do
      (claim_cid = claim_cid(claims)) != nil ->
        if claim_cid == cid, do: :ok, else: {:error, :cid_mismatch}

      (allowed_cids = claim_allowed_cids(claims)) != nil ->
        if cid in allowed_cids, do: :ok, else: {:error, :cid_mismatch}

      true ->
        :ok
    end
  end

  def validate_cid(_claims, _cid), do: {:error, :cid_mismatch}

  defp claim_username(claims), do: Map.get(claims, "username") || Map.get(claims, :username)

  defp claim_cid(claims) do
    claims
    |> (fn map -> Map.get(map, "cid") || Map.get(map, :cid) end).()
    |> normalize_integer()
  end

  defp claim_allowed_cids(claims) do
    claims
    |> (fn map -> Map.get(map, "allowed_cids") || Map.get(map, :allowed_cids) end).()
    |> normalize_allowed_cids()
  end

  defp maybe_put_claim(claims, _key, nil), do: claims

  defp maybe_put_claim(claims, _key, []), do: claims

  defp maybe_put_claim(claims, key, value), do: Map.put(claims, key, value)

  defp normalize_allowed_cids(nil), do: nil

  defp normalize_allowed_cids(values) when is_list(values) do
    values
    |> Enum.map(&normalize_integer/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      normalized -> normalized
    end
  end

  defp normalize_allowed_cids(value) do
    case normalize_integer(value) do
      nil -> nil
      normalized -> [normalized]
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {normalized, ""} -> normalized
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
