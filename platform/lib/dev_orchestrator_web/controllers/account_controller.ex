defmodule DevOrchestratorWeb.AccountController do
  use Phoenix.Controller, formats: [:html]
  alias DevOrchestrator.{Accounts, RateLimit}
  import Plug.Conn

  def index(conn, _), do: redirect(conn, to: if(conn.assigns.scope, do: "/app", else: "/login"))
  def login(conn, _), do: page(conn, "login")
  def register(conn, _), do: page(conn, "register")
  def forgot(conn, _), do: page(conn, "forgot")
  def reset(conn, %{"token" => token}), do: page(conn, "reset", token: token)

  def create_account(conn, params) do
    with :ok <- rate(conn), {:ok, _} <- Accounts.register(params) do
      page(conn, "notice",
        message:
          "Check your email to verify your account. In local development, open /dev/mailbox."
      )
    else
      _ ->
        page(conn, "register",
          error:
            "Registration was not completed. Use a valid email and a password of at least 12 characters."
        )
    end
  end

  def create_session(conn, params) do
    with :ok <- rate(conn), {:ok, token} <- Accounts.login(params["email"], params["password"]) do
      Accounts.logout(get_session(conn, :session_token))

      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:session_token, token)
      |> redirect(to: "/app")
    else
      {:error, :unverified} ->
        page(conn, "login", error: "Verify your email before signing in.")

      _ ->
        page(conn, "login", error: "Sign-in failed. Check your credentials or try again later.")
    end
  end

  def logout(conn, _) do
    Accounts.logout(get_session(conn, :session_token))
    conn |> configure_session(drop: true) |> redirect(to: "/login")
  end

  def verify(conn, %{"token" => token}) do
    case Accounts.verify(token) do
      {:ok, :verified} -> page(conn, "login", message: "Email verified. You can now sign in.")
      _ -> page(conn, "notice", error: "This verification link is invalid or expired.")
    end
  end

  def send_reset(conn, params) do
    if rate(conn) == :ok, do: Accounts.request_reset(params["email"] || "")
    page(conn, "notice", message: "If the account exists, a reset link has been sent.")
  end

  def update_password(conn, params) do
    case if(rate(conn) == :ok,
           do: Accounts.reset_password(params["token"], params["password"]),
           else: {:error, :rate_limited}
         ) do
      {:ok, :reset} ->
        page(conn, "login", message: "Password updated. Previous sessions have been revoked.")

      _ ->
        page(conn, "reset",
          token: params["token"],
          error: "The link expired or the password is shorter than 12 characters."
        )
    end
  end

  defp rate(conn), do: RateLimit.check({:account, conn.remote_ip}, 10)

  defp page(conn, mode, opts \\ []) do
    render(conn, :page,
      mode: mode,
      error: opts[:error],
      message: opts[:message],
      token: opts[:token]
    )
  end
end

defmodule DevOrchestratorWeb.AccountHTML do
  use Phoenix.Component

  def page(assigns) do
    ~H"""
    <main id="main" class="auth-layout">
      <section class="auth-story">
        <a class="brand" href="/">⌘ <span>dev / orchestrator</span></a>
        <div>
          <p class="eyebrow">A workspace for work that ships</p>
          <h1>Your tools.<br />Your agents.<br />One delivery loop.</h1>
          <p>Connect a project. Pair your local Codex. Follow the work from issue to pull request.</p>
        </div>
        <p class="fine">Your agent account stays on your machine.</p>
      </section>
      <section class="auth-form">
        <p class="eyebrow">Workspace access</p>
        <h2>
          {%{
            "register" => "Create your workspace",
            "login" => "Welcome back",
            "forgot" => "Reset your password",
            "reset" => "Choose a new password",
            "notice" => "Check your inbox"
          }[@mode]}
        </h2>
        <p :if={@error} class="alert error" role="alert">{@error}</p>
        <p :if={@message} class="alert" role="status">{@message}</p>
        <form
          :if={@mode != "notice"}
          method="post"
          action={if @mode == "reset", do: "/reset/" <> (@token || ""), else: "/" <> @mode}
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label :if={@mode == "register"}>
            Workspace name<input name="name" required maxlength="100" autocomplete="organization" />
          </label>
          <label :if={@mode != "reset"}>
            Email<input name="email" type="email" required maxlength="254" autocomplete="email" />
          </label>
          <label :if={@mode in ["register", "login", "reset"]}>
            Password<input
              name="password"
              type="password"
              required
              minlength={if @mode == "login", do: 1, else: 12}
              autocomplete={if @mode == "login", do: "current-password", else: "new-password"}
            />
          </label>
          <p :if={@mode in ["register", "reset"]} class="muted fine">Use at least 12 characters.</p>
          <button type="submit">
            {%{
              "login" => "Sign in",
              "register" => "Create workspace",
              "forgot" => "Send reset link",
              "reset" => "Update password"
            }[@mode]}
          </button>
        </form>
        <p class="fine">
          <a href="/login">Sign in</a>
          · <a href="/register">Create workspace</a>
          · <a href="/forgot">Forgot password?</a>
        </p>
      </section>
    </main>
    """
  end
end
