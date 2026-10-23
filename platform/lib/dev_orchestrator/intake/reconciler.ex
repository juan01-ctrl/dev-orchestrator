defmodule DevOrchestrator.Intake.Reconciler do
  require Logger
  alias DevOrchestrator.{Store, Connections}
  alias DevOrchestrator.Connections.Linear

  @max_pages_per_tick 10

  def tick_all do
    Store.rows(
      "SELECT id FROM connections WHERE provider='linear' AND revoked_at IS NULL ORDER BY created_at"
    )
    |> Enum.each(fn %{"id" => id} ->
      case tick(id) do
        {:error, _} ->
          Logger.warning(
            "Linear reconciliation failed for a connected workspace; retrying from its saved cursor."
          )

        _ ->
          :ok
      end
    end)

    :ok
  end

  def tick(connection_id) when is_binary(connection_id) do
    started = System.monotonic_time()

    result =
      with connection when is_map(connection) <-
             Store.one(
               "SELECT * FROM connections WHERE id=$1 AND provider='linear' AND revoked_at IS NULL",
               [connection_id]
             ),
           {:ok, token} <- Connections.credential(connection),
           projects when projects != [] <- projects_for(connection_id),
           {:ok, cursor} <- load_cursor(connection_id) do
        teams = projects |> Enum.map(& &1["linear_team"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        if teams == [] do
          :ok
        else
          case fetch_pages(connection, token, projects, teams, cursor, 0) do
            :ok -> revalidate_tracked(token, projects, connection["id"])
            error -> error
          end
        end
      else
        nil -> :ok
        [] -> :ok
        {:error, _} = error -> error
        _ -> :ok
      end

    :telemetry.execute(
      [:dev_orchestrator, :linear, :reconciliation],
      %{
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      },
      %{outcome: if(match?({:error, _}, result), do: "failed", else: "completed")}
    )

    result
  end

  defp projects_for(connection_id) do
    Store.rows(
      "SELECT DISTINCT p.* FROM projects p JOIN connection_grants g ON g.project_id=p.id AND g.organization_id=p.organization_id WHERE g.connection_id=$1 ORDER BY p.created_at",
      [connection_id]
    )
  end

  defp load_cursor(connection_id) do
    case Store.one("SELECT * FROM linear_reconciliation_cursors WHERE connection_id=$1", [
           connection_id
         ]) do
      nil -> {:ok, %{updated_at: nil, page: nil}}
      row -> {:ok, %{updated_at: row["updated_at_cursor"], page: row["page_cursor"]}}
    end
  end

  defp fetch_pages(_connection, _token, _projects, _teams, _cursor, page_count)
       when page_count >= @max_pages_per_tick,
       do: :ok

  defp fetch_pages(connection, token, projects, teams, cursor, page_count) do
    filter = %{"team" => %{"id" => %{"in" => teams}}}

    filter =
      if cursor.updated_at,
        do: Map.put(filter, "updatedAt", %{"gte" => DateTime.to_iso8601(cursor.updated_at)}),
        else: filter

    query =
      "query($after:String,$filter:IssueFilter){issues(first:100,after:$after,filter:$filter,orderBy:updatedAt){nodes{id identifier title description url updatedAt state{name} team{id} project{id} attachments{nodes{url}}} pageInfo{hasNextPage endCursor}}}"

    case Linear.query(token, query, %{"after" => cursor.page, "filter" => filter}) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => issues, "pageInfo" => page_info}}}}
      when is_list(issues) ->
        Enum.each(issues, fn issue ->
          Enum.each(projects, fn project ->
            DevOrchestrator.Runs.Lifecycle.apply_issue(project, issue, %{
              "linear_connection_id" => connection["id"]
            })
          end)
        end)

        next_updated = Enum.reduce(issues, cursor.updated_at, &later(&1["updatedAt"], &2))
        next_page = if page_info["hasNextPage"], do: page_info["endCursor"], else: nil

        saved_updated = if next_page, do: cursor.updated_at, else: next_updated
        save_cursor(connection["id"], saved_updated, next_page, nil)

        if next_page do
          fetch_pages(
            connection,
            token,
            projects,
            teams,
            %{updated_at: cursor.updated_at, page: next_page},
            page_count + 1
          )
        else
          :ok
        end

      {:error, reason} ->
        save_cursor(connection["id"], cursor.updated_at, cursor.page, error_category(reason))
        {:error, reason}

      _ ->
        save_cursor(connection["id"], cursor.updated_at, cursor.page, "provider_rejected")
        {:error, :provider_rejected}
    end
  end

  defp revalidate_tracked(token, projects, connection_id) do
    tracked =
      Store.rows(
        "SELECT l.project_id,l.issue_id FROM linear_issue_lifecycles l JOIN projects p ON p.id=l.project_id WHERE l.is_active=true AND l.project_id=ANY($1::text[]) ORDER BY l.updated_at LIMIT 100",
        [Enum.map(projects, & &1["id"])]
      )

    ids = tracked |> Enum.map(& &1["issue_id"]) |> Enum.uniq()

    if ids == [] do
      :ok
    else
      query =
        "query($filter:IssueFilter){issues(first:100,filter:$filter){nodes{id identifier title description url state{name} team{id} project{id} attachments{nodes{url}}}}}"

      case Linear.query(token, query, %{"filter" => %{"id" => %{"in" => ids}}}) do
        {:ok, %{"data" => %{"issues" => %{"nodes" => issues}}}} when is_list(issues) ->
          visible = MapSet.new(issues, & &1["id"])
          projects_by_id = Map.new(projects, &{&1["id"], &1})

          Enum.each(issues, fn issue ->
            Enum.each(projects, fn project ->
              DevOrchestrator.Runs.Lifecycle.apply_issue(project, issue, %{
                "linear_connection_id" => connection_id
              })
            end)
          end)

          Enum.each(tracked, fn item ->
            if not MapSet.member?(visible, item["issue_id"]) do
              DevOrchestrator.Runs.Lifecycle.remove_issue(
                projects_by_id[item["project_id"]],
                item["issue_id"]
              )
            end
          end)

          :ok

        {:error, _} = error ->
          error

        _ ->
          {:error, :provider_rejected}
      end
    end
  end

  defp later(nil, cursor), do: cursor
  defp later(value, nil), do: parse_datetime(value)

  defp later(value, cursor) do
    case parse_datetime(value) do
      %DateTime{} = next -> if DateTime.compare(next, cursor) == :gt, do: next, else: cursor
      _ -> cursor
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp save_cursor(connection_id, updated_at, page, error) do
    Store.exec(
      "INSERT INTO linear_reconciliation_cursors(connection_id,updated_at_cursor,page_cursor,last_success_at,last_error_category) VALUES($1,$2,$3,CASE WHEN $4::text IS NULL THEN now() ELSE NULL END,$4) ON CONFLICT(connection_id) DO UPDATE SET updated_at_cursor=EXCLUDED.updated_at_cursor,page_cursor=EXCLUDED.page_cursor,last_success_at=CASE WHEN $4::text IS NULL THEN now() ELSE linear_reconciliation_cursors.last_success_at END,last_error_category=$4",
      [connection_id, updated_at, page, error]
    )
  end

  defp error_category(:provider_rate_limit), do: "provider_rate_limit"
  defp error_category(:provider_unavailable), do: "provider_unavailable"
  defp error_category(_), do: "provider_rejected"
end
