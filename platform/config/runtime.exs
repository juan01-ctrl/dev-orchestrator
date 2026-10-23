import Config

if config_env() == :prod do
  url =
    System.fetch_env!("PUBLIC_URL")
    |> DevOrchestrator.RuntimeConfig.public_origin!()
    |> URI.parse()

  if url.scheme != "https" or is_nil(url.host), do: raise("PUBLIC_URL must use HTTPS")
  secret = System.fetch_env!("SECRET_KEY_BASE")
  if byte_size(secret) < 64, do: raise("SECRET_KEY_BASE must have at least 64 bytes")
  {:ok, key} = Base.decode64(System.fetch_env!("CONNECTION_ENCRYPTION_KEY"))
  if byte_size(key) != 32, do: raise("CONNECTION_ENCRYPTION_KEY must encode 32 bytes")
  config :dev_orchestrator, :encryption_key, key
  config :dev_orchestrator, :public_url, URI.to_string(url)

  config :dev_orchestrator, DevOrchestrator.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    ssl: [cacerts: :public_key.cacerts_get()],
    pool_size: 10

  config :dev_orchestrator, DevOrchestratorWeb.Endpoint,
    url: [scheme: "https", host: url.host, port: url.port || 443],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4100"))],
    secret_key_base: secret,
    server: true,
    check_origin: [URI.to_string(url)]

  config :swoosh, :api_client, Swoosh.ApiClient.Req

  config :dev_orchestrator, DevOrchestrator.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.fetch_env!("RESEND_API_KEY")
end

if config_env() == :dev do
  key = System.get_env("CONNECTION_ENCRYPTION_KEY")

  config :dev_orchestrator,
         :encryption_key,
         if(key,
           do: Base.decode64!(key),
           else: :crypto.hash(:sha256, "local-only-not-for-deployment")
         )
end

mail_from =
  if config_env() == :prod,
    do: System.fetch_env!("MAIL_FROM"),
    else: System.get_env("MAIL_FROM", "orchestrator@localhost")

config :dev_orchestrator, :mail_from, mail_from

supported_models =
  System.get_env("CODEX_SUPPORTED_MODELS", "gpt-6-luna,gpt-6.1-sol")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

network_hosts =
  System.get_env(
    "CODEX_NETWORK_ALLOWED_HOSTS",
    "registry.npmjs.org,hex.pm,repo.hex.pm,pypi.org,files.pythonhosted.org,github.com"
  )
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

routine_model = System.get_env("CODEX_ROUTINE_MODEL", "gpt-6-luna")
advanced_model = System.get_env("CODEX_ADVANCED_MODEL", "gpt-6.1-sol")

unless routine_model in supported_models and advanced_model in supported_models do
  raise "CODEX_ROUTINE_MODEL and CODEX_ADVANCED_MODEL must both be in CODEX_SUPPORTED_MODELS"
end

config :dev_orchestrator, :codex_models,
  routine: routine_model,
  advanced: advanced_model,
  supported: supported_models,
  network_hosts: network_hosts

unless config_env() == :test do
  for {provider, prefix} <- [{:slack, "SLACK"}, {:linear, "LINEAR"}, {:github, "GITHUB"}] do
    config :dev_orchestrator, provider,
      client_id: System.get_env(prefix <> "_CLIENT_ID"),
      client_secret: System.get_env(prefix <> "_CLIENT_SECRET"),
      webhook_secret: System.get_env(prefix <> "_WEBHOOK_SECRET"),
      app_id: System.get_env(prefix <> "_APP_ID"),
      private_key_path: System.get_env(prefix <> "_PRIVATE_KEY_PATH"),
      app_slug: System.get_env(prefix <> "_APP_SLUG")
  end

  config :dev_orchestrator, :slack, signing_secret: System.get_env("SLACK_SIGNING_SECRET")

  config :dev_orchestrator, :openai,
    api_key: System.get_env("OPENAI_API_KEY"),
    transcription_model: System.get_env("OPENAI_TRANSCRIPTION_MODEL", "gpt-transcribe"),
    task_model: System.get_env("OPENAI_TASK_MODEL", "gpt-6-luna")
end
