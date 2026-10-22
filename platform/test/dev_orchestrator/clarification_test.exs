defmodule DevOrchestrator.ClarificationTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.Clarification

  test "normalizes bounded questions and redacts tokens and local paths" do
    assert {:ok, [question]} =
             Clarification.normalize_questions(%{
               "questions" => [
                 %{
                   "id" => "framework",
                   "header" => "Framework",
                   "question" => "Use /Users/juan/project with token xoxb-1234567890-secret?",
                   "options" => [%{"label" => "Phoenix", "description" => "Elixir web app"}]
                 }
               ]
             })

    refute question["question"] =~ "/Users/juan"
    refute question["question"] =~ "xoxb-"
    assert question["question"] =~ "[local path]"
    assert question["question"] =~ "[redacted]"
    assert question["options"] == [%{"label" => "Phoenix", "description" => "Elixir web app"}]
  end

  test "rejects secret, malformed, oversized, or duplicated questions" do
    question = %{"id" => "q1", "question" => "Which option?"}

    assert {:error, :invalid_clarification} =
             Clarification.normalize_questions(%{"questions" => []})

    assert {:error, :invalid_clarification} =
             Clarification.normalize_questions(%{
               "questions" => [Map.put(question, "isSecret", true)]
             })

    assert {:error, :invalid_clarification} =
             Clarification.normalize_questions(%{"questions" => [question, question]})
  end

  test "answers map to Codex's question keyed response and require every question" do
    questions = [%{"id" => "framework"}, %{"id" => "hosting"}]

    assert {:ok,
            %{
              "answers" => %{
                "framework" => %{"answers" => ["Phoenix"]},
                "hosting" => %{"answers" => ["Fly.io"]}
              }
            }} =
             Clarification.normalize_answers(questions, %{
               "framework" => " Phoenix ",
               "hosting" => "Fly.io"
             })

    assert {:error, :invalid_clarification_answer} =
             Clarification.normalize_answers(questions, %{"framework" => "Phoenix"})

    assert {:ok, %{"answers" => %{"framework" => %{"answers" => [safe]}}}} =
             Clarification.normalize_answers([%{"id" => "framework"}], %{
               "framework" => "Use /Users/juan/app with xoxb-1234567890-private"
             })

    refute safe =~ "/Users/juan"
    refute safe =~ "xoxb-"
  end
end
