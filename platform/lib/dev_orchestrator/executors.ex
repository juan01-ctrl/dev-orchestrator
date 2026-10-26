defmodule DevOrchestrator.Executors do
  alias DevOrchestrator.{Accounts, Store, Projects, RateLimit, Runs}

  def list(scope),
    do:
      Store.rows(
        "SELECT id,name,last_seen_at,revoked_at,capabilities FROM executors WHERE organization_id=$1 ORDER BY created_at",
        [scope.organization_id]
      )

  def bindings(scope),
    do:
      Store.rows(
        "SELECT executor_id,project_id FROM executor_bindings WHERE organization_id=$1",
        [scope.organization_id]
      )

  def create_enrollment(scope) do
    with true <- Accounts.owner?(scope),
         :ok <- RateLimit.check({:enrollment, scope.organization_id}, 5) do
      code = Store.token()

      Store.exec("INSERT INTO enrollments VALUES($1,$2,now()+interval '10 minutes')", [
        Store.digest(code),
        scope.organization_id
      ])

      {:ok, code}
    else
      _ -> {:error, :forbidden}
    end
  end

  def enroll(code, %{"name" => name})
      when is_binary(code) and is_binary(name) and byte_size(name) in 1..100 do
    Store.transaction(fn ->
      enrollment =
        Store.one(
          "DELETE FROM enrollments WHERE hash=$1 AND expires_at>now() RETURNING organization_id",
          [Store.digest(code)]
        ) || Store.halt(:invalid_code)

      token = Store.token()
      id = Store.id()

      Store.exec(
        "INSERT INTO executors(id,organization_id,name,credential_hash) VALUES($1,$2,$3,$4)",
        [id, enrollment["organization_id"], name, Store.digest(token)]
      )

      %{token: token, executor: %{id: id, name: name}}
    end)
  end

  def enroll(_, _), do: {:error, :invalid_code}

  def authenticate(token) when is_binary(token) and byte_size(token) in 32..200 do
    case Store.one("SELECT * FROM executors WHERE credential_hash=$1 AND revoked_at IS NULL", [
           Store.digest(token)
         ]) do
      nil -> {:error, :unauthorized}
      row -> {:ok, row}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  def bind(scope, id, project_id) do
    with true <- Accounts.owner?(scope),
         {:ok, _} <- Projects.get_project(scope, project_id),
         row when is_map(row) <-
           Store.one(
             "SELECT id FROM executors WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL",
             [id, scope.organization_id]
           ) do
      Store.exec("INSERT INTO executor_bindings VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [
        scope.organization_id,
        id,
        project_id
      ])

      :ok
    else
      false -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  def revoke(scope, id) do
    if Accounts.owner?(scope) do
      case Store.transaction(fn ->
             executor =
               Store.one(
                 "UPDATE executors SET revoked_at=now() WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL RETURNING *",
                 [id, scope.organization_id]
               ) || Store.halt(:not_found)

             Runs.executor_revoked(executor)
           end) do
        {:ok, :ok} -> :ok
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def heartbeat(executor, capabilities) do
    safe =
      Map.take(
        capabilities,
        ~w(protocol codex_authenticated platform active_slots capacity workflow_version review_version)
      )

    Store.exec(
      "UPDATE executors SET last_seen_at=now(),capabilities=$2 WHERE id=$1 AND revoked_at IS NULL",
      [executor["id"], safe]
    )

    :telemetry.execute(
      [:dev_orchestrator, :executors, :heartbeat],
      %{count: 1},
      %{outcome: "accepted"}
    )

    :ok
  end
end
