defmodule AuthServer.AuthWorker do
  @moduledoc """
  Stateless auth claim builder and `Phoenix.Token` boundary for in-game login.

  The web controller uses this module to build the signed payload that the game
  client will later present to the gate server. The gate side uses the same
  module to verify the token remotely, so the auth node does not need a local
  GenServer or process registry entry.

  ## Flow

      browser form params
           ↓
      build_session_claims/2
           ↓
      issue_token/1
           ↓
      /ingame/login_success redirect

      gate socket
           ↓
      verify_token/1
           ↓
      validate_username/2
      validate_cid/2

  ## Claim fields

  - `"username"` is required and identifies the player
  - `"source"` records where the token came from, defaulting to `"ingame_login"`
  - `"session_id"` is a short url-safe identifier unless explicitly supplied
  - `"cid"` pins the token to one exact character ID when present
  - `"allowed_cids"` acts as a fallback allow-list when an exact cid is absent
  """

  @token_salt "ingame-auth"
  @max_age 86_400

  @spec build_session_claims(binary(), keyword()) :: map()
  @doc """
  Build the unsigned claim map used by the in-game login flow.

  `opts` accepts `:source`, `:session_id`, `:account_id`, `:cid`, and `:allowed_cids`.
  `:allowed_cids` may be a single value or a list; values are normalized to
  integers when possible and empty entries are discarded.
  """
  def build_session_claims(username, opts \\ []) when is_binary(username) do
    base_claims = %{
      "username" => username,
      "source" => Keyword.get(opts, :source, "ingame_login"),
      "session_id" => Keyword.get(opts, :session_id, generate_session_id())
    }

    base_claims
    |> maybe_put_claim("account_id", normalize_integer(Keyword.get(opts, :account_id)))
    |> maybe_put_claim("cid", Keyword.get(opts, :cid))
    |> maybe_put_claim("allowed_cids", normalize_allowed_cids(Keyword.get(opts, :allowed_cids)))
  end

  @spec issue_token(map()) :: String.t()
  @doc "Signs a claim map with `Phoenix.Token` using the auth endpoint."
  def issue_token(claims) when is_map(claims) do
    Phoenix.Token.sign(AuthServerWeb.Endpoint, @token_salt, claims)
  end

  @spec verify_token(term()) :: {:ok, map()} | {:error, :mismatch}
  @doc "Verifies a signed token and returns the claim map, or `{:error, :mismatch}`."
  def verify_token(token) when is_binary(token) do
    case Phoenix.Token.verify(AuthServerWeb.Endpoint, @token_salt, token, max_age: @max_age) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> {:error, :mismatch}
    end
  end

  def verify_token(_token), do: {:error, :mismatch}

  @spec validate_username(map(), term()) :: :ok | {:error, :username_mismatch}
  @doc "Confirms that the claims' username matches the presented one."
  def validate_username(claims, username) when is_map(claims) and is_binary(username) do
    case claim_username(claims) do
      ^username -> :ok
      _ -> {:error, :username_mismatch}
    end
  end

  def validate_username(_claims, _username), do: {:error, :username_mismatch}

  @spec validate_cid(map(), term()) :: :ok | {:error, :cid_mismatch}
  @doc "Confirms that the requested character ID is allowed by the claims."
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

  @spec authorize_character(map(), integer()) ::
          :ok | {:error, :account_not_found | :cid_mismatch | :data_service_unavailable}
  @doc "Confirms that the authenticated identity owns the requested character."
  def authorize_character(claims, cid) when is_map(claims) and is_integer(cid) do
    case fetch_authorized_character(claims, cid) do
      {:ok, _character} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_character(_claims, _cid), do: {:error, :account_not_found}

  @spec fetch_authorized_character(map(), integer()) ::
          {:ok, struct()}
          | {:error, :account_not_found | :cid_mismatch | :data_service_unavailable}
  @doc "Returns the character struct that the authenticated identity may enter."
  def fetch_authorized_character(claims, cid) when is_map(claims) and is_integer(cid) do
    with {:ok, account_id} <- resolve_account_id(claims),
         {:ok, character} <- AuthServer.Accounts.character_owned_by_account?(account_id, cid),
         false <- is_nil(character) do
      {:ok, character}
    else
      {:error, :invalid_account} -> {:error, :account_not_found}
      {:error, :data_service_unavailable} -> {:error, :data_service_unavailable}
      {:ok, nil} -> {:error, :cid_mismatch}
      true -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :account_not_found}
    end
  end

  def fetch_authorized_character(_claims, _cid), do: {:error, :account_not_found}

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

  defp claim_account_id(claims) do
    claims
    |> (fn map -> Map.get(map, "account_id") || Map.get(map, :account_id) end).()
    |> normalize_integer()
  end

  defp resolve_account_id(claims) do
    cond do
      (account_id = claim_account_id(claims)) != nil ->
        {:ok, account_id}

      (username = claim_username(claims)) != nil ->
        case AuthServer.Accounts.find_by_username(username) do
          {:ok, %{id: account_id}} -> {:ok, account_id}
          {:ok, nil} -> {:error, :account_not_found}
          {:error, :data_service_unavailable} -> {:error, :data_service_unavailable}
          {:error, _reason} -> {:error, :account_not_found}
        end

      true ->
        {:error, :account_not_found}
    end
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
