defmodule DevOrchestrator.EventTest do
  use ExUnit.Case, async: true

  test "only an explicit checkpoint flag makes a failure resumable" do
    alias DevOrchestrator.Runs.Event
    assert {:ok, %{"resumable" => true}} = Event.sanitize(%{}, "failure", %{"resumable" => true})

    assert {:ok, %{"resumable" => false}} =
             Event.sanitize(%{}, "failure", %{"resumable" => "true"})
  end

  alias DevOrchestrator.Runs.Event

  test "review repair progress is accepted and visible as an autonomous repair" do
    assert {:ok, %{"stage" => "review_repairing"}} =
             Event.sanitize(%{}, "progress", %{"stage" => "review_repairing"})
  end

  test "candidate events use the frozen attempt branch" do
    run = %{
      "id" => "run-1",
      "snapshot" => %{
        "repository" => "acme/app",
        "base_branch" => "main",
        "task_branch" => "task/run-1/attempt-2"
      }
    }

    candidate = %{
      "repository" => "acme/app",
      "base_branch" => "main",
      "branch" => "task/run-1/attempt-2",
      "commit" => String.duplicate("a", 40),
      "pr_url" => "https://github.com/acme/app/pull/1"
    }

    assert {:ok, ^candidate} = Event.sanitize(run, "candidate", candidate)

    assert {:error, :invalid_event} =
             Event.sanitize(
               run,
               "candidate",
               Map.put(candidate, "branch", "task/run-1/attempt-1")
             )
  end

  test "structured blockers retain actionable bounded details without secrets" do
    {:ok, data} =
      Event.sanitize(%{}, "blocked", %{
        "category" => "environment_setup_failed",
        "summary" => "npm ci failed: ghp_123456789012345678901234567890",
        "validation" => [
          %{"command" => "npm run check", "status" => "failed", "output" => "private"}
        ],
        "question" => "",
        "pr_url" => "https://evil.example/pull/1"
      })

    assert data["category"] == "environment_setup_failed"
    assert data["summary"] =~ "npm ci failed"
    refute data["summary"] =~ "ghp_"
    assert data["validation"] == [%{"command" => "npm run check", "status" => "failed"}]
    refute Map.has_key?(data, "pr_url")

    assert {:ok, %{"stage" => "environment_preparing"}} =
             Event.sanitize(%{}, "progress", %{"stage" => "environment_preparing"})
  end

  test "no-change reports preserve the actual summary and checks" do
    assert {:ok, %{"summary" => "Already implemented", "validation" => []}} =
             Event.sanitize(%{}, "no_changes", %{
               "summary" => "Already implemented",
               "validation" => []
             })
  end

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

    assert {:ok,
            %{
              "stage" => "task_context_ready",
              "available_count" => 2,
              "unavailable_count" => 1,
              "skipped_count" => 3
            }} =
             Event.sanitize(%{}, "progress", %{
               "stage" => "task_context_ready",
               "available_count" => 2,
               "unavailable_count" => 1,
               "skipped_count" => 3,
               "filename" => "private.csv",
               "source_url" => "https://uploads.linear.app/private"
             })

    assert {:ok, %{"stage" => "task_context_ready", "available_count" => 0}} =
             Event.sanitize(%{}, "progress", %{
               "stage" => "task_context_ready",
               "available_count" => 1000
             })
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

    assert {:ok, %{"event" => %{"text" => "[redacted]"}}} =
             Event.sanitize(
               %{},
               "activity",
               %{
                 "event" => %{
                   "kind" => "message_delta",
                   "text" => "p_123456789012345678901234567890"
                 }
               },
               "gh"
             )

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
          "task_context_loading",
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
