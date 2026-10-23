defmodule DevOrchestrator.Runs.Event do
  @moduledoc "Bounded event data; raw provider/tool output is never persisted."
  @categories ~w(authentication_required local_policy_denied execution_failed publication_failed missing_context interrupted github_installation_required github_permission_denied base_branch_missing github_unavailable workspace_setup_failed environment_setup_failed validation_failed network_unavailable execution_timeout recovery_exhausted)
  @progress_stages ~w(repository_preparing workspace_ready resuming_thread waiting_for_context agent_started working editing environment_preparing validating checks_passed publishing pr_verifying)
  @secret_pattern ~r/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/

  def sanitize(run, kind, data, previous_text)
      when is_binary(previous_text) and kind != "activity",
      do: sanitize(run, kind, data)

  def sanitize(
        _,
        "activity",
        %{"event" => %{"kind" => "message_delta", "text" => text}},
        previous_text
      )
      when is_binary(text) and is_binary(previous_text) do
    combined = String.slice(previous_text, -80, 80) <> text

    safe =
      if Regex.match?(@secret_pattern, combined) and not Regex.match?(@secret_pattern, text),
        do: "[redacted]",
        else: safe_text(text, 1_000)

    {:ok, %{"event" => %{"kind" => "message_delta", "text" => safe}}}
  end

  def sanitize(run, kind, data, _previous_text), do: sanitize(run, kind, data)

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

    if valid, do: {:ok, Map.merge(allowed, report(data))}, else: {:error, :invalid_event}
  end

  def sanitize(run, kind, data) when kind in ~w(failure blocked) and is_map(data) do
    category = if data["category"] in @categories, do: data["category"], else: "execution_failed"
    fingerprint = data["fingerprint"]

    fingerprint =
      if is_binary(fingerprint) and Regex.match?(~r/\A[a-f0-9]{64}\z/, fingerprint),
        do: fingerprint,
        else: :crypto.hash(:sha256, category) |> Base.encode16(case: :lower)

    occurrences = if data["occurrences"] in [1, 2, 3], do: data["occurrences"], else: 1

    safe =
      Map.merge(
        %{"category" => category, "fingerprint" => fingerprint, "occurrences" => occurrences},
        report(data)
      )

    repo = get_in(run, ["snapshot", "repository"])
    url = data["pr_url"]

    safe =
      if is_binary(repo) and is_binary(url) and
           Regex.match?(~r/\Ahttps:\/\/github\.com\/#{Regex.escape(repo)}\/pull\/[0-9]+\z/, url),
         do: Map.put(safe, "pr_url", url),
         else: safe

    {:ok, safe}
  end

  def sanitize(_, "progress", %{"stage" => stage}) when stage in @progress_stages,
    do: {:ok, %{"stage" => stage}}

  def sanitize(_, "activity", %{"event" => %{"kind" => "message_delta", "text" => text}})
      when is_binary(text) do
    sanitize(%{}, "activity", %{"event" => %{"kind" => "message_delta", "text" => text}}, "")
  end

  def sanitize(_, "activity", %{"event" => %{"kind" => "plan", "steps" => steps}})
      when is_list(steps) do
    safe_steps =
      steps
      |> Enum.take(20)
      |> Enum.flat_map(fn
        %{"step" => step, "status" => status} when is_binary(step) and is_binary(status) ->
          [%{"step" => safe_text(step, 160), "status" => String.slice(status, 0, 32)}]

        _ ->
          []
      end)

    {:ok, %{"event" => %{"kind" => "plan", "steps" => safe_steps}}}
  end

  def sanitize(_, "activity", %{
        "event" => %{"kind" => "usage", "inputTokens" => input, "outputTokens" => output}
      })
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
      do:
        {:ok,
         %{
           "event" => %{
             "kind" => "usage",
             "inputTokens" => min(input, 2_000_000_000),
             "outputTokens" => min(output, 2_000_000_000)
           }
         }}

  def sanitize(_, "activity", %{"event" => %{"kind" => "warning", "message" => message}})
      when is_binary(message),
      do: {:ok, %{"event" => %{"kind" => "warning", "message" => safe_text(message, 300)}}}

  def sanitize(_, "activity", %{"event" => %{"kind" => "turn_completed", "status" => status}})
      when is_binary(status),
      do:
        {:ok,
         %{"event" => %{"kind" => "turn_completed", "status" => String.slice(status, 0, 32)}}}

  def sanitize(_, "no_changes", data) when is_map(data), do: {:ok, report(data)}
  def sanitize(_, "started", data) when is_map(data), do: {:ok, %{}}

  def sanitize(_, _, _), do: {:error, :invalid_event}

  defp report(data) do
    safe =
      Enum.reduce([{"summary", 1_000}, {"question", 600}], %{}, fn {key, limit}, acc ->
        if is_binary(data[key]) and data[key] != "",
          do: Map.put(acc, key, safe_text(data[key], limit)),
          else: acc
      end)

    if is_list(data["validation"]) do
      checks =
        data["validation"]
        |> Enum.take(12)
        |> Enum.flat_map(fn
          %{"command" => command, "status" => status}
          when is_binary(command) and status in ~w(passed failed not_run) ->
            [%{"command" => safe_text(command, 200), "status" => status}]

          _ ->
            []
        end)

      Map.put(safe, "validation", checks)
    else
      safe
    end
  end

  defp safe_text(value, max) do
    value
    |> String.replace(
      @secret_pattern,
      "[redacted]"
    )
    |> String.replace(~r{https?://[^\s/@]+:[^\s/@]+@}, "https://[redacted]@")
    |> String.replace(
      ~r/(?:\/Users\/[^\s"'`]+|\/home\/[^\s"'`]+|[A-Za-z]:\\Users\\[^\s"'`]+)/,
      "[local path]"
    )
    |> String.slice(0, max)
  end
end