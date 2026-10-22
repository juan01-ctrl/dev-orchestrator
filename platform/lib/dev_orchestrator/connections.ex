defmodule DevOrchestrator.Connections do
  alias DevOrchestrator.{Accounts, Store, Projects}
  alias DevOrchestrator.Connections.{OAuth, SecretBox, GitHub, Slack}

  def list(scope) do
    Store.rows(
      "SELECT id,provider,label,external_id,revoked_at FROM connections WHERE organization_id=$1 ORDER BY created_at",
      [scope.organization_id]
    )
  end

  def start_github_installation(scope, project_id, session) do
    cond do
      not Accounts.owner?(scope) ->
        {:error, :forbidden}

      not OAuth.configured?("github") ->
        {:error, :not_configured}

      not (is_binary(session) and session != "") ->
        {:error, :invalid_state}

      true ->
        with {:ok, project} <- Projects.get_project(scope, project_id) do
          state = Store.token()

          with {:ok, url} <- GitHub.installation_url(state) do
            Store.exec(
              "INSERT INTO github_install_states(hash,organization_id,user_id,project_id,repository,session_hash,expires_at) VALUES($1,$2,$3,$4,$5,$6,now()+interval '10 minutes')",
              [
                Store.digest(state),
                scope.organization_id,
                scope.user_id,
                project_id,
                project.repository,
                Store.digest(session)
              ]
            )

            {:ok, url}
          end
        end
    end
  end

  def complete_github_installation(scope, state, installation_id, session) do
    with {:ok, pending} <- consume_github_install_state(scope, state, session),
         {:ok, project} <- Projects.get_project(scope, pending["project_id"]),
         true <- project.repository == pending["repository"] do
      case GitHub.verify_installation(installation_id, pending["repository"]) do
        {:ok, installation} ->
          Store.exec(
            "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account,verified_at) VALUES($1,$2,$3,$4,$5,now()) ON CONFLICT(organization_id,project_id) DO UPDATE SET repository=EXCLUDED.repository,installation_id=EXCLUDED.installation_id,account=EXCLUDED.account,verified_at=now()",
            [
              scope.organization_id,
              pending["project_id"],
              pending["repository"],
              installation.installation_id,
              installation.account
            ]
          )

          {:ok, pending["project_id"]}

        {:error, :installation_required} = error ->
          Store.exec(
            "DELETE FROM github_app_installations WHERE organization_id=$1 AND project_id=$2 AND repository=$3",
            [scope.organization_id, pending["project_id"], pending["repository"]]
          )

          error

        error ->
          error
      end
    else
      false -> {:error, :repository_changed}
      {:error, _} = error -> error
      _ -> {:error, :invalid_state}
    end
  end

  def github_status(scope, project_id) do
    with {:ok, project} <- Projects.get_project(scope, project_id),
         %{"installation_id" => _} = installation <-
           Store.one(
             "SELECT installation_id FROM github_app_installations WHERE organization_id=$1 AND project_id=$2 AND repository=$3",
             [scope.organization_id, project.id, project.repository]
           ) do
      connection = for_project(scope.organization_id, project_id, "github")

      if connection && connection["external_id"] == to_string(installation["installation_id"]),
        do: :connected,
        else: :installed
    else
      _ -> :not_installed
    end
  end

  def start_oauth(scope, provider, project_id, session) do
    with true <- Accounts.owner?(scope),
         {:ok, _} <- Projects.get_project(scope, project_id),
         true <- OAuth.configured?(provider) do
      token = Store.token()

      Store.exec(
        "INSERT INTO oauth_states VALUES($1,$2,$3,$4,$5,$6,now()+interval '10 minutes')",
        [
          Store.digest(token),
          scope.organization_id,
          scope.user_id,
          project_id,
          provider,
          Store.digest(session)
        ]
      )

      {:ok, OAuth.authorize_url(provider, token)}
    else
      false -> {:error, if(Accounts.owner?(scope), do: :not_configured, else: :forbidden)}
      error -> error
    end
  end

  def consume_state(scope, provider, token, session)
      when is_binary(token) and is_binary(session) do
    if Accounts.owner?(scope) do
      case Store.one(
             "DELETE FROM oauth_states WHERE hash=$1 AND organization_id=$2 AND user_id=$3 AND provider=$4 AND session_hash=$5 AND expires_at>now() RETURNING project_id",
             [
               Store.digest(token),
               scope.organization_id,
               scope.user_id,
               provider,
               Store.digest(session)
             ]
           ) do
        nil -> {:error, :invalid_state}
        row -> {:ok, row["project_id"]}
      end
    else
      {:error, :forbidden}
    end
  end

  def consume_state(_, _, _, _), do: {:error, :invalid_state}

  defp consume_github_install_state(scope, state, session)
       when is_binary(state) and is_binary(session) and session != "" do
    if Accounts.owner?(scope) do
      case Store.one(
             "DELETE FROM github_install_states WHERE hash=$1 AND organization_id=$2 AND user_id=$3 AND session_hash=$4 AND expires_at>now() RETURNING organization_id,user_id,project_id,repository",
             [
               Store.digest(state),
               scope.organization_id,
               scope.user_id,
               Store.digest(session)
             ]
           ) do
        nil -> {:error, :invalid_state}
        row -> {:ok, row}
      end
    else
      {:error, :forbidden}
    end
  end

  defp consume_github_install_state(_, _, _), do: {:error, :invalid_state}

  def complete_oauth(scope, provider, state, code, session) do
    with {:ok, project_id} <- consume_state(scope, provider, state, session),
         {:ok, project} <- Projects.get_project(scope, project_id),
         {:ok, body} <- OAuth.exchange(provider, code),
         {:ok, secret, external_id, label} <- identity(provider, body, project) do
      Store.transaction(fn ->
        id = Store.id()

        Store.exec(
          "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,$3,$4,$5,$6)",
          [
            id,
            scope.organization_id,
            provider,
            label,
            seal(secret, scope.organization_id),
            external_id
          ]
        )

        Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
          scope.organization_id,
          project_id,
          id
        ])

        project_id
      end)
    end
  end

  def disconnect(scope, id) do
    if Accounts.owner?(scope) do
      Store.exec(
        "UPDATE connections SET revoked_at=now(),secret=$3 WHERE id=$1 AND organization_id=$2",
        [id, scope.organization_id, <<>>]
      )

      :ok
    else
      {:error, :forbidden}
    end
  end

  def for_project(organization_id, project_id, provider) do
    Store.one(
      "SELECT c.* FROM connections c JOIN connection_grants g ON g.connection_id=c.id AND g.organization_id=c.organization_id WHERE g.project_id=$1 AND g.organization_id=$2 AND c.provider=$3 AND c.revoked_at IS NULL ORDER BY c.created_at DESC LIMIT 1",
      [project_id, organization_id, provider]
    )
  end

  def slack_channels(scope, project_id) do
    with {:ok, _project} <- Projects.get_project(scope, project_id),
         connection when is_map(connection) <-
           for_project(scope.organization_id, project_id, "slack"),
         {:ok, token} <- credential(connection),
         {:ok, channels} <- Slack.channels(token) do
      {:ok, channels}
    else
      nil -> {:error, :not_connected}
      {:error, _} = error -> error
      _ -> {:error, :not_connected}
    end
  end

  def credential(row) do
    Store.transaction(fn ->
      current =
        Store.one(
          "SELECT * FROM connections WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL FOR UPDATE",
          [row["id"], row["organization_id"]]
        ) || Store.halt(:connection_unavailable)

      with {:ok, plaintext} <-
             SecretBox.open(current["secret"], current["organization_id"], key()),
           {:ok, secret} <- Jason.decode(plaintext) do
        secret = refresh_if_expired(current, secret)

        if current["provider"] == "github" do
          case GitHub.token(secret) do
            {:ok, token} -> token
            {:error, reason} -> Store.halt(reason)
          end
        else
          secret["access_token"] || Store.halt(:invalid_secret)
        end
      else
        _ -> Store.halt(:invalid_secret)
      end
    end)
  end

  defp refresh_if_expired(row, %{"expires_at" => expires} = secret) when is_integer(expires) do
    if expires <= System.system_time(:second) + 60 do
      if is_binary(secret["refresh_token"]) do
        case OAuth.refresh(row["provider"], secret["refresh_token"]) do
          {:ok, updated} ->
            merged = Map.merge(secret, updated)

            Store.exec("UPDATE connections SET secret=$2 WHERE id=$1", [
              row["id"],
              seal(merged, row["organization_id"])
            ])

            merged

          {:error, reason} ->
            Store.halt(reason)
        end
      else
        Store.halt(:provider_authentication)
      end
    else
      secret
    end
  end

  defp refresh_if_expired(_, secret), do: secret

  defp identity("github", body, project) do
    with {:ok, installation} <- GitHub.bind_installation(body["access_token"], project.repository),
         do:
           {:ok, installation, to_string(installation["installation_id"]),
            "GitHub · " <> installation["account"]}
  end

  defp identity("slack", %{"team" => %{"id" => id, "name" => name}} = body, _),
    do: {:ok, body, id, "Slack · " <> name}

  defp identity("linear", body, _) do
    with {:ok, %{"data" => %{"organization" => %{"id" => id, "name" => name}}}} <-
           DevOrchestrator.Connections.Linear.query(
             body["access_token"],
             "query { organization { id name } }",
             %{}
           ),
         do: {:ok, body, id, "Linear · " <> name}
  end

  defp identity(_, _, _), do: {:error, :invalid_provider_response}
  defp seal(secret, org), do: SecretBox.seal(Jason.encode!(secret), org, key())
  defp key, do: Application.fetch_env!(:dev_orchestrator, :encryption_key)
end
