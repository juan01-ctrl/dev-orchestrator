defmodule DevOrchestrator.Runs.Continuation do
  @moduledoc false
  @pr_work ~w(slack_followup pr_feedback)

  # Carry the approved work request through an answer or technical retry without
  # nesting every intermediate pause. These values come from server-owned snapshots.
  def with_origin(previous, next) do
    origin =
      case previous do
        %{"kind" => kind} = work when kind in @pr_work -> work
        %{"origin" => %{"kind" => kind} = work} when kind in @pr_work -> work
        _ -> nil
      end

    if origin, do: Map.put(next, "origin", origin), else: next
  end

  def pr_work?(%{"kind" => kind}) when kind in @pr_work, do: true

  def pr_work?(%{"kind" => kind, "origin" => %{"kind" => origin}})
      when kind in ~w(human_answer execution_retry) and origin in @pr_work, do: true

  def pr_work?(_), do: false
end
