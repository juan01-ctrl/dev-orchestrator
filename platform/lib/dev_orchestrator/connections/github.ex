defmodule DevOrchestrator.Connections.GitHub do
  alias DevOrchestrator.Connections.{HTTP, OAuth}

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
