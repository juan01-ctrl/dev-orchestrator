# Checks without PostgreSQL or provider network access. Not a substitute for mix test.
for app <- ~w(jason req plug mime plug_crypto telemetry),
    profile <- ~w(test dev),
    path = "_build/#{profile}/lib/#{app}/ebin",
    File.dir?(path),
    do: Code.append_path(path)

for file <-
      ~w(policy.ex runtime_config.ex execution_policy.ex connections/secret_box.ex connections/http.ex connections/oauth.ex connections/github.ex connections/slack.ex connections/open_ai.ex intake/slack.ex intake/task_draft.ex intake/slack_drafts.ex intake/linear_assets.ex connections/linear.ex runs/failure_budget.ex runs/event.ex runs/lifecycle.ex delivery/retry.ex delivery/verification.ex intake/signature.ex intake/inbox.ex intake/reconciler.ex intake/linear.ex background.ex) do
  Code.require_file("lib/dev_orchestrator/" <> file)
end

Code.require_file("lib/dev_orchestrator/intake/batch.ex")
ExUnit.start()
Code.require_file("test/dev_orchestrator/batch_test.exs")
Code.require_file("lib/dev_orchestrator/background/worker.ex")
Code.require_file("test/dev_orchestrator/background_worker_test.exs")
Code.require_file("lib/dev_orchestrator/runs/pr_feedback.ex")
Code.require_file("test/dev_orchestrator/pr_feedback_test.exs")
Code.require_file("test/dev_orchestrator/reconciliation_cursor_test.exs")

for name <-
      ~w(policy runtime_config execution_policy secret_box failure_budget event verification webhook provider intake task_draft linear_assets runs_lifecycle delivery_retry download_transport),
    do: Code.require_file("test/dev_orchestrator/#{name}_test.exs")
