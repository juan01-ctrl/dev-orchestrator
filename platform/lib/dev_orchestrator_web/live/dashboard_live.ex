defmodule DevOrchestratorWeb.DashboardLive do
  use Phoenix.LiveView, layout: false
  alias DevOrchestrator.{Accounts, Projects, Connections, Executors, Runs}
  import DevOrchestratorWeb.DashboardComponents

  def mount(_, session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)

    {:ok,
     socket
     |> assign(
       session_token: session["session_token"],
       code: nil,
       selected: nil,
       selected_run: nil,
       instruction_error: nil,
       slack_channels: [],
       slack_connected: false,
       slack_channel_message: nil,
       subscribed_run_id: nil,
       clarifications: []
     )
     |> allow_upload(:instructions,
       accept: ~w(.md),
       max_entries: 1,
       max_file_size: 32_000
     )}
  end

  def handle_params(params, _, socket) do
    socket =
      socket
      |> assign(:params, params)
      |> refresh()
      |> load_slack_channels()
      |> subscribe_to_selected_run()

    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:run_updated, run_id}, socket) do
    if get_in(socket.assigns, [:selected_run, "id"]) == run_id,
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket}
  end

  def handle_event(event, params, socket) do
    case Accounts.from_session(socket.assigns.session_token) do
      {:ok, scope} -> dispatch(event, params, assign(socket, :scope, scope))
      _ -> {:noreply, redirect(socket, to: "/login")}
    end
  end

  defp dispatch("create_project", params, socket) do
    case consume_instructions(socket) do
      {:ok, instructions} ->
        case Projects.create_project(
               socket.assigns.scope,
               Map.put(params, "instructions", instructions || Projects.default_instructions())
             ) do
          {:ok, project} ->
            {:noreply, push_navigate(socket, to: "/app/projects/" <> project.id)}

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Check the project name, repository, branch and concurrency."
             )}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :instruction_error, instruction_error(reason))}
    end
  end

  defp dispatch("save_project", params, socket) do
    case consume_instructions(socket) do
      {:ok, instructions} ->
        params = if instructions, do: Map.put(params, "instructions", instructions), else: params

        case Projects.update_project(socket.assigns.scope, socket.assigns.params["id"], params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:instruction_error, nil)
             |> put_flash(:info, "Project rules saved for future attempts.")
             |> refresh()}

          {:error, :slack_channel_already_bound} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "That Slack channel is already connected to another project in this workspace."
             )}

          {:error, :slack_not_connected} ->
            {:noreply,
             put_flash(socket, :error, "Reconnect Slack before saving this channel binding.")}

          _ ->
            {:noreply,
             put_flash(socket, :error, "Project rules were not saved. Check the fields.")}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :instruction_error, instruction_error(reason))}
    end
  end

  defp dispatch("validate_project_upload", _params, socket),
    do: {:noreply, assign(socket, :instruction_error, nil)}

  defp dispatch("refresh_slack_channels", _params, socket),
    do: {:noreply, load_slack_channels(socket)}

  defp dispatch("create_run", params, socket) do
    case Runs.create(socket.assigns.scope, params["project_id"], params) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: "/app/runs/" <> run["id"])}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Choose a project and enter a title and task instructions.")}
    end
  end

  defp dispatch("pair", _, socket) do
    case Executors.create_enrollment(socket.assigns.scope) do
      {:ok, code} ->
        {:noreply, assign(socket, :code, code)}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only owners can enroll executors. Try again later if the limit was reached."
         )}
    end
  end

  defp dispatch("bind", params, socket) do
    case Executors.bind(socket.assigns.scope, params["executor_id"], params["project_id"]) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Executor authorized for this project.") |> refresh()}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Binding denied. Check ownership and project access.")}
    end
  end

  defp dispatch("revoke", %{"id" => id}, socket),
    do: action(socket, Executors.revoke(socket.assigns.scope, id), "Executor access revoked.")

  defp dispatch("disconnect", %{"id" => id}, socket),
    do:
      action(
        socket,
        Connections.disconnect(socket.assigns.scope, id),
        "Connection disabled for future requests."
      )

  defp dispatch("retry", %{"id" => id}, socket),
    do: action(socket, Runs.retry(socket.assigns.scope, id), "New execution lifecycle queued.")

  defp dispatch("cancel", %{"id" => id}, socket),
    do:
      action(
        socket,
        Runs.cancel(socket.assigns.scope, id),
        "Cancellation recorded. The executor stops on lease renewal."
      )

  defp dispatch("retry_delivery", %{"id" => id}, socket),
    do:
      action(
        socket,
        DevOrchestrator.Delivery.Outbox.retry_failed(socket.assigns.scope, id),
        "Report delivery queued again. Task execution was not restarted."
      )

  defp dispatch("acknowledge_delivery", %{"id" => id}, socket),
    do:
      action(
        socket,
        DevOrchestrator.Delivery.Outbox.acknowledge_ambiguous(socket.assigns.scope, id),
        "Ambiguous delivery acknowledged without resending."
      )

  defp dispatch("answer_clarification", %{"id" => id, "answers" => answers}, socket) do
    case Runs.answer_clarification(socket.assigns.scope, id, %{"answers" => answers}) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Context sent. The task will continue from its current Codex thread."
         )
         |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The context request is no longer open or the answers are incomplete."
         )}
    end
  end

  defp dispatch(_, _, socket), do: {:noreply, socket}

  defp consume_instructions(socket) do
    upload = socket.assigns.uploads.instructions

    if Enum.any?(upload.entries, &(not &1.valid?)) do
      {:error, :invalid_file}
    else
      case consume_uploaded_entries(socket, :instructions, fn %{path: path}, entry ->
             result =
               with {:ok, bytes} <- File.read(path),
                    result <- Projects.validate_instructions(entry.client_name, bytes) do
                 result
               else
                 _ -> {:error, :invalid_file}
               end

             {:ok, result}
           end) do
        [result] -> result
        [] -> {:ok, nil}
      end
    end
  end

  defp instruction_error(:invalid_filename), do: "Choose the file named instructions.md."
  defp instruction_error(:too_large), do: "The instructions file must be 32 KB or smaller."
  defp instruction_error(:invalid_encoding), do: "The instructions file must use UTF-8 text."
  defp instruction_error(:empty), do: "The instructions file cannot be empty."
  defp instruction_error(_), do: "Choose a valid, non-empty Markdown file no larger than 32 KB."

  defp provider_name("github"), do: "GitHub"
  defp provider_name(provider), do: String.capitalize(provider)

  defp action(socket, result, message) do
    if result == :ok or match?({:ok, _}, result),
      do: {:noreply, socket |> put_flash(:info, message) |> refresh()},
      else:
        {:noreply,
         put_flash(socket, :error, "The action is not available for this state or account.")}
  end

  defp refresh(socket) do
    case Accounts.from_session(socket.assigns.session_token) do
      {:ok, scope} ->
        selected =
          if socket.assigns.live_action == :project do
            case Projects.get_project(scope, socket.assigns.params["id"]) do
              {:ok, p} -> p
              _ -> nil
            end
          end

        run =
          if socket.assigns.live_action == :run do
            case Runs.get(scope, socket.assigns.params["id"]) do
              {:ok, r} -> r
              _ -> nil
            end
          end

        github_status =
          if selected, do: Connections.github_status(scope, selected.id), else: :not_installed

        connected_providers =
          if selected do
            %{
              "github" => github_status == :connected,
              "linear" =>
                not is_nil(Connections.for_project(scope.organization_id, selected.id, "linear")),
              "slack" =>
                not is_nil(Connections.for_project(scope.organization_id, selected.id, "slack"))
            }
          else
            %{}
          end

        assign(socket,
          scope: scope,
          projects: Projects.list(scope),
          connections: Connections.list(scope),
          github_status: github_status,
          connected_providers: connected_providers,
          executors: Executors.list(scope),
          bindings: Executors.bindings(scope),
          runs: Runs.list(scope),
          selected: selected,
          selected_run: run,
          deliveries:
            if(run, do: DevOrchestrator.Delivery.Outbox.list(scope, run["id"]), else: []),
          events: if(run, do: Runs.events(scope, run["id"]), else: []),
          clarifications:
            if(run,
              do:
                case Runs.clarifications(scope, run["id"]) do
                  {:ok, values} -> values
                  _ -> []
                end,
              else: []
            )
        )

      _ ->
        redirect(socket, to: "/login")
    end
  end

  defp subscribe_to_selected_run(socket) do
    run_id = get_in(socket.assigns, [:selected_run, "id"])
    previous_id = socket.assigns[:subscribed_run_id]

    if connected?(socket) and previous_id != run_id do
      if previous_id,
        do: Phoenix.PubSub.unsubscribe(DevOrchestrator.PubSub, "run:" <> previous_id)

      if run_id, do: Runs.subscribe(socket.assigns.scope, run_id)
    end

    assign(socket, :subscribed_run_id, run_id)
  end

  defp load_slack_channels(
         %{assigns: %{live_action: :project, selected: %{id: project_id}}} = socket
       ) do
    case Connections.slack_channels(socket.assigns.scope, project_id) do
      {:ok, channels} ->
        assign(socket,
          slack_channels: channels,
          slack_connected: true,
          slack_channel_message:
            if(channels == [],
              do:
                "No channels available yet. Invite the connected app to a channel, then refresh.",
              else: nil
            )
        )

      {:error, :not_connected} ->
        assign(socket,
          slack_channels: [],
          slack_connected: false,
          slack_channel_message: "Connect Slack below to choose this project's report channel."
        )

      {:error, :missing_scope} ->
        assign(socket,
          slack_channels: [],
          slack_connected: true,
          slack_channel_message: "Reconnect Slack to grant permission to list channel names."
        )

      _ ->
        assign(socket,
          slack_channels: [],
          slack_connected: true,
          slack_channel_message: "Slack channels could not be loaded. Try refreshing."
        )
    end
  end

  defp load_slack_channels(socket),
    do:
      assign(socket,
        slack_channels: [],
        slack_connected: false,
        slack_channel_message: nil
      )

  def render(assigns) do
    ~H"""
    <div class="workspace">
      <aside class="sidebar">
        <a class="brand" href="/app">⌘ <span>dev / orchestrator</span></a>
        <p class="workspace-label">Your workspace</p>
        <nav aria-label="Main navigation">
          <.link navigate="/app" aria-current={if @live_action in [:projects, :project], do: "page"}>
            Projects <span>{length(@projects)}</span>
          </.link>
          <.link navigate="/app/runs" aria-current={if @live_action in [:runs, :run], do: "page"}>
            Runs <span>{length(@runs)}</span>
          </.link>
          <.link
            navigate="/app/connections"
            aria-current={if @live_action == :connections, do: "page"}
          >
            Connections
          </.link>
          <.link navigate="/app/executors" aria-current={if @live_action == :executors, do: "page"}>
            Executors
          </.link>
        </nav>
        <div class="sidebar-bottom">
          <span class="badge">Private evaluation</span>
          <p class="fine">{@scope.email}</p>
          <form action="/logout" method="post">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <button class="quiet">
              Sign out
            </button>
          </form>
        </div>
      </aside>
      <main id="main" class="main">
        <header class="topline">
          <span>Development workspace</span><span class="fine">Local execution · Cloud coordination</span>
        </header>
        <p :if={@flash["error"]} role="alert" class="alert error">{@flash["error"]}</p>
        <p :if={@flash["info"]} role="status" class="alert">{@flash["info"]}</p>
        <section :if={@live_action == :projects}>
          <.heading
            eyebrow="From issue to delivery"
            title="Make room for work that ships."
            description="Each project has its own repository, instructions, connections and execution limits."
          />
          <div class="split">
            <div>
              <.empty
                :if={@projects == []}
                title="Start with one project"
                description="Add a repository, connect your tools and pair a local executor. Your existing Symphony setup stays separate."
              />
              <.link :for={p <- @projects} class="project-row" navigate={"/app/projects/" <> p.id}>
                <div>
                  <h2>{p.name}</h2>
                  <p class="mono muted">{p.repository}</p>
                </div>
                <span class="badge">{p.base_branch} ↗</span>
              </.link>
            </div>
            <section class="panel">
              <h2>New project</h2>
              <form id="new-project" phx-change="validate_project_upload" phx-submit="create_project">
                <.field name="name" label="Project name" required /><.field
                  name="repository"
                  label="GitHub repository"
                  placeholder="owner/repository"
                  required
                /><.field name="base_branch" label="PR target branch" value="main" required />
                <label>Project instructions (optional)</label>
                <p class="fine">
                  <a href="/templates/instructions.md" download="instructions.md">
                    Download instructions.md template
                  </a>
                </p>
                <p class="fine muted">
                  Upload instructions.md to customize this project. If you skip it, the default template is used.
                </p>
                <.live_file_input upload={@uploads.instructions} />
                <p :if={@instruction_error} id="instructions-error" role="alert" class="fine error">
                  {@instruction_error}
                </p>
                <button>
                  Create project
                </button>
              </form>
            </section>
          </div>
        </section>
        <section :if={@live_action == :project and @selected}>
          <.heading
            eyebrow={@selected.repository}
            title={@selected.name}
            description="Rules are versioned. Saving changes only affects future execution attempts."
          />
          <div class="split">
            <section class="panel">
              <h2>Project rules</h2>
              <form
                id="project-rules"
                phx-change="validate_project_upload"
                phx-submit="save_project"
              >
                <.field name="name" label="Project name" value={@selected.name} required /><.field
                  name="repository"
                  label="GitHub repository"
                  value={@selected.repository}
                  required
                /><.field
                  name="base_branch"
                  label="PR target branch"
                  value={@selected.base_branch}
                  required
                />
                <label>Project instructions</label>
                <p class="fine">
                  <a href="/templates/instructions.md" download="instructions.md">
                    Download instructions.md template
                  </a>
                </p>
                <p :if={@selected.data["instructions"] == ""} class="fine muted">
                  No instructions file is saved yet. Upload one to add project guidance.
                </p>
                <p :if={@selected.data["instructions"] != ""} class="fine muted">
                  Saved instructions stay in place unless you upload a replacement.
                </p>
                <.live_file_input upload={@uploads.instructions} />
                <p :if={@instruction_error} id="instructions-error" role="alert" class="fine error">
                  {@instruction_error}
                </p>
                <.field
                  name="concurrency"
                  type="number"
                  label="Parallel tasks (1–10)"
                  value={@selected.data["concurrency"]}
                />
                <label for="project-model">Model override</label>
                <input type="hidden" name="pr_feedback_enabled" value="false" />
                <label>
                  <input
                    type="checkbox"
                    name="pr_feedback_enabled"
                    value="true"
                    checked={@selected.data["pr_feedback_enabled"] == true}
                  /> Repair failed CI and requested PR changes (maximum 3 rounds)
                </label>
                <select id="project-model" name="model">
                  <option value="">Automatic</option>
                  <option
                    :for={model <- DevOrchestrator.ExecutionPolicy.supported_models()}
                    value={model}
                    selected={@selected.data["model"] == model}
                  >
                    {model}
                  </option>
                </select>
                <.field
                  name="linear_team"
                  label="Linear team ID"
                  value={@selected.data["linear_team"]}
                /><.field
                  name="linear_project"
                  label="Linear project ID"
                  value={@selected.data["linear_project"]}
                />
                <.field
                  name="review_state"
                  label="Linear review state"
                  value={@selected.data["review_state"]}
                />
                <label for="slack-channel">Slack report channel</label>
                <select id="slack-channel" name="slack_channel" disabled={!@slack_connected}>
                  <option value="">Choose a channel</option>
                  <option
                    :if={
                      @selected.data["slack_channel"] &&
                        not Enum.any?(@slack_channels, &(&1.id == @selected.data["slack_channel"]))
                    }
                    value={@selected.data["slack_channel"]}
                    selected
                  >
                    {if @slack_connected,
                      do: "Current channel — unavailable to the connected app",
                      else: "Previously saved channel"}
                  </option>
                  <option
                    :for={channel <- @slack_channels}
                    value={channel.id}
                    selected={channel.id == @selected.data["slack_channel"]}
                  >
                    #{channel.name}
                  </option>
                </select>
                <p :if={@slack_channel_message} class="fine muted" role="status">
                  {@slack_channel_message}
                </p>
                <button
                  :if={@slack_connected}
                  type="button"
                  class="quiet"
                  phx-click="refresh_slack_channels"
                >
                  Refresh Slack channels
                </button>
                <button>Save project rules</button>
              </form>
            </section>
            <section class="panel">
              <h2>Connect this project</h2>
              <p class="muted">Only explicitly connected accounts can be used by this project.</p>
              <div :for={provider <- ~w(github linear slack)} class="connection-row">
                <strong>{provider_name(provider)}</strong>
                <form
                  :if={
                    provider == "github" and @scope.role == "owner" and
                      DevOrchestrator.Connections.OAuth.configured?("github") and
                      @github_status == :not_installed
                  }
                  method="post"
                  action="/connections/github/install/start"
                >
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Plug.CSRFProtection.get_csrf_token()}
                  /><input type="hidden" name="project_id" value={@selected.id} />
                  <button class="secondary">Install GitHub App</button>
                </form>
                <form
                  :if={
                    DevOrchestrator.Connections.OAuth.configured?(provider) and
                      @scope.role == "owner" and
                      (provider != "github" or @github_status in [:installed, :connected])
                  }
                  method="post"
                  action={"/connections/#{provider}/start"}
                >
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Plug.CSRFProtection.get_csrf_token()}
                  /><input type="hidden" name="project_id" value={@selected.id} />
                  <button class="secondary">
                    {if @connected_providers[provider],
                      do: "Reconnect #{provider_name(provider)}",
                      else: "Connect #{provider_name(provider)}"}
                  </button>
                </form>
                <span
                  :if={@connected_providers[provider]}
                  class="connection-state is-connected"
                  role="status"
                >
                  <span class="connection-state-dot" aria-hidden="true"></span>
                  {provider_name(provider)} connected
                </span>
                <button
                  :if={
                    not @connected_providers[provider] and
                      (!DevOrchestrator.Connections.OAuth.configured?(provider) or
                         @scope.role != "owner")
                  }
                  class="secondary"
                  disabled
                >
                  Connect {provider_name(provider)}
                </button>
                <span
                  :if={@scope.role != "owner" and not @connected_providers[provider]}
                  class="badge"
                >
                  Workspace owner required
                </span>
                <span
                  :if={
                    @scope.role == "owner" and not @connected_providers[provider] and
                      !DevOrchestrator.Connections.OAuth.configured?(provider)
                  }
                  class="badge"
                >
                  Server setup required
                </span>
              </div>
              <p
                :if={
                  @scope.role == "owner" and not @connected_providers["github"] and
                    !DevOrchestrator.Connections.OAuth.configured?("github")
                }
                class="fine muted"
              >
                GitHub needs GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_APP_ID, GITHUB_APP_SLUG and GITHUB_PRIVATE_KEY_PATH on the server.
              </p>
              <p
                :if={
                  @scope.role == "owner" and not @connected_providers["linear"] and
                    !DevOrchestrator.Connections.OAuth.configured?("linear")
                }
                class="fine muted"
              >
                Linear needs LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET on the server.
              </p>
              <p
                :if={
                  @scope.role == "owner" and not @connected_providers["slack"] and
                    !DevOrchestrator.Connections.OAuth.configured?("slack")
                }
                class="fine muted"
              >
                Slack needs SLACK_CLIENT_ID and SLACK_CLIENT_SECRET on the server.
              </p>
              <p
                :if={
                  @scope.role == "owner" and
                    Enum.any?(~w(github linear slack), fn provider ->
                      not @connected_providers[provider] and
                        not DevOrchestrator.Connections.OAuth.configured?(provider)
                    end)
                }
                class="fine muted"
              >
                After configuring a provider app and its callback URLs, restart the server to enable its setup actions.
              </p>
              <p :if={@connected_providers["slack"]} class="fine muted">
                Invite the connected Slack app to the channel you want to use. Only channels where it can post are listed.
              </p>
            </section>
          </div>
        </section>
        <section :if={@live_action == :connections}>
          <.heading
            eyebrow="Tools with boundaries"
            title="Connected accounts"
            description="Connections are granted to individual projects. Provider secrets are never shown in the browser."
          />
          <.empty
            :if={@connections == []}
            title="No accounts connected"
            description="Open a project to connect GitHub, Linear and Slack. The operator must first configure each provider application."
          />
          <div :for={c <- @connections} class="project-row">
            <div>
              <h2>{c["label"]}</h2>
              <span class={if c["revoked_at"], do: "badge", else: "connection-state is-connected"}>
                <span :if={!c["revoked_at"]} class="connection-state-dot" aria-hidden="true"></span>
                {if c["revoked_at"], do: "Disconnected", else: "Connected"}
              </span>
              <p class="mono fine">{c["id"]}</p>
            </div>
            <button
              :if={@scope.role == "owner" and !c["revoked_at"]}
              class="secondary"
              phx-click="disconnect"
              phx-value-id={c["id"]}
              data-confirm="Disable this connection?"
            >
              Disconnect
            </button>
          </div>
        </section>
        <section :if={@live_action == :executors}>
          <.heading
            eyebrow="Your account stays local"
            title="Execution, on your terms."
            description="Pair a machine, authorize its projects, and run the connector with your existing Codex login. No inbound port is opened."
          />
          <div class="setup-steps">
            <details class="setup-step" open={@executors == [] or not is_nil(@code)}>
              <summary>
                <span class="step-number">1</span>
                <span class="step-heading">Pair this computer<small>Install the connector and link it to your account.</small></span>
                <span :if={@code} class="badge">Code ready · 10 min</span>
              </summary>
              <div class="setup-step-content">
                <button :if={@scope.role == "owner" and !@code} phx-click="pair">Create pairing code</button>
                <div :if={@code}>
                  <h2>Pair within 10 minutes</h2>
                  <p>Run this command on the computer that will process tasks:</p>
                  <pre>mkdir -p "$HOME/.local/share/dev-orchestrator" && npx --yes @juan01-ctrl/dev-orchestrator-connector@0.4.1 pair --server {Application.fetch_env!(:dev_orchestrator,:public_url)} --code {@code} --config "$HOME/.local/share/dev-orchestrator/connector.json"</pre>
                  <button
                    type="button"
                    class="secondary copy-command"
                    aria-label="Copy pairing command"
                    data-copy={"mkdir -p \"$HOME/.local/share/dev-orchestrator\" && npx --yes @juan01-ctrl/dev-orchestrator-connector@0.4.1 pair --server #{Application.fetch_env!(:dev_orchestrator, :public_url)} --code #{@code} --config \"$HOME/.local/share/dev-orchestrator/connector.json\""}
                  >
                    <.copy_icon /> <span class="copy-label">Copy command</span>
                  </button>
                  <p class="fine muted">
                    The code is single use. Next, start the connector and authorize a project.
                  </p>
                </div>
                <p :if={!@code and @scope.role == "owner"} class="fine muted">
                  Create a one-time pairing code to begin.
                </p>
                <p :if={!@code and @scope.role != "owner"} class="fine muted">
                  Ask a workspace owner to create the pairing code.
                </p>
              </div>
            </details>
            <details :if={@executors != []} class="setup-step">
              <summary>
                <span class="step-number">2</span>
                <span class="step-heading">Start the connector<small>Keep it running on your development computer to process tasks.</small></span>
                <span class="badge">{length(@executors)} paired</span>
              </summary>
              <div class="setup-step-content">
                <div :for={e <- @executors} class="executor-card">
                  <div class="executor-card-heading">
                    <div>
                      <h2>{e["name"]}</h2><p class="mono fine muted">{e["id"]}</p>
                    </div>
                    <span class={
                      if executor_status(e) == "Connected", do: "badge is-positive", else: "badge"
                    }>{executor_status(e)}</span>
                  </div>
                  <p class="fine muted">Run this command in a terminal and leave it open:</p>
                  <pre>npx --yes @juan01-ctrl/dev-orchestrator-connector@0.4.1 run --config "$HOME/.local/share/dev-orchestrator/connector.json"</pre>
                  <div class="executor-card-actions">
                    <button
                      :if={@scope.role == "owner" and !e["revoked_at"]}
                      type="button"
                      class="secondary copy-command"
                      aria-label="Copy start command"
                      data-copy={"npx --yes @juan01-ctrl/dev-orchestrator-connector@0.4.1 run --config \"$HOME/.local/share/dev-orchestrator/connector.json\""}
                    >
                      <.copy_icon /> <span class="copy-label">Copy command</span>
                    </button>
                    <button
                      :if={@scope.role == "owner" and !e["revoked_at"]}
                      phx-click="revoke"
                      phx-value-id={e["id"]}
                      class="secondary"
                    >
                      Revoke access
                    </button>
                  </div>
                </div>
              </div>
            </details>
            <details
              :if={@scope.role == "owner" and @executors != [] and @projects != []}
              class="setup-step"
            >
              <summary>
                <span class="step-number">3</span>
                <span class="step-heading">Authorize a project<small>Choose which project this computer can access.</small></span>
                <span class="badge">{length(@bindings)} authorized</span>
              </summary>
              <form class="setup-step-content" phx-submit="bind">
                <label>
                  Executor<select name="executor_id"><option
                    :for={e <- @executors}
                    :if={!e["revoked_at"]}
                    value={e["id"]}
                  >
                    {e["name"]}
                  </option></select>
                </label>
                <label>Project<select name="project_id"><option :for={p <- @projects} value={p.id}>
                  {p.name}
                </option></select></label>
                <button>Authorize project</button>
              </form>
            </details>
          </div>
        </section>
        <section :if={@live_action == :runs}>
          <.heading
            eyebrow="The delivery loop"
            title="Work in motion"
            description="Track the task, not a terminal. Results appear here and in your project's Slack channel."
          />
          <.run_list runs={@runs} />
          <form :if={@projects != []} class="panel" phx-submit="create_run">
            <h2>New task</h2>
            <label>
              Project<select name="project_id"><option :for={p <- @projects} value={p.id}>
                {p.name}
              </option></select>
            </label>
            <.field name="title" label="Task title" required />
            <label>
              Task mode<select name="mode"><option value="implement">Implement changes</option><option value="investigate">
                Investigate and report
              </option></select>
            </label>
            <label>
              Instructions<textarea name="prompt" required rows="4" maxlength="32000"></textarea>
            </label>
            <button>Queue task</button>
          </form>
        </section>
        <section :if={@live_action == :run and @selected_run}>
          <.heading
            eyebrow="Run details"
            title={@selected_run["title"]}
            description="Only verified delivery counts as success. Files and commits are preserved when work is interrupted."
          />
          <div class="delivery-rail">
            <span class="badge">{humanize(@selected_run["state"])}</span><span>Attempt {@selected_run[
              "generation"
            ]}</span><span>Lifecycle {@selected_run["lifecycle"]}</span>
          </div>
          <section :if={@selected_run["result"]} class="panel">
            <p :if={@selected_run["pr_observation"]} class="fine">
              PR follow-up: {humanize(@selected_run["pr_observation"]["status"])} · Repairs: {@selected_run[
                "repair_count"
              ] || 0}/3
            </p>
            <h2>Result</h2>
            <p>{@selected_run["result"]["summary"]}</p>
            <a
              :if={@selected_run["result"]["pr_url"]}
              href={@selected_run["result"]["pr_url"]}
              target="_blank"
              rel="noopener noreferrer"
              class="button"
            >
              Review pull request ↗
            </a>
          </section>
          <section class="activity-panel" aria-label="Task activity">
            <header class="activity-header">
              <div>
                <p class="eyebrow">Execution activity</p>
                <h2>What’s happening</h2>
              </div>
              <span
                class={
                  if(@selected_run["state"] == "running",
                    do: "activity-status is-live",
                    else: "activity-status"
                  )
                }
                role="status"
                aria-live="polite"
              >
                <span class="activity-status-dot" aria-hidden="true"></span>
                {if @selected_run["state"] == "running", do: "Live", else: "Activity log"}
              </span>
            </header>
            <p class="fine muted activity-note">
              Updates as work progresses. Private reasoning and raw command output stay hidden.
            </p>
            <div
              :if={@events != []}
              id="activity-stream"
              class="activity-stream"
              phx-hook="ActivityStream"
              role="region"
              aria-label="Task activity updates"
              tabindex="0"
            >
              <ol class="activity-list" aria-live="polite" aria-relevant="additions text">
                <li
                  :for={{event, index} <- Enum.with_index(@events)}
                  class={[
                    "activity-item",
                    if(@selected_run["state"] == "running" and index == length(@events) - 1,
                      do: "is-current",
                      else: nil
                    )
                  ]}
                  aria-current={
                    if(@selected_run["state"] == "running" and index == length(@events) - 1,
                      do: "step",
                      else: nil
                    )
                  }
                >
                  <span class="activity-marker" aria-hidden="true"></span>
                  <div class="activity-content">
                    <div class="activity-meta">
                      <strong>{activity_title(event)}</strong>
                      <time class="mono fine muted">{Calendar.strftime(
                        event["created_at"],
                        "%H:%M:%S"
                      )}</time>
                    </div>
                    <p class="fine muted">{activity_description(event)}</p>
                  </div>
                </li>
              </ol>
            </div>
            <p :if={@events == []} class="activity-empty muted" role="status">
              Waiting for the local executor to report its first update…
            </p>
          </section>
          <section :if={@clarifications != []} class="panel">
            <h2>Additional context</h2>
            <article :for={clarification <- @clarifications} class="connection-row">
              <div>
                <span class="badge">{humanize(clarification["status"])}</span>
                <p :for={question <- clarification["questions"]} class="fine">
                  <strong>{question["header"]}:</strong> {question["question"]}
                  <span :if={question["options"] != []} class="fine muted">
                    Options: {Enum.map_join(question["options"], ", ", & &1["label"])}
                  </span>
                </p>
                <p :if={clarification["status"] == "answered"} class="fine muted">
                  Answer submitted. The executor will continue this task.
                </p>
              </div>
              <form
                :if={clarification["status"] == "open" and @scope.role == "owner"}
                phx-submit="answer_clarification"
                phx-value-id={clarification["id"]}
              >
                <label :for={question <- clarification["questions"]}>
                  {question["header"]}
                  <input
                    type="text"
                    name={"answers[" <> question["id"] <> "]"}
                    maxlength="2000"
                    required
                    placeholder="Add the missing context"
                  />
                </label>
                <button type="submit">Send context</button>
              </form>
              <p :if={clarification["status"] == "expired"} class="fine muted">
                This request expired or the run ended before context was supplied. Check the run result for next steps.
              </p>
            </article>
          </section>
          <section :if={@deliveries != []} class="panel">
            <h2>Report delivery</h2>
            <div :for={d <- @deliveries} class="connection-row">
              <div>
                <span>{humanize(d["kind"])}</span>
                <p :if={d["last_error_category"]} class="fine muted">
                  {humanize(d["last_error_category"])}
                </p>
              </div>
              <div class="actions">
                <span class="badge">{humanize(d["state"])}</span>
                <button
                  :if={@scope.role == "owner" and d["state"] == "failed"}
                  phx-click="retry_delivery"
                  phx-value-id={d["id"]}
                  class="secondary"
                >Retry report</button>
                <button
                  :if={@scope.role == "owner" and d["state"] == "ambiguous"}
                  phx-click="acknowledge_delivery"
                  phx-value-id={d["id"]}
                  class="secondary"
                >Mark delivered</button>
              </div>
            </div>
          </section>
          <div :if={@scope.role == "owner"} class="actions">
            <button
              :if={@selected_run["state"] in ~w(blocked failed cancelled)}
              phx-click="retry"
              phx-value-id={@selected_run["id"]}
            >
              Start new lifecycle
            </button>
            <button
              :if={@selected_run["state"] not in ~w(succeeded failed cancelled)}
              phx-click="cancel"
              phx-value-id={@selected_run["id"]}
              class="secondary"
            >Cancel task</button>
          </div>
        </section>
        <.empty
          :if={@live_action in [:project, :run] and is_nil(@selected) and is_nil(@selected_run)}
          title="Not found"
          description="This resource does not exist in your workspace."
        />
      </main>
    </div>
    """
  end
end
