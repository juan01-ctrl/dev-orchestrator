import Config

config :dev_orchestrator, DevOrchestrator.Repo,
  url:
    System.get_env(
      "DEV_ORCHESTRATOR_TEST_DATABASE_URL",
      "postgres://postgres:postgres@localhost:5433/dev_orchestrator_test"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :dev_orchestrator, DevOrchestratorWeb.Endpoint,
  secret_key_base: String.duplicate("isolated-tests-", 8),
  server: false

config :dev_orchestrator, DevOrchestrator.Mailer, adapter: Swoosh.Adapters.Test
config :dev_orchestrator, :public_url, "http://localhost:4100"
config :dev_orchestrator, :secure_cookies, false
config :dev_orchestrator, :background_workers, false
config :dev_orchestrator, :encryption_key, :crypto.hash(:sha256, "test-only-key")
config :pbkdf2_elixir, :rounds, 1
config :dev_orchestrator, :provider_transport, fn _ -> {:error, :network_disabled_in_tests} end
config :dev_orchestrator, :github, []
config :dev_orchestrator, :linear, []
config :dev_orchestrator, :slack, []
config :logger, level: :warning
