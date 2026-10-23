defmodule DevOrchestrator.Connections.GitHub do
  alias DevOrchestrator.Connections.{HTTP, OAuth}

  @token_permissions %{
    checkout: %{contents: "read"},
    publish: %{contents: "write", pull_requests: "write"}
  }

  def installation_url(state) when is_binary(state) do
    slug = OAuth.config("github")[:app_slug]

    if is_binary(slug) and Regex.match?(~r/\A[a-zA-Z0-9-]+\z/, slug) do
      {:ok,
       "https://github.com/apps/#{slug}/installations/new?" <>
         URI.encode_query(%{state: state})}
    else
      {:error, :not_configured}
    end
  end

  def installation_url(_), do: {:error, :invalid_state}

  def verify_installation(installation_id, repository)
      when is_binary(installation_id) and is_binary(repository) do
    with [account, repo] <- String.split(repository, "/", parts: 2),
         true <- account != "" and repo != "",
         {id, ""} when id > 0 <- Integer.parse(installation_id),
         {:ok, jwt} <- jwt(),
         {:ok, %{"token" => token}} when is_binary(token) and token != "" <-
           api(:post, "/app/installations/#{id}/access_tokens", jwt, json: %{}),
         {:ok, %{"total_count" => total, "repositories" => repositories}}
         when is_integer(total) and is_list(repositories) <-
           api(:get, "/installation/repositories?per_page=100", token),
         true <- total <= 100,
         true <- Enum.any?(repositories, &(&1["full_name"] == repository)) do
      {:ok, %{installation_id: id, account: account}}
    else
      false -> {:error, :installation_required}
      nil -> {:error, :installation_required}
      {:error, :provider_rejected} -> {:error, :installation_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  rescue
    _ -> {:error, :invalid_provider_response}
  end

  def verify_installation(_, _), do: {:error, :invalid_installation}

  def bind_installation(user_token, repository) do
    with {:ok, %{"installations" => installations}} <-
           api(:get, "/user/installations?per_page=100", user_token) do
      Enum.reduce_while(installations, {:error, :installation_required}, fn installation, _ ->
        case api(
               :get,
               "/user/installations/#{installation["id"]}/repositories?per_page=100",
               user_token
             ) do
          {:ok, %{"repositories" => repos, "total_count" => total}} when total <= 100 ->
            if Enum.any?(repos, &(&1["full_name"] == repository)),
              do:
                {:halt,
                 {:ok,
                  %{
                    "installation_id" => installation["id"],
                    "account" => installation["account"]["login"]
                  }}},
              else: {:cont, {:error, :installation_required}}

          _ ->
            {:cont, {:error, :installation_required}}
        end
      end)
    end
  end

  def token(%{"installation_id" => id}) when is_integer(id) and id > 0 do
    with {:ok, jwt} <- jwt(),
         {:ok, %{"token" => token}} <-
           api(:post, "/app/installations/#{id}/access_tokens", jwt, json: %{}) do
      {:ok, token}
    end
  end

  def installation_token(installation_id, repository, purpose)
      when is_integer(installation_id) and installation_id > 0 and is_binary(repository) and
             is_map_key(@token_permissions, purpose) do
    if DevOrchestrator.Policy.valid_repository?(repository) do
      [_, repository_name] = String.split(repository, "/", parts: 2)

      with {:ok, jwt} <- jwt(),
           {:ok, %{"token" => token, "expires_at" => expires_at}}
           when is_binary(token) and token != "" and is_binary(expires_at) <-
             api(:post, "/app/installations/#{installation_id}/access_tokens", jwt,
               json: %{
                 repositories: [repository_name],
                 permissions: Map.fetch!(@token_permissions, purpose)
               }
             ) do
        {:ok, %{token: token, expires_at: expires_at}}
      else
        {:error, reason} when reason in [:provider_authentication, :provider_rate_limit] ->
          {:error, reason}

        {:error, _} ->
          {:error, :provider_rejected}

        _ ->
          {:error, :invalid_provider_response}
      end
    else
      {:error, :invalid_repository}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  end

  def installation_token(_, _, _), do: {:error, :invalid_request}

  def api(method, path, token, opts \\ []) do
    HTTP.request(
      method,
      "https://api.github.com" <> path,
      [
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "dev-orchestrator"}
        ]
      ] ++ opts
    )
  end

  defp jwt do
    config = OAuth.config("github")
    now = System.system_time(:second)

    with {:ok, pem} <- File.read(config[:private_key_path] || ""),
         [entry] <- :public_key.pem_decode(pem) do
      key = :public_key.pem_entry_decode(entry)

      message =
        b64(Jason.encode!(%{alg: "RS256", typ: "JWT"})) <>
          "." <> b64(Jason.encode!(%{iat: now - 60, exp: now + 540, iss: config[:app_id]}))

      {:ok, message <> "." <> b64(:public_key.sign(message, :sha256, key))}
    else
      _ -> {:error, :not_configured}
    end
  rescue
    _ -> {:error, :not_configured}
  end

  defp b64(value), do: Base.url_encode64(value, padding: false)
end
