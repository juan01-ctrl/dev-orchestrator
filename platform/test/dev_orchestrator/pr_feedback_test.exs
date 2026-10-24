defmodule DevOrchestrator.PRFeedbackTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.PRFeedback

  test "inline comments are scoped to an authorized current-head change request" do
    sha = String.duplicate("a", 40)
    pr = %{"state" => "open", "head" => %{"sha" => sha}}

    review = %{
      "id" => 1,
      "user" => %{"login" => "owner"},
      "state" => "CHANGES_REQUESTED",
      "commit_id" => sha,
      "author_association" => "OWNER",
      "body" => ""
    }

    comment = %{
      "pull_request_review_id" => 1,
      "commit_id" => sha,
      "path" => "src/form.ts",
      "line" => 12,
      "body" => "Validate the email here"
    }

    assert {:ok, feedback} = PRFeedback.classify(pr, [], [review], sha, [comment])
    assert Enum.any?(feedback["feedback"], &String.contains?(&1["detail"], "src/form.ts:12"))

    assert {:ignore, "pending_review"} =
             PRFeedback.classify(pr, [], [review], sha, [%{comment | "commit_id" => "old"}])
  end

  test "feedback belongs to the current head and fingerprints ignore delivery order" do
    sha = String.duplicate("a", 40)
    pr = %{"state" => "open", "head" => %{"sha" => sha}}

    checks = [
      %{
        "id" => 1,
        "name" => "test",
        "head_sha" => sha,
        "conclusion" => "failure",
        "output" => %{"summary" => "Expected 200, got 500"}
      }
    ]

    assert {:ok, first} = PRFeedback.classify(pr, checks, [], sha)
    assert {:ok, repeated} = PRFeedback.classify(pr, [%{hd(checks) | "id" => 2}], [], sha)
    assert first["fingerprint"] == repeated["fingerprint"]

    assert {:ignore, "head_changed"} =
             PRFeedback.classify(
               put_in(pr, ["head", "sha"], String.duplicate("b", 40)),
               checks,
               [],
               sha
             )

    assert {:ignore, "closed"} = PRFeedback.classify(%{pr | "state" => "closed"}, checks, [], sha)

    assert {:ignore, "pending_review"} =
             PRFeedback.classify(
               pr,
               [%{hd(checks) | "head_sha" => String.duplicate("b", 40)}],
               [],
               sha
             )
  end

  test "approval supersedes an earlier request and untrusted reviewers cannot trigger work" do
    sha = String.duplicate("a", 40)
    pr = %{"state" => "open", "head" => %{"sha" => sha}}

    review = %{
      "id" => 1,
      "user" => %{"login" => "owner"},
      "state" => "CHANGES_REQUESTED",
      "commit_id" => sha,
      "author_association" => "OWNER",
      "body" => "Fix validation"
    }

    assert {:ok, _} = PRFeedback.classify(pr, [], [review], sha)
    approved = %{review | "id" => 2, "state" => "APPROVED"}
    assert {:ignore, "pending_review"} = PRFeedback.classify(pr, [], [approved, review], sha)

    assert {:ignore, "pending_review"} =
             PRFeedback.classify(pr, [], [%{review | "author_association" => "NONE"}], sha)
  end
end
