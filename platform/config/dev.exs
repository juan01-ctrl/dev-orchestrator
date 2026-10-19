import Config
config :dev_orchestrator, :dev_routes, true

config :dev_orchestrator, DevOrchestrator.Repo,
  url:
    System.get_env(
      "DEV_ORCHESTRATOR_DATABASE_URL",
      "postgres://postgres:postgres@localhost:5433/dev_orchestrator_dev"
    ),
  pool_size: 10

config :dev_orchestrator, DevOrchestratorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4100],
  secret_key_base: String.duplicate("local-development-only-", 4),
  check_origin: ["http://localhost:4100", "http://127.0.0.1:4100"],
  server: true

config :dev_orchestrator, DevOrchestrator.Mailer, adapter: Swoosh.Adapters.Local
config :dev_orchestrator, :public_url, "http://localhost:4100"
config :dev_orchestrator, :secure_cookies, false
config :dev_orchestrator, :background_workers, true
