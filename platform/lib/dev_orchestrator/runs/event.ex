defmodule DevOrchestrator.Runs.Event do
  @moduledoc "Bounded event data; raw provider/tool output is never persisted."
  @categories ~w(authentication_required local_policy_denied execution_failed publication_failed missing_context interrupted)

  def sanitize(run, "candidate", data) when is_map(data) do
    allowed = Map.take(data, ~w(repository branch base_branch commit pr_url))
    repo = get_in(run, ["snapshot", "repository"])

    valid =
      is_binary(repo) and allowed["repository"] == repo and
        allowed["branch"] == "task/" <> run["id"] and
        allowed["base_branch"] == get_in(run, ["snapshot", "base_branch"]) and
        is_binary(allowed["commit"]) and
        Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, allowed["commit"]) and
        is_binary(allowed["pr_url"]) and
        Regex.match?(
          ~r/\Ahttps:\/\/github\.com\/#{Regex.escape(repo)}\/pull\/[0-9]+\z/,
          allowed["pr_url"]
        )

    if valid, do: {:ok, allowed}, else: {:error, :invalid_event}
  end

  def sanitize(_, kind, data) when kind in ~w(failure blocked) and is_map(data) do
    category = if data["category"] in @categories, do: data["category"], else: "execution_failed"
    fingerprint = data["fingerprint"]

    fingerprint =
      if is_binary(fingerprint) and Regex.match?(~r/\A[a-f0-9]{64}\z/, fingerprint),
        do: fingerprint,
        else: :crypto.hash(:sha256, category) |> Base.encode16(case: :lower)

    occurrences = if data["occurrences"] in [1, 2, 3], do: data["occurrences"], else: 1
    {:ok, %{"category" => category, "fingerprint" => fingerprint, "occurrences" => occurrences}}
  end

  def sanitize(_, kind, data) when kind in ~w(started progress no_changes) and is_map(data),
    do: {:ok, %{}}

  def sanitize(_, _, _), do: {:error, :invalid_event}
end
