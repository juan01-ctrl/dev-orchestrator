defmodule DevOrchestrator.Runs.Clarification do
  @moduledoc false

  def normalize_questions(%{"questions" => questions}) when is_list(questions) do
    normalized = Enum.map(questions, &normalize_question/1)

    if length(normalized) in 1..5 and Enum.all?(normalized, &is_map/1) and
         length(Enum.uniq_by(normalized, & &1["id"])) == length(normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_clarification}
    end
  end

  def normalize_questions(_), do: {:error, :invalid_clarification}

  def decision_question([
        %{"header" => header, "options" => [%{"label" => "Approve"}, %{"label" => "Deny"}]} =
          question
      ])
      when header in [
             "Data",
             "Security",
             "Commitment",
             "Scope"
           ],
      do: question

  def decision_question(_), do: nil

  def normalize_answers(questions, answers) when is_list(questions) and is_map(answers) do
    expected_ids = MapSet.new(questions, & &1["id"])

    normalized =
      Enum.reduce_while(answers, %{}, fn {id, answer}, acc ->
        value = if is_binary(answer), do: String.trim(answer), else: ""

        if MapSet.member?(expected_ids, id) and byte_size(value) in 1..2_000 do
          {:cont, Map.put(acc, id, %{"answers" => [safe_text(value, 2_000)]})}
        else
          {:halt, :invalid}
        end
      end)

    if normalized != :invalid and MapSet.new(Map.keys(normalized)) == expected_ids,
      do: {:ok, %{"answers" => normalized}},
      else: {:error, :invalid_clarification_answer}
  end

  def normalize_answers(_, _), do: {:error, :invalid_clarification_answer}

  defp normalize_question(%{"id" => id, "question" => question} = item)
       when is_binary(id) and is_binary(question) do
    header = item["header"] || "More context"
    options = normalize_options(item["options"])

    if safe_id?(id) and byte_size(question) in 1..600 and is_binary(header) and
         byte_size(header) in 1..80 and item["isSecret"] != true and options != :invalid do
      %{
        "id" => id,
        "header" => safe_text(header, 80),
        "question" => safe_text(question, 600),
        "options" => options
      }
    else
      nil
    end
  end

  defp normalize_question(_), do: nil
  defp normalize_options(nil), do: []

  defp normalize_options(options) when is_list(options) and length(options) <= 5 do
    normalized =
      Enum.map(options, fn
        %{"label" => label, "description" => description}
        when is_binary(label) and is_binary(description) ->
          if byte_size(label) in 1..80 and byte_size(description) <= 200,
            do: %{"label" => safe_text(label, 80), "description" => safe_text(description, 200)},
            else: nil

        _ ->
          nil
      end)

    if Enum.all?(normalized, &is_map/1), do: normalized, else: :invalid
  end

  defp normalize_options(_), do: :invalid
  defp safe_id?(value), do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,80}\z/, value)

  defp safe_text(value, max) do
    value
    |> String.slice(0, max)
    |> String.replace(
      ~r/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/,
      "[redacted]"
    )
    |> String.replace(~r/(?:\/Users\/[^\s"'`]+|\/home\/[^\s"'`]+)/, "[local path]")
  end
end
