# Pure security/protocol checks only. This is not a substitute for mix test + PostgreSQL.
for file <-
      ~w(policy.ex runtime_config.ex connections/secret_box.ex connections/http.ex connections/oauth.ex connections/slack.ex runs/failure_budget.ex runs/event.ex delivery/verification.ex intake/signature.ex) do
  Code.require_file("lib/dev_orchestrator/" <> file)
end

ExUnit.start()

for name <-
      ~w(policy runtime_config secret_box failure_budget event verification webhook provider),
    do: Code.require_file("test/dev_orchestrator/#{name}_test.exs")
