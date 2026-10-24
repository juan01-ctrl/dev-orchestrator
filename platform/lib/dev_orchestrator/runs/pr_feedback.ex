defmodule DevOrchestrator.Runs.PRFeedback do
  @moduledoc "Bounded, current-head feedback from checks and authorized PR reviewers."

  def classify(pr, checks, reviews, expected_head, comments \\ []) do
    cond do
      pr["state"] != "open" -> {:ignore, "closed"}
      get_in(pr, ["head", "sha"]) != expected_head -> {:ignore, "head_changed"}
      true -> build_feedback(checks, reviews, expected_head, comments)
    end
  end

  defp build_feedback(checks, reviews, head, comments) do
    failures =
      for check <- checks,
          check["head_sha"] == head and
            check["conclusion"] in ["failure", "timed_out", "action_required"] do
        %{
          "kind" => "ci",
          "name" => safe(check["name"], 200),
          "detail" => safe(get_in(check, ["output", "summary"]), 1_200)
        }
      end

    latest =
      reviews
      |> Enum.filter(&(&1["state"] in ["CHANGES_REQUESTED", "APPROVED", "DISMISSED"]))
      |> Enum.sort_by(&{&1["submitted_at"] || "", &1["id"] || 0})
      |> Enum.reduce(%{}, fn review, acc ->
        Map.put(acc, get_in(review, ["user", "login"]), review)
      end)

    requested =
      for {login, review} <- latest,
          is_binary(login) and review["state"] == "CHANGES_REQUESTED" and
            review["commit_id"] == head and
            review["author_association"] in ["OWNER", "MEMBER", "COLLABORATOR"] do
        inline =
          comments
          |> Enum.filter(
            &(&1["pull_request_review_id"] == review["id"] and &1["commit_id"] == head and
                is_integer(&1["line"]))
          )
          |> Enum.take(10)
          |> Enum.map_join("\n", fn c ->
            "#{safe(c["path"], 200)}:#{c["line"]} #{safe(c["body"], 800)}"
          end)

        %{
          "kind" => "review",
          "name" => safe(login, 100),
          "detail" => safe(safe(review["body"], 1_200) <> "\n" <> inline, 4_000) |> String.trim()
        }
      end

    feedback =
      (failures ++ requested)
      |> Enum.reject(&(&1["kind"] == "review" and &1["detail"] == ""))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["kind"], &1["name"], &1["detail"]})
      |> Enum.take(20)

    if feedback == [] do
      {:ignore, "pending_review"}
    else
      fingerprint =
        :crypto.hash(:sha256, Jason.encode!([head, feedback])) |> Base.encode16(case: :lower)

      {:ok,
       %{
         "kind" => "pr_feedback",
         "head" => head,
         "feedback" => feedback,
         "fingerprint" => fingerprint
       }}
    end
  end

  defp safe(value, size) do
    if(is_binary(value), do: value, else: "")
    |> String.replace(
      ~r/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/,
      "[redacted]"
    )
    |> String.replace(~r{/(?:Users|home)/[^\s"'`]+}, "[local path]")
    |> String.slice(0, size)
  end
end
