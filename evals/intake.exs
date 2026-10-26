# Run only through evals/intake.mjs. No database, executor, Slack or GitHub startup.
unless System.get_env("DEV_ORCHESTRATOR_EVAL_LIVE") == "1" do
  raise "Live model evaluations require explicit opt-in"
end

Application.ensure_all_started(:req)
config = Application.get_env(:dev_orchestrator, :openai, [])
key = config[:api_key] || System.get_env("OPENAI_API_KEY")
model = config[:task_model] || System.get_env("OPENAI_TASK_MODEL") || "gpt-6-luna"

if is_binary(key) and key != "" do
  Application.put_env(
    :dev_orchestrator,
    :openai,
    Keyword.merge(config, api_key: key, task_model: model)
  )

  # Fixed repository corpus only: never accept arbitrary file paths or user input.
  corpus = File.read!(Path.expand("../evals/intake-cases.json")) |> Jason.decode!()
  selected = System.get_env("DEV_ORCHESTRATOR_EVAL_CASE")
  cases = Enum.filter(corpus["cases"], &(is_nil(selected) or &1["id"] == selected))
  if length(cases) not in 1..20, do: raise("Invalid eval corpus selection")
  IO.puts("EVAL_MODEL " <> Jason.encode!(%{model: model}))

  for scenario <- cases do
    input = scenario["input"]

    # The production adapter intentionally uses atom keys for these outer fields.
    request =
      Map.new(
        ~w(message transcript previous_draft purpose task_context project_name project_instructions)a,
        &{&1, input[Atom.to_string(&1)]}
      )

    task = Task.async(fn -> DevOrchestrator.Connections.OpenAI.structure_task(request) end)

    result =
      case Task.yield(task, 45_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, draft}} ->
          case DevOrchestrator.Intake.TaskDraft.normalize(draft) do
            {:ok, normalized} -> %{id: scenario["id"], status: "completed", draft: normalized}
            _ -> %{id: scenario["id"], status: "invalid_draft"}
          end

        {:ok, {:error, reason}}
        when reason in [
               :provider_authentication,
               :provider_rate_limit,
               :provider_unavailable,
               :provider_rejected,
               :not_configured,
               :invalid_provider_response
             ] ->
          %{id: scenario["id"], status: Atom.to_string(reason)}

        _ ->
          %{id: scenario["id"], status: "timeout_or_execution_failure"}
      end

    # Consumed in memory by intake.mjs. Draft content is not persisted in artifacts.
    IO.puts("EVAL_DRAFT " <> Jason.encode!(result))
  end
else
  IO.puts("EVAL_BLOCKED missing_openai_configuration")
  System.halt(2)
end
