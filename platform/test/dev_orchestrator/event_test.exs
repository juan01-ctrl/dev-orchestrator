defmodule DevOrchestrator.EventTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.Event

  test "free-form fingerprints and logs never enter persistent events" do
    {:ok, safe} =
      Event.sanitize(%{}, "failure", %{
        "fingerprint" => "token-private",
        "category" => "publication_failed",
        "raw_output" => "token-private"
      })

    refute inspect(safe) =~ "token-private"
    assert byte_size(safe["fingerprint"]) == 64
    assert {:error, :invalid_event} = Event.sanitize(%{}, "failure", ["wrong shape"])
  end

  test "candidate event URLs and branch identity are validated before storage" do
    run = %{"id" => "run-1", "snapshot" => %{"repository" => "acme/app", "base_branch" => "main"}}

    candidate = %{
      "repository" => "acme/app",
      "base_branch" => "main",
      "branch" => "task/run-1",
      "commit" => String.duplicate("a", 40),
      "pr_url" => "https://github.com/acme/app/pull/1"
    }

    assert {:ok, ^candidate} = Event.sanitize(run, "candidate", candidate)

    assert {:error, :invalid_event} =
             Event.sanitize(
               run,
               "candidate",
               Map.put(candidate, "pr_url", candidate["pr_url"] <> "?token=private")
             )

    assert {:error, :invalid_event} =
             Event.sanitize(run, "candidate", Map.put(candidate, "branch", "task/another-run"))
  end
end
