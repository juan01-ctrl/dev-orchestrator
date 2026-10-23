defmodule DevOrchestratorWeb.DashboardComponents do
  use Phoenix.Component
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:type, :string, default: "text")
  attr(:placeholder, :string, default: nil)
  attr(:required, :boolean, default: false)

  def field(assigns) do
    ~H"""
    <label>
      {@label}<input
        name={@name}
        type={@type}
        value={@value}
        placeholder={@placeholder}
        required={@required}
      />
    </label>
    """
  end

  attr(:eyebrow, :string, required: true)
  attr(:title, :string, required: true)
  attr(:description, :string, required: true)

  def heading(assigns) do
    ~H"""
    <header class="page-heading">
      <p class="eyebrow">{@eyebrow}</p>
      <h1>{@title}</h1>
      <p class="muted">{@description}</p>
    </header>
    """
  end

  attr(:title, :string, required: true)
  attr(:description, :string, required: true)

  def empty(assigns) do
    ~H"""
    <section class="empty">
      <span class="empty-mark" aria-hidden="true">↗</span>
      <h2>{@title}</h2>
      <p class="muted">{@description}</p>
    </section>
    """
  end

  def copy_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" width="18" height="18" fill="none" aria-hidden="true">
      <rect x="7" y="6" width="9" height="11" rx="1.5" stroke="currentColor" stroke-width="1.5" />
      <path d="M13 6V4.5A1.5 1.5 0 0 0 11.5 3h-7A1.5 1.5 0 0 0 3 4.5v9A1.5 1.5 0 0 0 4.5 15H7" stroke="currentColor" stroke-width="1.5" />
    </svg>
    """
  end

  attr(:runs, :list, required: true)

  def run_list(assigns) do
    ~H"""
    <div>
      <.empty
        :if={@runs == []}
        title="No tasks yet"
        description="Queue a task below or configure Linear routing in a project. Work waits safely when no executor is available."
      />
      <.link :for={r <- @runs} class="project-row" navigate={"/app/runs/" <> r["id"]}>
        <div>
          <h2>{r["title"]}</h2>
          <p class="fine muted">{Calendar.strftime(r["created_at"], "%d %b · %H:%M")}</p>
        </div>
        <span class="badge">{humanize(r["state"])}</span>
      </.link>
    </div>
    """
  end

  def humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()

  def activity_title(%{"kind" => "started"}), do: "Task assigned to the local executor"
  def activity_title(%{"kind" => "candidate"}), do: "Pull request submitted for verification"
  def activity_title(%{"kind" => "no_changes"}), do: "Task completed without code changes"

  def activity_title(%{
        "kind" => "activity",
        "data" => %{"event" => %{"kind" => "message_delta"}}
      }),
      do: "Agent progress update"

  def activity_title(%{"kind" => "activity", "data" => %{"event" => %{"kind" => "plan"}}}),
    do: "Implementation plan updated"

  def activity_title(%{"kind" => "activity", "data" => %{"event" => %{"kind" => "usage"}}}),
    do: "Execution usage updated"

  def activity_title(%{"kind" => "activity", "data" => %{"event" => %{"kind" => "warning"}}}),
    do: "Execution warning"

  def activity_title(%{"kind" => kind, "data" => %{"category" => category}})
      when kind in ["failure", "blocked"], do: failure_title(category)

  def activity_title(%{"kind" => "failure"}), do: "Execution could not be completed"
  def activity_title(%{"kind" => "blocked"}), do: "Execution is blocked"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "repository_preparing"}}),
    do: "Connecting to the project repository"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "workspace_ready"}}),
    do: "Workspace prepared"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "resuming_thread"}}),
    do: "Resuming the existing task"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "waiting_for_context"}}),
    do: "Waiting for your context"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "agent_started"}}),
    do: "Implementation started"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "working"}}),
    do: "Working in the project"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "editing"}}),
    do: "Project files are being updated"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "validating"}}),
    do: "Running a project check"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "checks_passed"}}),
    do: "Project check passed"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "publishing"}}),
    do: "Preparing the pull request"

  def activity_title(%{"kind" => "progress", "data" => %{"stage" => "pr_verifying"}}),
    do: "Verifying the pull request"

  def activity_title(_), do: "Execution update"

  def activity_description(%{"kind" => "started"}),
    do: "A local executor accepted the task and reserved its workspace."

  def activity_description(%{"kind" => "candidate"}),
    do: "GitHub received the changes; the server is verifying the pull request."

  def activity_description(%{"kind" => "no_changes"}),
    do: "The task finished without project changes, so no pull request was needed."

  def activity_description(%{
        "kind" => "activity",
        "data" => %{"event" => %{"kind" => "message_delta", "text" => text}}
      }),
      do: text

  def activity_description(%{
        "kind" => "activity",
        "data" => %{"event" => %{"kind" => "plan", "steps" => steps}}
      }),
      do: "The agent has #{length(steps)} tracked plan steps."

  def activity_description(%{
        "kind" => "activity",
        "data" => %{
          "event" => %{"kind" => "usage", "inputTokens" => input, "outputTokens" => output}
        }
      }),
      do: "Usage so far: #{input} input and #{output} output tokens."

  def activity_description(%{
        "kind" => "activity",
        "data" => %{"event" => %{"kind" => "warning", "message" => message}}
      }),
      do: message

  def activity_description(%{"kind" => kind, "data" => %{"category" => category}})
      when kind in ["failure", "blocked"], do: failure_description(category)

  def activity_description(%{"kind" => "failure"}),
    do: "The executor reported a failure. Check the task result for the next step."

  def activity_description(%{"kind" => "blocked"}),
    do: "The executor needs missing context or a local prerequisite before it can continue."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "workspace_ready"}}),
    do: "The repository checkout and project instructions are ready."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "resuming_thread"}}),
    do:
      "The executor recovered the saved workspace and is continuing the same Codex conversation."

  def activity_description(%{
        "kind" => "progress",
        "data" => %{"stage" => "waiting_for_context"}
      }),
      do: "A clarification was requested. Answer it below or use the secure link in Slack."

  def activity_description(%{
        "kind" => "progress",
        "data" => %{"stage" => "repository_preparing"}
      }),
      do: "The executor is retrieving the approved repository and selected base branch."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "agent_started"}}),
    do: "The agent started the implementation turn using this project's instructions."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "working"}}),
    do: "The agent is working with the project files and tools."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "editing"}}),
    do: "The agent reported a file change in the task workspace."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "validating"}}),
    do: "A command matching a common test, lint, build, or type-check task has started."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "checks_passed"}}),
    do: "The latest detected project check exited successfully."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "publishing"}}),
    do: "The executor is committing the changes and opening a pull request."

  def activity_description(%{"kind" => "progress", "data" => %{"stage" => "pr_verifying"}}),
    do:
      "GitHub received the task branch. The pull request is being checked against the exact repository, base branch, and commit."

  def activity_description(_), do: "Progress was recorded for this execution."

  defp failure_title("github_installation_required"),
    do: "GitHub App access is not set up for this repository"

  defp failure_title("github_permission_denied"), do: "GitHub App permissions are insufficient"
  defp failure_title("base_branch_missing"), do: "The selected base branch was not found"
  defp failure_title("github_unavailable"), do: "GitHub could not be reached"

  defp failure_title("workspace_setup_failed"),
    do: "The local repository workspace could not be prepared"

  defp failure_title("authentication_required"), do: "The local Codex account is not signed in"
  defp failure_title(_), do: "Execution could not be completed"

  defp failure_description("github_installation_required"),
    do: "Install the configured GitHub App for this repository, then retry the task."

  defp failure_description("github_permission_denied"),
    do:
      "Update the App's repository permissions to allow repository contents access and pull request creation, then retry."

  defp failure_description("base_branch_missing"),
    do: "Choose a base branch that exists in the selected GitHub repository."

  defp failure_description("github_unavailable"),
    do: "Check GitHub availability and repository access, then retry the task."

  defp failure_description("workspace_setup_failed"),
    do:
      "Check local disk space and the connector's access to its managed data directory, then retry."

  defp failure_description("authentication_required"),
    do: "Sign in to the official Codex CLI with the account that should run this task."

  defp failure_description(_),
    do: "The executor needs missing context or a local prerequisite before it can continue."

  def executor_status(%{"revoked_at" => revoked}) when not is_nil(revoked), do: "Revoked"
  def executor_status(%{"last_seen_at" => nil}), do: "Waiting for first connection"

  def executor_status(e),
    do:
      if(DateTime.diff(DateTime.utc_now(), e["last_seen_at"]) < 45,
        do: "Connected",
        else: "Offline"
      )
end
