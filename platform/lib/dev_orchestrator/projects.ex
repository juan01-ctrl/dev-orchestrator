defmodule DevOrchestrator.Projects do
  alias DevOrchestrator.{Store, Policy, ExecutionPolicy}
  alias DevOrchestrator.Accounts.Scope

  def list(%Scope{} = scope),
    do:
      Store.rows("SELECT * FROM projects WHERE organization_id=$1 ORDER BY created_at", [
        scope.organization_id
      ])
      |> Enum.map(&public/1)

  def get_project(%Scope{} = scope, id) do
    case Store.one("SELECT * FROM projects WHERE id=$1 AND organization_id=$2", [
           id,
           scope.organization_id
         ]) do
      nil -> {:error, :not_found}
      row -> {:ok, public(row)}
    end
  end

  def create_project(%Scope{} = scope, attrs) do
    attrs = Map.merge(%{"base_branch" => "main", "concurrency" => 1, "instructions" => ""}, attrs)

    if valid?(attrs) do
      row =
        Store.one(
          "INSERT INTO projects(id,organization_id,name,repository,base_branch,instructions,concurrency,model) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *",
          [
            Store.id(),
            scope.organization_id,
            attrs["name"],
            attrs["repository"],
            attrs["base_branch"],
            attrs["instructions"],
            integer(attrs["concurrency"]),
            blank(attrs["model"])
          ]
        )

      {:ok, public(row)}
    else
      {:error, :invalid_project}
    end
  end

  def update_project(%Scope{} = scope, id, attrs) do
    with {:ok, project} <- get_project(scope, id) do
      merged =
        Map.merge(
          project.data,
          Map.take(
            attrs,
            ~w(name repository base_branch instructions concurrency model linear_team linear_project active_states review_state slack_channel)
          )
        )

      if valid?(merged) do
        row =
          Store.one(
            "UPDATE projects SET name=$3,repository=$4,base_branch=$5,instructions=$6,concurrency=$7,version=version+1,model=$8,linear_team=$9,linear_project=$10,review_state=$11,slack_channel=$12,active_states=$13 WHERE id=$1 AND organization_id=$2 RETURNING *",
            [
              id,
              scope.organization_id,
              merged["name"],
              merged["repository"],
              merged["base_branch"],
              merged["instructions"],
              integer(merged["concurrency"]),
              blank(merged["model"]),
              blank(merged["linear_team"]),
              blank(merged["linear_project"]),
              merged["review_state"] || "In Review",
              blank(merged["slack_channel"]),
              merged["active_states"] || ["Todo", "In Progress"]
            ]
          )

        if Enum.any?(~w(linear_team linear_project active_states), fn key ->
             project.data[key] != row[key]
           end) do
          Store.exec(
            "DELETE FROM linear_reconciliation_cursors WHERE connection_id IN (SELECT connection_id FROM connection_grants WHERE organization_id=$1 AND project_id=$2)",
            [scope.organization_id, id]
          )
        end

        {:ok, public(row)}
      else
        {:error, :invalid_project}
      end
    end
  end

  def snapshot(project),
    do:
      Map.take(
        project.data,
        ~w(id name repository base_branch instructions concurrency version model linear_team linear_project active_states review_state slack_channel)
      )

  def validate_instructions(filename, bytes) when is_binary(filename) and is_binary(bytes) do
    cond do
      filename != "instructions.md" -> {:error, :invalid_filename}
      byte_size(bytes) > 32_000 -> {:error, :too_large}
      not String.valid?(bytes) -> {:error, :invalid_encoding}
      String.trim(bytes) == "" -> {:error, :empty}
      true -> {:ok, bytes}
    end
  end

  def validate_instructions(_, _), do: {:error, :invalid_file}

  def default_instructions do
    Application.app_dir(:dev_orchestrator, "priv/static/templates/instructions.md")
    |> File.read!()
  end

  defp public(row),
    do: %{
      id: row["id"],
      name: row["name"],
      repository: row["repository"],
      base_branch: row["base_branch"],
      data: row
    }

  defp integer(n) when is_integer(n), do: n

  defp integer(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, ""} -> v
      _ -> 0
    end
  end

  defp integer(_), do: 0
  defp blank(""), do: nil
  defp blank(value), do: value

  defp valid?(a) do
    is_binary(a["name"]) and byte_size(a["name"]) in 1..100 and
      Policy.valid_repository?(a["repository"]) and Policy.valid_branch?(a["base_branch"]) and
      is_binary(a["instructions"]) and byte_size(a["instructions"]) <= 32_000 and
      integer(a["concurrency"]) in 1..10 and ExecutionPolicy.valid_override?(blank(a["model"])) and
      valid_states?(a["active_states"] || ["Todo", "In Progress"])
  end

  defp valid_states?(states) when is_list(states) and length(states) in 1..20,
    do: Enum.all?(states, &(is_binary(&1) and byte_size(&1) in 1..100))

  defp valid_states?(_), do: false
end
