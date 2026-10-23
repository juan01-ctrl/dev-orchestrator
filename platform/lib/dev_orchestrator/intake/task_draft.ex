defmodule DevOrchestrator.Intake.TaskDraft do
  @keys ~w(title context objective scope acceptance_criteria constraints_or_open_questions)
  @max_text 8_000
  @max_field 2_500
  @max_item 1_000
  @max_items 12

  def normalize(draft) when is_map(draft) do
    valid_shape = Map.keys(draft) |> Enum.sort() == Enum.sort(@keys)

    if valid_shape and valid_fields?(draft) and total_size(draft) <= @max_text do
      normalized = Map.new(@keys, &{&1, normalize_value(draft[&1])})

      if byte_size(to_linear_markdown(normalized)) <= 20_000,
        do: {:ok, normalized},
        else: {:error, :invalid_draft}
    else
      {:error, :invalid_draft}
    end
  end

  def normalize(_), do: {:error, :invalid_draft}

  def to_linear_markdown(draft) do
    [
      "## Context\n\n",
      draft["context"],
      "\n\n## Objective\n\n",
      draft["objective"],
      "\n\n## Scope\n\n",
      bullets(draft["scope"]),
      "\n\n## Acceptance criteria\n\n",
      bullets(draft["acceptance_criteria"]),
      "\n\n## Constraints / open questions\n\n",
      bullets(draft["constraints_or_open_questions"])
    ]
    |> IO.iodata_to_binary()
  end

  def to_slack_blocks(draft, draft_id) do
    [
      section("Proposed Linear task\nTitle: " <> slack_text(draft["title"])),
      section("Context\n" <> slack_text(draft["context"])),
      section("Objective\n" <> slack_text(draft["objective"])),
      section("Scope\n" <> slack_bullets(draft["scope"])),
      section("Acceptance criteria\n" <> slack_bullets(draft["acceptance_criteria"])),
      section(
        "Constraints / open questions\n" <> slack_bullets(draft["constraints_or_open_questions"])
      ),
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            action_id: "create_linear_task",
            text: %{type: "plain_text", text: "Create in Linear"},
            value: draft_id,
            style: "primary"
          },
          %{
            type: "button",
            action_id: "cancel_linear_task",
            text: %{type: "plain_text", text: "Cancel"},
            value: draft_id
          }
        ]
      }
    ]
  end

  defp valid_fields?(draft) do
    valid_text?(draft["title"], 160, false) and
      valid_text?(draft["context"], @max_field, false) and
      valid_text?(draft["objective"], @max_field, false) and
      valid_list?(draft["scope"]) and valid_list?(draft["acceptance_criteria"]) and
      valid_list?(draft["constraints_or_open_questions"])
  end

  defp valid_text?(value, max, allow_empty) when is_binary(value) do
    String.valid?(value) and byte_size(value) <= max and
      (allow_empty or String.trim(value) != "")
  end

  defp valid_text?(_, _, _), do: false

  defp valid_list?(list) when is_list(list) and length(list) <= @max_items do
    Enum.all?(list, &valid_text?(&1, @max_item, false)) and
      byte_size(slack_bullets(list)) <= @max_field
  end

  defp valid_list?(_), do: false

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(values) when is_list(values), do: Enum.map(values, &String.trim/1)

  defp total_size(draft) do
    Enum.reduce(@keys, 0, fn key, total ->
      value = draft[key]

      total +
        if(is_list(value),
          do: Enum.sum(Enum.map(value, &byte_size/1)),
          else: byte_size(value)
        )
    end)
  end

  defp bullets([]), do: "- None specified"
  defp bullets(values), do: Enum.map_join(values, "\n", &("- " <> &1))

  defp section(text), do: %{type: "section", text: %{type: "plain_text", text: text}}

  defp slack_bullets([]), do: "• None specified"
  defp slack_bullets(values), do: Enum.map_join(values, "\n", &("• " <> slack_text(&1)))

  defp slack_text(text), do: text
end
