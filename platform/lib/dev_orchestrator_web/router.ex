defmodule DevOrchestratorWeb.Router do
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import DevOrchestratorWeb.Auth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {DevOrchestratorWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'self'; frame-ancestors 'none'"
    })

    plug(:fetch_scope)
  end

  pipeline(:signed_in, do: plug(:require_scope))
  pipeline(:api, do: plug(:accepts, ["json"]))

  scope "/", DevOrchestratorWeb do
    pipe_through(:browser)
    get("/", AccountController, :index)
    get("/login", AccountController, :login)
    post("/login", AccountController, :create_session)
    get("/register", AccountController, :register)
    post("/register", AccountController, :create_account)
    post("/logout", AccountController, :logout)
    get("/verify/:token", AccountController, :verify)
    get("/forgot", AccountController, :forgot)
    post("/forgot", AccountController, :send_reset)
    get("/reset/:token", AccountController, :reset)
    post("/reset/:token", AccountController, :update_password)
  end

  scope "/", DevOrchestratorWeb do
    pipe_through([:browser, :signed_in])
    post("/connections/github/install/start", OAuthController, :install_start)
    get("/connections/github/install/callback", OAuthController, :install_callback)
    post("/connections/:provider/start", OAuthController, :start)
    get("/connections/:provider/callback", OAuthController, :callback)

    live_session :authenticated, on_mount: [{DevOrchestratorWeb.Auth, :required}] do
      live("/app", DashboardLive, :projects)
      live("/app/projects/:id", DashboardLive, :project)
      live("/app/connections", DashboardLive, :connections)
      live("/app/executors", DashboardLive, :executors)
      live("/app/runs", DashboardLive, :runs)
      live("/app/runs/:id", DashboardLive, :run)
    end
  end

  scope "/api/v1", DevOrchestratorWeb do
    pipe_through(:api)
    get("/health", HealthController, :health)
    get("/ready", HealthController, :ready)
    post("/enroll", ExecutorController, :enroll)
    post("/executor/heartbeat", ExecutorController, :heartbeat)
    post("/executor/claim", ExecutorController, :claim)
    post("/executor/renew", ExecutorController, :renew)
    post("/executor/github-token", ExecutorController, :github_token)
    post("/executor/events", ExecutorController, :event)
    post("/executor/reconcile", ExecutorController, :reconcile)
    post("/executor/clarifications/request", ExecutorController, :clarification_request)
    post("/executor/clarifications/status", ExecutorController, :clarification_status)
    post("/webhooks/linear", WebhookController, :receive_linear)
    post("/webhooks/:provider/:connection_id", WebhookController, :receive_event)
  end

  if Application.compile_env(:dev_orchestrator, :dev_routes, false) do
    scope "/dev" do
      pipe_through(:browser)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
