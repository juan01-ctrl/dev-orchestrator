defmodule DevOrchestrator.TaskDraftTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Intake.TaskDraft

  @draft %{
    "title" => "Export monthly usage",
    "context" => "Customers need a monthly report.",
    "objective" => "Make the report available to workspace admins.",
    "scope" => ["Add an export action"],
    "acceptance_criteria" => ["CSV contains the selected month"],
    "constraints_or_open_questions" => []
  }

  test "confirmation buttons identify the displayed revision" do
    blocks = TaskDraft.to_slack_blocks(@draft, "draft-1", 3)
    actions = List.last(blocks)[:elements]
    assert Enum.all?(actions, &(&1[:value] == "draft-1:3"))
  end

  test "normalizes exact required fields and renders the same content for Linear and Slack" do
    assert {:ok, normalized} = TaskDraft.normalize(@draft)
    assert normalized == @draft
    markdown = TaskDraft.to_linear_markdown(normalized)
    blocks = TaskDraft.to_slack_blocks(normalized, "draft-1")

    assert markdown =~ "## Objective"
    assert markdown =~ "Add an export action"
    assert Enum.any?(blocks, &(&1[:text][:text] =~ "Export monthly usage"))

    assert Enum.any?(
             blocks,
             &(&1[:elements] && hd(&1[:elements])[:action_id] == "create_linear_task")
           )

    refute markdown =~ "raw transcript"
  end

  test "rejects missing, extra, empty required, oversized and invalid UTF-8 content" do
    assert {:error, :invalid_draft} = TaskDraft.normalize(Map.delete(@draft, "context"))
    assert {:error, :invalid_draft} = TaskDraft.normalize(Map.put(@draft, "extra", "no"))
    assert {:error, :invalid_draft} = TaskDraft.normalize(Map.put(@draft, "title", " "))

    assert {:error, :invalid_draft} =
             TaskDraft.normalize(Map.put(@draft, "title", :binary.copy("a", 161)))

    assert {:error, :invalid_draft} = TaskDraft.normalize(Map.put(@draft, "context", <<255>>))
  end
end
