import Config

config :dev_orchestrator, ecto_repos: [DevOrchestrator.Repo]

config :dev_orchestrator, DevOrchestratorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DevOrchestratorWeb.ErrorHTML, json: DevOrchestratorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DevOrchestrator.PubSub,
  live_view: [signing_salt: "dev-orchestrator-live"]

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "code",
  "secret",
  "authorization",
  "access_token",
  "refresh_token",
  "client_secret",
  "session_token"
]

config :pbkdf2_elixir, :rounds, 600_000
config :logger, :console, format: "$time $level $message\n"

import_config "#{config_env()}.exs"
