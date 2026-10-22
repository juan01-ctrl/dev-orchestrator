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

  test "progress events keep only an approved stage and reject free-form activity" do
    assert {:ok, %{"stage" => "editing"}} =
             Event.sanitize(%{}, "progress", %{
               "stage" => "editing",
               "message" => "token-private",
               "command" => "cat secrets.txt"
             })

    assert {:error, :invalid_event} =
             Event.sanitize(%{}, "progress", %{"stage" => "arbitrary user content"})
  end

  test "activity timeline events are allowlisted, bounded, and redact local paths and credentials" do
    {:ok, %{"event" => %{"kind" => "message_delta", "text" => text}}} =
      Event.sanitize(%{}, "activity", %{
        "event" => %{
          "kind" => "message_delta",
          "text" => "Updated /Users/juan/project and ghp_123456789012345678901234567890"
        }
      })

    refute text =~ "/Users/juan"
    refute text =~ "ghp_"
    assert text =~ "[local path]"
    assert text =~ "[redacted]"

    assert {:error, :invalid_event} =
             Event.sanitize(%{}, "activity", %{
               "event" => %{"kind" => "command_output", "text" => "private"}
             })
  end

  test "repository setup and PR verification milestones are allowlisted without free-form detail" do
    for stage <- [
          "repository_preparing",
          "resuming_thread",
          "waiting_for_context",
          "pr_verifying"
        ] do
      assert {:ok, %{"stage" => ^stage}} =
               Event.sanitize(%{}, "progress", %{"stage" => stage, "output" => "private"})
    end

    for category <- [
          "github_installation_required",
          "github_permission_denied",
          "base_branch_missing",
          "github_unavailable",
          "workspace_setup_failed"
        ] do
      assert {:ok, %{"category" => ^category} = safe} =
               Event.sanitize(%{}, "blocked", %{
                 "category" => category,
                 "provider_body" => "secret"
               })

      refute inspect(safe) =~ "secret"
    end
  end
end
