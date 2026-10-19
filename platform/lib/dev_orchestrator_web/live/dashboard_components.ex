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
  def executor_status(%{"revoked_at" => revoked}) when not is_nil(revoked), do: "Revoked"
  def executor_status(%{"last_seen_at" => nil}), do: "Waiting for first connection"

  def executor_status(e),
    do:
      if(DateTime.diff(DateTime.utc_now(), e["last_seen_at"]) < 45,
        do: "Connected",
        else: "Offline"
      )
end
