defmodule DevOrchestrator.Connections.Linear do
  require Logger
  alias DevOrchestrator.Connections.HTTP

  @max_file_bytes 10 * 1_024 * 1_024

  @allowed_types %{
    "image/png" => {".png", :png},
    "image/jpeg" => {".jpg", :jpeg},
    "image/gif" => {".gif", :gif},
    "image/webp" => {".webp", :webp},
    "text/csv" => {".csv", :text},
    "application/csv" => {".csv", :text},
    "text/tab-separated-values" => {".tsv", :text},
    "text/plain" => {".txt", :text},
    "text/markdown" => {".md", :text},
    "application/json" => {".json", :text},
    "application/yaml" => {".yaml", :text},
    "text/yaml" => {".yaml", :text},
    "application/xml" => {".xml", :text},
    "text/xml" => {".xml", :text},
    "application/pdf" => {".pdf", :pdf}
  }

  def issue_id_from_source_key("linear:" <> value) do
    case String.split(value, ":") do
      [issue_id, activation] when issue_id != "" ->
        case Integer.parse(activation) do
          {number, ""} when number > 0 -> {:ok, issue_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def issue_id_from_source_key(_), do: :error

  def query(token, query, variables) when is_binary(token) do
    case HTTP.request(:post, "https://api.linear.app/graphql",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{query: query, variables: variables}
         ) do
      {:ok, %{"errors" => _}} -> {:error, :provider_rejected}
      other -> other
    end
  end

  def create_issue(token, project, draft)
      when is_binary(token) and is_map(project) and is_map(draft) do
    with {:ok, team, states} <- validate_team(token, project["linear_team"]),
         {:ok, _linear_project} <-
           validate_linear_project(token, project["linear_project"], team["id"]),
         {:ok, state} <- select_active_state(states, project["active_states"] || []),
         {:ok, normalized_draft} <- DevOrchestrator.Intake.TaskDraft.normalize(draft),
         {:ok, title, description} <- issue_content(normalized_draft) do
      create_issue_mutation(token, %{
        "teamId" => team["id"],
        "projectId" => project["linear_project"],
        "stateId" => state["id"],
        "title" => title,
        "description" => description
      })
    end
  end

  def create_issue(_, _, _), do: {:error, :invalid_destination}

  defp validate_team(token, team_id) when is_binary(team_id) and team_id != "" do
    case query(
           token,
           "query Team($id: String!) { team(id: $id) { id states { nodes { id name } } } }",
           %{"id" => team_id}
         ) do
      {:ok,
       %{"data" => %{"team" => %{"id" => ^team_id, "states" => %{"nodes" => states}} = team}}}
      when is_list(states) ->
        {:ok, team, states}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_destination}
    end
  end

  defp validate_team(_, _), do: {:error, :invalid_destination}

  defp validate_linear_project(token, project_id, team_id)
       when is_binary(project_id) and project_id != "" do
    case query(
           token,
           "query Project($id: String!) { project(id: $id) { id teams { nodes { id } } } }",
           %{"id" => project_id}
         ) do
      {:ok,
       %{
         "data" => %{
           "project" => %{"id" => ^project_id, "teams" => %{"nodes" => teams}} = project
         }
       }}
      when is_list(teams) ->
        if Enum.any?(teams, &(&1["id"] == team_id)),
          do: {:ok, project},
          else: {:error, :invalid_destination}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_destination}
    end
  end

  defp validate_linear_project(_, _, _), do: {:error, :invalid_destination}

  defp select_active_state(states, configured) when is_list(configured) do
    Enum.find_value(configured, {:error, :invalid_destination}, fn name ->
      case Enum.find(states, &(&1["name"] == name and is_binary(&1["id"]))) do
        nil -> nil
        state -> {:ok, state}
      end
    end)
  end

  defp select_active_state(_, _), do: {:error, :invalid_destination}

  defp issue_content(draft) do
    title = draft["title"]
    description = DevOrchestrator.Intake.TaskDraft.to_linear_markdown(draft)

    if is_binary(title) and String.valid?(title) and String.length(title) in 1..255 and
         String.valid?(description) and byte_size(description) <= 20_000 do
      {:ok, title, description}
    else
      {:error, :invalid_draft}
    end
  end

  defp create_issue_mutation(token, variables) do
    mutation =
      "mutation CreateIssue($teamId: String!, $projectId: String!, $stateId: String!, $title: String!, $description: String!) { issueCreate(input: {teamId: $teamId, projectId: $projectId, stateId: $stateId, title: $title, description: $description}) { success issue { id identifier url } } }"

    case HTTP.request(:post, "https://api.linear.app/graphql",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{query: mutation, variables: variables}
         ) do
      {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}
      when is_map(issue) ->
        if is_binary(issue["id"]) and is_binary(issue["identifier"]) and is_binary(issue["url"]) do
          {:ok, %{id: issue["id"], identifier: issue["identifier"], url: issue["url"]}}
        else
          {:error, :ambiguous}
        end

      {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}} ->
        {:error, :provider_rejected}

      {:error, reason} when reason in [:provider_authentication, :provider_rate_limit] ->
        {:error, reason}

      {:error, :provider_unavailable} ->
        {:error, :ambiguous}

      _ ->
        {:error, :ambiguous}
    end
  rescue
    _ -> {:error, :ambiguous}
  end

  def download_file(token, source_url, opts \\ [])

  def download_file(token, source_url, opts) when is_binary(token) and is_binary(source_url) do
    if not DevOrchestrator.Intake.LinearAssets.linear_upload_url?(source_url) do
      {:error, :invalid_file_url}
    else
      request_download(token, source_url, opts)
    end
  end

  def download_file(_, _, _), do: {:error, :invalid_file_url}

  defp request_download(token, source_url, opts) do
    collector = fn {:data, chunk}, {request, response} ->
      chunks = Map.get(response.private, :linear_asset_chunks, [])
      size = Map.get(response.private, :linear_asset_size, 0) + byte_size(chunk)

      if size > @max_file_bytes do
        {:halt,
         {request,
          %{response | private: Map.put(response.private, :linear_asset_too_large, true)}}}
      else
        {:cont,
         {request,
          %{
            response
            | private:
                response.private
                |> Map.put(:linear_asset_chunks, [chunk | chunks])
                |> Map.put(:linear_asset_size, size)
          }}}
      end
    end

    with {:ok, %{status: 200} = response} <-
           HTTP.request_response(:get, source_url,
             headers: [{"authorization", "Bearer " <> token}, {"accept-encoding", "identity"}],
             into: collector,
             raw: true
           ),
         false <- Map.get(response.private || %{}, :linear_asset_too_large, false),
         body <-
           response.private
           |> Map.get(:linear_asset_chunks, [])
           |> Enum.reverse()
           |> IO.iodata_to_binary(),
         :ok <- verify_content_length(response.headers || %{}, byte_size(body)),
         {:ok, media_type, extension} <- validate_file(body, response.headers || %{}) do
      filename =
        opts
        |> Keyword.get(:filename_hint, "linear-file")
        |> safe_filename(extension)

      {:ok,
       %{
         body: body,
         filename: filename,
         media_type: media_type,
         sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
       }}
    else
      true -> {:error, :file_too_large}
      {:error, :file_too_large} -> {:error, :file_too_large}
      {:error, :provider_rejected} -> {:error, :unsupported_file}
      {:error, _} = error -> error
      _ -> {:error, :unsupported_file}
    end
  rescue
    exception ->
      Logger.warning(
        "File processing failed; provider=linear stage=asset_download " <>
          "exception=#{inspect(exception.__struct__)}"
      )

      {:error, :provider_unavailable}
  end

  defp validate_file(body, headers) when is_binary(body) do
    media_type =
      header(headers, "content-type") |> String.split(";", parts: 2) |> hd() |> String.downcase()

    case Map.get(@allowed_types, media_type) do
      {extension, kind} ->
        if valid_signature?(body, kind),
          do: {:ok, media_type, extension},
          else: {:error, :unsupported_file}

      _ ->
        {:error, :unsupported_file}
    end
  end

  defp valid_signature?(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, :png), do: true
  defp valid_signature?(<<0xFF, 0xD8, 0xFF, _::binary>>, :jpeg), do: true
  defp valid_signature?(<<"GIF87a", _::binary>>, :gif), do: true
  defp valid_signature?(<<"GIF89a", _::binary>>, :gif), do: true
  defp valid_signature?(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>, :webp), do: true
  defp valid_signature?(<<"%PDF-", _::binary>>, :pdf), do: true

  defp valid_signature?(body, :text) do
    String.valid?(body) and not String.contains?(body, <<0>>) and
      not Regex.match?(~r/^\s*(?:<!doctype\s+html|<html\b|<svg\b)/i, body)
  end

  defp valid_signature?(_, _), do: false

  defp verify_content_length(headers, actual_size) do
    case Integer.parse(header(headers, "content-length")) do
      {size, ""} when size == actual_size and size <= @max_file_bytes ->
        :ok

      {size, ""} when size > @max_file_bytes ->
        {:error, :file_too_large}

      {size, ""} when size >= 0 ->
        {:error, :provider_rejected}

      _ ->
        if header(headers, "content-length") == "",
          do: :ok,
          else: {:error, :provider_rejected}
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value("", fn {key, value} ->
      if is_binary(key) and String.downcase(key) == name,
        do: List.wrap(value) |> List.first(),
        else: nil
    end)
    |> to_string()
  end

  defp safe_filename(name, extension) do
    base =
      name
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.replace(~r/[^\p{L}\p{N}._ -]/u, "_")
      |> String.trim()
      |> String.slice(0, 100)

    base = if base == "" or base in [".", ".."], do: "linear-file", else: base
    if String.downcase(Path.extname(base)) == extension, do: base, else: base <> extension
  end
end
