defmodule DevOrchestrator.Intake.SlackDrafts do
  import Bitwise
  alias DevOrchestrator.{Connections, Store}
  alias DevOrchestrator.Connections.{OpenAI, Slack}
  alias DevOrchestrator.Connections.Linear
  alias DevOrchestrator.Intake.TaskDraft

  @max_attempts 5

  def accept(event) when is_map(event) do
    with {:ok, project, slack_connection} <- route(event),
         true <- valid_event?(event) do
      ids = event["file_ids"]

      audio_valid =
        is_list(ids) and length(ids) == 1 and is_binary(hd(ids)) and hd(ids) != ""

      linear_ready =
        is_map(Connections.for_project(project["organization_id"], project["id"], "linear")) and
          present?(project["linear_team"]) and present?(project["linear_project"])

      error_category =
        cond do
          not audio_valid -> "audio_required"
          not linear_ready -> "linear_not_configured"
          true -> nil
        end

      file_id = if error_category, do: nil, else: hd(ids)
      id = Store.id()

      case Store.one(
             "INSERT INTO slack_task_drafts(id,event_id,organization_id,project_id,slack_connection_id,requester_slack_user_id,channel_id,thread_ts,file_id,message_text,error_category) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT(event_id) DO NOTHING RETURNING id",
             [
               id,
               event["event_id"],
               project["organization_id"],
               project["id"],
               slack_connection["id"],
               event["requester_slack_user_id"],
               event["channel_id"],
               event["thread_ts"],
               file_id,
               event["text"] || "",
               error_category
             ]
           ) do
        %{"id" => _} -> {:ok, :created}
        nil -> {:ok, :duplicate}
      end
    else
      false -> {:ok, :ignored}
      nil -> {:ok, :ignored}
      {:error, _} -> {:ok, :ignored}
      _ -> {:ok, :ignored}
    end
  end

  def accept(_), do: {:ok, :ignored}

  def process_one do
    case claim_received() do
      {:ok, nil} -> :empty
      {:ok, row} -> process_received(row)
      {:error, _} = error -> error
    end
  end

  def expire do
    case Store.one(
           "UPDATE slack_task_drafts SET state='cancelled',error_category='confirmation_expired',updated_at=now() WHERE id=(SELECT id FROM slack_task_drafts WHERE state='awaiting_confirmation' AND expires_at<=now() ORDER BY expires_at LIMIT 1) RETURNING *"
         ) do
      nil -> :ok
      row -> remove_buttons(row)
    end
  end

  def confirm(action), do: transition_action(action, "create_linear_task", "creating")
  def cancel(action), do: transition_action(action, "cancel_linear_task", "cancelled")

  def create_one do
    recover_ambiguous_creations()

    case claim_creation() do
      {:ok, nil} -> update_terminal_messages()
      {:ok, row} -> create_confirmed_issue(row)
      {:error, _} = error -> error
    end
  end

  def update_terminal_messages do
    case Store.one(
           "SELECT * FROM slack_task_drafts WHERE state IN ('created','cancelled','failed','creation_ambiguous') AND slack_message_ts IS NOT NULL AND buttons_removed_at IS NULL ORDER BY updated_at LIMIT 1"
         ) do
      nil -> :empty
      row -> update_terminal_message(row)
    end
  end

  defp transition_action(action, expected_action, target_state) when is_map(action) do
    if action["action_id"] != expected_action do
      {:error, :invalid_action}
    else
      result =
        Store.transaction(fn ->
          row =
            Store.one(
              "SELECT d.*,p.slack_workspace_id,p.slack_channel AS configured_channel,c.external_id AS workspace_id,(d.expires_at>now()) AS not_expired FROM slack_task_drafts d JOIN projects p ON p.id=d.project_id AND p.organization_id=d.organization_id JOIN connections c ON c.id=d.slack_connection_id AND c.organization_id=d.organization_id AND c.revoked_at IS NULL WHERE d.id=$1 FOR UPDATE OF d",
              [action["draft_id"]]
            )

          cond do
            is_nil(row) ->
              {:error, :not_found}

            not action_matches?(row, action) ->
              {:error, :forbidden}

            row["state"] != "awaiting_confirmation" ->
              {:ok, :already_handled}

            row["not_expired"] != true ->
              {:error, :expired}

            true ->
              Store.exec(
                "UPDATE slack_task_drafts SET state=$2,claimed_at=NULL,error_category=NULL,updated_at=now() WHERE id=$1 AND state='awaiting_confirmation'",
                [row["id"], target_state]
              )

              {:ok, if(target_state == "creating", do: :queued, else: :cancelled)}
          end
        end)

      case result do
        {:ok, value} -> value
        {:error, _} = error -> error
      end
    end
  end

  defp transition_action(_, _, _), do: {:error, :invalid_action}

  defp action_matches?(row, action) do
    row["workspace_id"] == action["workspace_id"] and
      row["slack_workspace_id"] == action["workspace_id"] and
      row["channel_id"] == action["channel_id"] and
      row["configured_channel"] == action["channel_id"] and
      row["requester_slack_user_id"] == action["user_id"] and
      row["slack_message_ts"] == action["message_ts"]
  end

  defp claim_creation do
    Store.transaction(fn ->
      row =
        Store.one(
          "SELECT * FROM slack_task_drafts WHERE state='creating' AND claimed_at IS NULL AND next_attempt_at<=now() ORDER BY updated_at FOR UPDATE SKIP LOCKED LIMIT 1"
        )

      if row do
        Store.one(
          "UPDATE slack_task_drafts SET claimed_at=now(),attempts=attempts+1,updated_at=now() WHERE id=$1 AND state='creating' AND claimed_at IS NULL RETURNING *",
          [row["id"]]
        )
      end
    end)
  end

  defp create_confirmed_issue(row) do
    with {:ok, project} <- project_for(row),
         connection when is_map(connection) <-
           Connections.for_project(row["organization_id"], row["project_id"], "linear"),
         {:ok, linear_token} <- Connections.credential(connection),
         {:ok, issue} <- Linear.create_issue(linear_token, project, row["task_draft"]) do
      case persist_issue(row, issue) do
        :ok -> update_terminal_messages()
        {:error, _} -> mark_creation_ambiguous(row)
      end
    else
      {:error, :ambiguous} -> mark_creation_ambiguous(row)
      {:error, category} -> handle_creation_error(row, safe_category(category))
      _ -> handle_creation_error(row, "invalid_destination")
    end
  rescue
    _ -> mark_creation_ambiguous(row)
  end

  defp persist_issue(row, issue) do
    case Store.exec(
           "UPDATE slack_task_drafts SET state='created',linear_issue_id=$2,linear_identifier=$3,linear_url=$4,claimed_at=NULL,error_category=NULL,updated_at=now() WHERE id=$1 AND state='creating'",
           [row["id"], issue.id, issue.identifier, issue.url]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp mark_creation_ambiguous(row) do
    Store.exec(
      "UPDATE slack_task_drafts SET state='creation_ambiguous',claimed_at=NULL,error_category='creation_ambiguous',buttons_removed_at=NULL,updated_at=now() WHERE id=$1 AND state='creating'",
      [row["id"]]
    )

    update_terminal_messages()
  end

  defp handle_creation_error(row, category) do
    if transient?(category) and row["attempts"] < @max_attempts do
      delay = min(round(:math.pow(2, row["attempts"])), 300)

      Store.exec(
        "UPDATE slack_task_drafts SET claimed_at=NULL,next_attempt_at=now()+($2 * interval '1 second'),error_category=$3,updated_at=now() WHERE id=$1 AND state='creating'",
        [row["id"], delay, category]
      )

      :retry
    else
      Store.exec(
        "UPDATE slack_task_drafts SET state='failed',claimed_at=NULL,error_category=$2,updated_at=now() WHERE id=$1 AND state='creating'",
        [row["id"], category]
      )

      :processed
    end
  end

  defp recover_ambiguous_creations do
    stale =
      Store.rows(
        "UPDATE slack_task_drafts SET state='creation_ambiguous',claimed_at=NULL,error_category='creation_ambiguous',updated_at=now() WHERE state='creating' AND claimed_at<now()-interval '2 minutes' RETURNING id"
      )

    if stale != [], do: update_terminal_messages()
    :ok
  end

  defp update_terminal_message(row) do
    with {:ok, token} <- slack_token(row),
         {:ok, text} <- terminal_text(row),
         :ok <-
           Slack.update_message(token, %{
             channel: row["channel_id"],
             ts: row["slack_message_ts"],
             text: text,
             blocks: []
           }) do
      Store.exec(
        "UPDATE slack_task_drafts SET buttons_removed_at=now(),updated_at=now() WHERE id=$1",
        [row["id"]]
      )

      :updated
    else
      _ -> :retry
    end
  end

  defp terminal_text(%{
         "state" => "created",
         "linear_identifier" => identifier,
         "linear_url" => url
       }) do
    if trusted_linear_url?(url),
      do: {:ok, "Created <#{url}|#{identifier}> in Linear."},
      else: {:ok, "Created #{identifier} in Linear."}
  end

  defp terminal_text(%{"state" => "creation_ambiguous"}),
    do:
      {:ok,
       "Linear's response was unclear. Check Linear for this task before submitting it again; the request will not be retried."}

  defp terminal_text(%{"state" => "cancelled"}),
    do: {:ok, "Task draft cancelled. No Linear issue was created."}

  defp terminal_text(%{"state" => "failed"}),
    do:
      {:ok,
       "This task could not be created in Linear. Check the project connection and try a new request."}

  defp trusted_linear_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when host == "linear.app" -> true
      _ -> false
    end
  end

  defp trusted_linear_url?(_), do: false

  defp route(event) do
    rows =
      Store.rows(
        "SELECT DISTINCT ON (p.id) p.*, c.id AS slack_connection_id FROM projects p JOIN connection_grants g ON g.project_id=p.id AND g.organization_id=p.organization_id JOIN connections c ON c.id=g.connection_id AND c.organization_id=g.organization_id WHERE p.slack_workspace_id=$1 AND p.slack_channel=$2 AND c.provider='slack' AND c.external_id=$1 AND c.revoked_at IS NULL ORDER BY p.id, c.created_at DESC, c.id DESC",
        [event["workspace_id"], event["channel_id"]]
      )

    case rows do
      [project] ->
        with connection when is_map(connection) <-
               Connections.for_project(project["organization_id"], project["id"], "slack"),
             %{"id" => connection_id} <- connection,
             true <- connection_id == project["slack_connection_id"] do
          {:ok, project, connection}
        else
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp valid_event?(event) do
    Enum.all?(
      ~w(event_id workspace_id channel_id requester_slack_user_id message_ts thread_ts),
      fn key ->
        value = event[key]
        is_binary(value) and value != "" and byte_size(value) <= 200
      end
    )
  end

  defp claim_received do
    Store.transaction(fn ->
      row =
        Store.one(
          "SELECT * FROM slack_task_drafts WHERE (state='received' AND next_attempt_at<=now()) OR (state='processing' AND claimed_at<now()-interval '5 minutes') ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1"
        )

      if row do
        Store.one(
          "UPDATE slack_task_drafts SET state='processing',claimed_at=now(),attempts=attempts+1,updated_at=now() WHERE id=$1 RETURNING *",
          [row["id"]]
        )
      end
    end)
  end

  defp process_received(row) do
    with {:ok, token} <- slack_token(row),
         {:ok, progress_ts} <- post_progress(token, row),
         :ok <- save_progress(row, progress_ts),
         {:ok, {transcript, draft}} <- build_task(row, token),
         :ok <- persist_draft(row, transcript, draft),
         {:ok, message_ts} <- post_draft(token, row, draft),
         :ok <- await_confirmation(row, message_ts) do
      :processed
    else
      {:error, category} -> handle_processing_error(row, category)
      _ -> handle_processing_error(row, :invalid_provider_response)
    end
  rescue
    _ -> handle_processing_error(row, :provider_unavailable)
  end

  defp build_task(%{"error_category" => "audio_required"}, _token), do: {:error, :audio_required}

  defp build_task(%{"error_category" => "linear_not_configured"}, _token),
    do: {:error, :linear_not_configured}

  defp build_task(row, token) do
    with :ok <- if(OpenAI.configured?(), do: :ok, else: {:error, :not_configured}),
         {:ok, project} <- project_for(row),
         {:ok, {transcript, draft}} <-
           Slack.with_audio(token, row["file_id"], fn path, metadata ->
             with {:ok, transcript} <- OpenAI.transcribe(path, metadata.type),
                  {:ok, raw_draft} <-
                    OpenAI.structure_task(%{
                      transcript: transcript,
                      message: row["message_text"] || "",
                      project_name: project["name"],
                      project_instructions: project["instructions"]
                    }),
                  {:ok, draft} <- TaskDraft.normalize(raw_draft) do
               {:ok, {transcript, draft}}
             end
           end) do
      {:ok, {transcript, draft}}
    end
  end

  defp post_progress(token, row) do
    Slack.post_message(token, %{
      channel: row["channel_id"],
      thread_ts: row["thread_ts"],
      client_msg_id: deterministic_uuid(row["id"] <> ":progress"),
      text: "Transcribing and preparing a task draft…",
      unfurl_links: false,
      unfurl_media: false
    })
  end

  defp post_draft(token, row, draft) do
    Slack.post_message(token, %{
      channel: row["channel_id"],
      thread_ts: row["thread_ts"],
      client_msg_id: deterministic_uuid(row["id"] <> ":draft"),
      text: "Please review the proposed Linear task and confirm or cancel.",
      blocks: TaskDraft.to_slack_blocks(draft, row["id"]),
      unfurl_links: false,
      unfurl_media: false
    })
  end

  defp save_progress(row, ts) do
    case Store.exec(
           "UPDATE slack_task_drafts SET slack_progress_message_ts=$2,updated_at=now() WHERE id=$1 AND state='processing'",
           [row["id"], ts]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp persist_draft(row, transcript, draft) do
    case Store.exec(
           "UPDATE slack_task_drafts SET transcript=$2,task_draft=$3,updated_at=now() WHERE id=$1 AND state='processing'",
           [row["id"], transcript, draft]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp await_confirmation(row, ts) do
    case Store.exec(
           "UPDATE slack_task_drafts SET state='awaiting_confirmation',slack_message_ts=$2,expires_at=now()+interval '24 hours',claimed_at=NULL,error_category=NULL,updated_at=now() WHERE id=$1 AND state='processing'",
           [row["id"], ts]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp handle_processing_error(row, category) do
    category = safe_category(category)

    if row["error_category"] == "audio_required" do
      with {:ok, token} <- slack_token(row),
           {:ok, ts} <- progress_ts(row) do
        case Slack.update_message(token, %{
               channel: row["channel_id"],
               ts: ts,
               text:
                 "Please mention me with exactly one supported audio file attached (MP3, MP4, M4A, WAV, or WebM; up to 25 MB).",
               blocks: []
             }) do
          :ok -> mark_failed(row, "audio_required")
          {:error, error} -> retry_or_fail(row, safe_category(error))
        end
      else
        {:error, error} -> retry_or_fail(row, safe_category(error))
      end
    else
      if transient?(category) and row["attempts"] < @max_attempts do
        retry(row, category)
      else
        with {:ok, token} <- slack_token(row),
             {:ok, ts} <- progress_ts(row) do
          text = processing_failure_text(row, category)

          _ =
            Slack.update_message(token, %{
              channel: row["channel_id"],
              ts: ts,
              text: text,
              blocks: []
            })
        end

        mark_failed(row, category)
      end
    end
  end

  defp retry_or_fail(row, category) do
    if transient?(category) and row["attempts"] < @max_attempts,
      do: retry(row, category),
      else: mark_failed(row, category)
  end

  defp retry(row, category) do
    delay = min(round(:math.pow(2, row["attempts"])), 300)

    Store.exec(
      "UPDATE slack_task_drafts SET state='received',claimed_at=NULL,next_attempt_at=now()+($2 * interval '1 second'),error_category=$3,updated_at=now() WHERE id=$1 AND state='processing'",
      [row["id"], delay, category]
    )

    :retry
  end

  defp mark_failed(row, category) do
    Store.exec(
      "UPDATE slack_task_drafts SET state='failed',claimed_at=NULL,error_category=$2,updated_at=now() WHERE id=$1 AND state='processing'",
      [row["id"], category]
    )

    :processed
  end

  defp remove_buttons(row) do
    with {:ok, token} <- slack_token(row),
         ts when is_binary(ts) <- row["slack_message_ts"] do
      result =
        Slack.update_message(token, %{
          channel: row["channel_id"],
          ts: ts,
          text: "This task draft expired. Send a new request to create another one.",
          blocks: []
        })

      if result == :ok do
        Store.exec("UPDATE slack_task_drafts SET buttons_removed_at=now() WHERE id=$1", [
          row["id"]
        ])
      end

      result
    else
      _ -> :ok
    end
  end

  defp progress_ts(%{"slack_progress_message_ts" => ts}) when is_binary(ts), do: {:ok, ts}

  defp progress_ts(row) do
    case Store.one("SELECT slack_progress_message_ts FROM slack_task_drafts WHERE id=$1", [
           row["id"]
         ]) do
      %{"slack_progress_message_ts" => ts} when is_binary(ts) ->
        {:ok, ts}

      _ ->
        with {:ok, token} <- slack_token(row),
             {:ok, ts} <- post_progress(token, row),
             :ok <- save_progress(row, ts),
             do: {:ok, ts}
    end
  end

  defp slack_token(row) do
    case Store.one(
           "SELECT c.* FROM connections c JOIN connection_grants g ON g.connection_id=c.id AND g.organization_id=c.organization_id WHERE c.id=$1 AND c.organization_id=$2 AND g.project_id=$3 AND c.provider='slack' AND c.revoked_at IS NULL",
           [row["slack_connection_id"], row["organization_id"], row["project_id"]]
         ) do
      connection when is_map(connection) -> Connections.credential(connection)
      _ -> {:error, :provider_authentication}
    end
  end

  defp project_for(row) do
    case Store.one("SELECT * FROM projects WHERE id=$1 AND organization_id=$2", [
           row["project_id"],
           row["organization_id"]
         ]) do
      project when is_map(project) -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end

  defp deterministic_uuid(value) do
    <<first::binary-size(6), version, second::binary-size(1), variant, rest::binary-size(7)>> =
      :crypto.hash(:sha256, value)

    bytes =
      <<first::binary, (version &&& 0x0F) ||| 0x50, second::binary, (variant &&& 0x3F) ||| 0x80,
        rest::binary>>

    hex = Base.encode16(bytes, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp processing_failure_text(%{"error_category" => "linear_not_configured"}, _category),
    do:
      "Connect Linear and configure this project's team and project before requesting a task. No issue was created."

  defp processing_failure_text(_row, "not_configured"),
    do: "Audio task intake is not configured with OpenAI yet. No Linear issue was created."

  defp processing_failure_text(_row, _category),
    do:
      "I couldn't prepare this task draft. Please check the audio and project connection, then try again."

  defp transient?(category), do: category in ["provider_unavailable", "provider_rate_limit"]

  defp safe_category(category)
       when category in [
              :provider_unavailable,
              :provider_rate_limit,
              :provider_authentication,
              :provider_rejected,
              :invalid_provider_response,
              :not_configured,
              :linear_not_configured,
              :file_too_large,
              :unsupported_file,
              :invalid_file_url,
              :audio_required,
              :not_found,
              :state_changed
            ],
       do: Atom.to_string(category)

  defp safe_category(_), do: "slack_intake_failed"
end
