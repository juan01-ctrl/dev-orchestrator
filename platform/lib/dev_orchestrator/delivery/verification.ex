defmodule DevOrchestrator.Delivery.Verification do
  alias DevOrchestrator.Connections
  alias DevOrchestrator.Connections.GitHub

  def retryable?(reason), do: reason in [:provider_unavailable, :provider_rate_limit]

  def verify(run, result) do
    repository = run["snapshot"]["repository"]

    with true <- valid_url?(result["pr_url"], repository),
         connection when is_map(connection) <-
           Connections.for_project(run["organization_id"], run["project_id"], "github"),
         {:ok, token} <- Connections.credential(connection),
         number = result["pr_url"] |> String.split("/") |> List.last(),
         {:ok, pr} <- GitHub.api(:get, "/repos/#{repository}/pulls/#{number}", token) do
      validate_pr(run, result, pr)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_connection_required}
    end
  end

  def validate_pr(run, result, pr) do
    repository = run["snapshot"]["repository"]
    base = run["snapshot"]["base_branch"]
    branch = "task/" <> run["id"]

    valid =
      valid_url?(result["pr_url"], repository) and result["repository"] == repository and
        result["base_branch"] == base and result["branch"] == branch and
        is_binary(result["commit"]) and
        Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, result["commit"]) and
        pr["state"] == "open" and get_in(pr, ["head", "sha"]) == result["commit"] and
        get_in(pr, ["head", "ref"]) == branch and get_in(pr, ["base", "ref"]) == base and
        get_in(pr, ["head", "repo", "full_name"]) == repository and
        get_in(pr, ["base", "repo", "full_name"]) == repository

    if valid,
      do:
        {:ok,
         Map.merge(result, %{
           "outcome" => "pr_ready",
           "summary" =>
             result["summary"] ||
               "Changes are available in a verified open pull request for review."
         })},
      else: {:error, :unverified_pr}
  end

  defp valid_url?(url, repository) when is_binary(url) and is_binary(repository),
    do:
      Regex.match?(~r/\Ahttps:\/\/github\.com\/#{Regex.escape(repository)}\/pull\/[0-9]+\z/, url)

  defp valid_url?(_, _), do: false
end
