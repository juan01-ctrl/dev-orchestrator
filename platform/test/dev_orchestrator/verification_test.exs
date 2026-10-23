defmodule DevOrchestrator.VerificationTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Delivery.Verification

  test "only transient provider failures retry verification without restarting implementation" do
    assert Verification.retryable?(:provider_unavailable)
    assert Verification.retryable?(:provider_rate_limit)
    refute Verification.retryable?(:unverified_pr)
    refute Verification.retryable?(:provider_authentication)
  end

  test "a verified open PR is accepted regardless of a review state's name" do
    run = %{
      "id" => "run-13",
      "snapshot" => %{"repository" => "acme/app", "base_branch" => "main"}
    }

    result = %{
      "repository" => "acme/app",
      "branch" => "task/run-13",
      "base_branch" => "main",
      "commit" => String.duplicate("a", 40),
      "pr_url" => "https://github.com/acme/app/pull/13",
      "summary" => "Added the signup popup",
      "validation" => [%{"command" => "npm run check", "status" => "passed"}]
    }

    pr = %{
      "state" => "open",
      "head" => %{
        "ref" => "task/run-13",
        "sha" => String.duplicate("a", 40),
        "repo" => %{"full_name" => "acme/app"}
      },
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/app"}}
    }

    assert {:ok, verified} = Verification.validate_pr(run, result, pr)
    assert verified["pr_url"] == "https://github.com/acme/app/pull/13"
    assert verified["summary"] == result["summary"]
    assert verified["validation"] == result["validation"]

    assert {:error, :unverified_pr} =
             Verification.validate_pr(
               run,
               result,
               put_in(pr, ["head", "sha"], String.duplicate("b", 40))
             )

    assert {:error, :unverified_pr} =
             Verification.validate_pr(run, result, put_in(pr, ["base", "ref"], "develop"))

    assert {:error, :unverified_pr} =
             Verification.validate_pr(
               run,
               result,
               put_in(pr, ["head", "repo", "full_name"], "other/app")
             )

    assert {:error, :unverified_pr} =
             Verification.validate_pr(
               run,
               Map.put(result, "pr_url", "https://github.com/other/app/pull/13"),
               pr
             )
  end
end
