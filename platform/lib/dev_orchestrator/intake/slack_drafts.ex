defmodule DevOrchestrator.Intake.SlackDrafts do
  require Logger
  import Bitwise
  alias DevOrchestrator.{Connections, Store}
  alias DevOrchestrator.Connections.{OpenAI, Slack}
  alias DevOrchestrator.Connections.Linear
  alias DevOrchestrator.Intake.TaskDraft
  alias DevOrchestrator.Runs.SlackFollowups

  @max_attempts 5

  def accept(event) when is_map(event) do
    with {:ok, project, slack_connection} <- route(event),
         true <- valid_event?(event) do
      case Store.transaction(fn -> accept_in_scope(event, project, slack_connection) end) do
        {:ok, result} -> result
        {:error, _} -> {:ok, :ignored}
      end
    else
      _ -> {:ok, :ignored}
    end
  end

  def accept(_), do: {:ok, :ignored}

  defp accept_in_scope(event, project, slack_connection) do
    target = SlackFollowups.target(project, event)

    duplicate =
      Store.one(
        "SELECT id FROM slack_task_drafts WHERE event_id=$1 UNION ALL SELECT draft_id AS id FROM slack_draft_inputs WHERE event_id=$1 LIMIT 1",
        [event["event_id"]]
      )

    cond do
      duplicate -> {:ok, :duplicate}
      target -> accept_followup(event, project, slack_connection, target)
      true -> accept_initial(event, project, slack_connection)
    end
  end

  defp accept_followup(event, project, connection, target) do
    previous =
      Store.one(
        "SELECT *,(expires_at IS NULL OR expires_at>now()) AS revision_not_expired FROM slack_task_drafts WHERE organization_id=$1 AND target_run_id=$2 AND state IN ('received','processing','awaiting_confirmation','creating') ORDER BY created_at DESC LIMIT 1 FOR UPDATE",
        [project["organization_id"], target["run_id"]]
      )

    cond do
      is_binary(target["requester_slack_user_id"]) and
          target["requester_slack_user_id"] != event["requester_slack_user_id"] ->
        {:ok, :ignored}

      previous &&
          (previous["thread_ts"] != event["thread_ts"] or
             previous["target_lifecycle"] != target["lifecycle"]) ->
        {:ok, :ignored}

      previous ->
        revise(previous, event)

      true ->
        insert_draft(event, project, connection, target)
    end
  end

  defp accept_initial(event, project, slack_connection) do
    previous =
      if event["thread_ts"] != event["message_ts"] do
        Store.one(
          "SELECT *,(expires_at IS NULL OR expires_at>now()) AS revision_not_expired FROM slack_task_drafts WHERE project_id=$1 AND organization_id=$2 AND channel_id=$3 AND thread_ts=$4 ORDER BY created_at DESC LIMIT 1 FOR UPDATE",
          [project["id"], project["organization_id"], event["channel_id"], event["thread_ts"]]
        )
      end

    cond do
      previous -> revise(previous, event)
      event["thread_ts"] != event["message_ts"] -> {:ok, :ignored}
      true -> insert_draft(event, project, slack_connection)
    end
  end

  defp revise(previous, event) do
    valid_state =
      previous["state"] in ~w(received processing awaiting_confirmation) and
        (is_map(previous["task_draft"]) or is_binary(previous["target_run_id"]))

    not_expired = previous["revision_not_expired"] == true

    with true <-
           valid_state and not_expired and
             previous["requester_slack_user_id"] == event["requester_slack_user_id"],
         {:ok, file_id} <- DevOrchestrator.Intake.Slack.task_file_id(event) do
      receipt =
        Store.one(
          "INSERT INTO slack_draft_inputs(event_id,draft_id) VALUES($1,$2) ON CONFLICT(event_id) DO NOTHING RETURNING event_id",
          [event["event_id"], previous["id"]]
        )

      if receipt do
        message =
          if previous["message_text"] in [nil, ""],
            do: event["text"] || "",
            else: previous["message_text"] <> "\n\nCorrection:\n" <> (event["text"] || "")

        message = String.slice(message, -4_000, 4_000)

        Store.exec(
          "UPDATE slack_task_drafts SET revision=revision+1,state='received',file_id=$2,message_text=$3,attempts=0,claimed_at=NULL,next_attempt_at=now(),error_category=NULL,updated_at=now() WHERE id=$1",
          [previous["id"], revision_file_id(previous, file_id), message]
        )

        {:ok, :revised}
      else
        {:ok, :duplicate}
      end
    else
      _ -> {:ok, :ignored}
    end
  end

  @doc false
  def revision_file_id(previous, file_id) do
    if is_nil(file_id) and previous["state"] in ~w(received processing),
      do: previous["file_id"],
      else: file_id
  end

  defp insert_draft(event, project, slack_connection, target \\ nil) do
    input = DevOrchestrator.Intake.Slack.task_file_id(event)

    linear_ready =
      is_map(Connections.for_project(project["organization_id"], project["id"], "linear")) and
        present?(project["linear_team"]) and present?(project["linear_project"])

    error_category =
      cond do
        match?({:error, _}, input) -> "input_required"
        not linear_ready and is_nil(target) -> "linear_not_configured"
        true -> nil
      end

    file_id = if error_category, do: nil, else: elem(input, 1)
    id = Store.id()

    case Store.one(
           "INSERT INTO slack_task_drafts(id,event_id,organization_id,project_id,slack_connection_id,requester_slack_user_id,channel_id,thread_ts,file_id,message_text,error_category,target_run_id,target_lifecycle,target_commit) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) ON CONFLICT(event_id) DO NOTHING RETURNING id",
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
             error_category,
             if(target, do: target["run_id"]),
             if(target, do: target["lifecycle"]),
             if(target, do: target["commit"] || "")
           ]
         ) do
      %{"id" => _} -> {:ok, :created}
      nil -> {:ok, :duplicate}
    end
  end

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

  def confirm(%{"action_id" => "apply_pr_followup"} = action),
    do: transition_action(action, "apply_pr_followup", "creating")

  def confirm(action), do: transition_action(action, "create_linear_task", "creating")

  def cancel(%{"action_id" => "cancel_pr_followup"} = action),
    do: transition_action(action, "cancel_pr_followup", "cancelled")

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

            is_binary(row["target_run_id"]) !=
                expected_action in ["apply_pr_followup", "cancel_pr_followup"] ->
              {:error, :invalid_action}

            row["revision"] != Map.get(action, "revision", 1) ->
              {:error, :stale_draft}

            row["slack_message_ts"] != action["message_ts"] ->
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
      row["requester_slack_user_id"] == action["user_id"]
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

  defp create_confirmed_issue(%{"target_run_id" => target} = row) when is_binary(target) do
    case SlackFollowups.queue(row) do
      {:ok, _} -> update_terminal_messages()
      {:error, category} -> handle_creation_error(row, safe_category(category))
    end
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
    Store.exec(
      "UPDATE slack_task_drafts SET claimed_at=NULL,next_attempt_at=now(),updated_at=now() WHERE target_run_id IS NOT NULL AND state='creating' AND claimed_at<now()-interval '2 minutes'"
    )

    stale =
      Store.rows(
        "UPDATE slack_task_drafts SET state='creation_ambiguous',claimed_at=NULL,error_category='creation_ambiguous',updated_at=now() WHERE target_run_id IS NULL AND state='creating' AND claimed_at<now()-interval '2 minutes' RETURNING id"
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
         "target_run_id" => run_id
       })
       when is_binary(run_id),
       do:
         {:ok,
          "Approved update queued for the existing pull request. I will report the result in this thread. No new Linear task was created."}

  defp terminal_text(%{"state" => "cancelled", "target_run_id" => run_id}) when is_binary(run_id),
    do: {:ok, "PR update cancelled. The existing pull request was not changed."}

  defp terminal_text(%{"state" => state, "target_run_id" => run_id} = row)
       when is_binary(run_id) and state in ["failed", "creation_ambiguous"],
       do: {:ok, followup_failure(row["error_category"])}

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
    with {:ok, token} <- logged_step("slack_credentials", fn -> slack_token(row) end),
         {:ok, progress_ts} <-
           logged_step("slack_progress_message", fn -> post_progress(token, row) end),
         :ok <- save_progress(row, progress_ts),
         {:ok, {transcript, draft}} <-
           logged_step("task_draft", fn -> build_task(row, token) end),
         :ok <- persist_draft(row, transcript, draft),
         {:ok, message_ts} <-
           logged_step("slack_draft_message", fn -> post_draft(token, row, draft) end),
         :ok <- await_confirmation(row, message_ts) do
      :processed
    else
      {:error, category} -> handle_processing_error(row, category)
      _ -> handle_processing_error(row, :invalid_provider_response)
    end
  rescue
    exception ->
      Logger.warning(
        "Slack task draft processing failed; recovering its durable state. " <>
          "step=processing category=provider_unavailable exception=#{inspect(exception.__struct__)}"
      )

      retry_or_fail(row, "provider_unavailable")
  end

  defp logged_step(step, operation) do
    case operation.() do
      {:error, category} ->
        logged_category = safe_category(category)

        Logger.warning(
          "Slack task draft processing failed; step=#{step} category=#{logged_category}"
        )

        {:error, category}

      result ->
        result
    end
  rescue
    exception ->
      Logger.warning(
        "Slack task draft processing failed; step=#{step} " <>
          "category=provider_unavailable exception=#{inspect(exception.__struct__)}"
      )

      {:error, :provider_unavailable}
  end

  defp build_task(%{"error_category" => "audio_required"}, _token), do: {:error, :audio_required}

  defp build_task(%{"error_category" => "input_required"}, _token), do: {:error, :input_required}

  defp build_task(%{"error_category" => "linear_not_configured"}, _token),
    do: {:error, :linear_not_configured}

  defp build_task(row, token) do
    with :ok <- if(OpenAI.configured?(), do: :ok, else: {:error, :not_configured}),
         {:ok, project} <- project_for(row),
         {:ok, context} <- followup_context(row),
         {:ok, transcript} <- transcribe_audio(row, token),
         {:ok, raw_draft} <-
           logged_step("openai_task_draft", fn ->
             OpenAI.structure_task(%{
               transcript: transcript,
               previous_draft: row["task_draft"],
               purpose: if(row["target_run_id"], do: "pr_followup", else: "linear_task"),
               task_context: context,
               message: row["message_text"] || "",
               project_name: project["name"],
               project_instructions: project["instructions"]
             })
           end),
         {:ok, draft} <- TaskDraft.normalize(raw_draft) do
      {:ok, {transcript, draft}}
    end
  end

  defp followup_context(%{"target_run_id" => target} = row) when is_binary(target) do
    with {:ok, run} <- SlackFollowups.context(row) do
      {:ok,
       %{
         "title" => run["title"],
         "original_request" => String.slice(run["prompt"], 0, 4_000),
         "last_result" => String.slice(run["result"]["summary"] || "", 0, 4_000),
         "pr_url" => run["result"]["pr_url"]
       }}
    end
  end

  defp followup_context(_), do: {:ok, nil}

  defp transcribe_audio(%{"file_id" => nil} = row, _token), do: {:ok, row["transcript"]}

  defp transcribe_audio(row, token) do
    Slack.with_audio(token, row["file_id"], fn path, metadata ->
      logged_step("openai_transcription", fn -> OpenAI.transcribe(path, metadata.type) end)
    end)
  end

  defp post_progress(token, row) do
    Slack.post_message(token, %{
      channel: row["channel_id"],
      thread_ts: row["thread_ts"],
      client_msg_id: deterministic_uuid(row["id"] <> ":#{row["revision"]}:progress"),
      text:
        if(row["file_id"],
          do: "Transcribing and preparing a task draft…",
          else: "Preparing a task draft…"
        ),
      unfurl_links: false,
      unfurl_media: false
    })
  end

  defp post_draft(token, row, draft) do
    Slack.post_message(token, %{
      channel: row["channel_id"],
      thread_ts: row["thread_ts"],
      client_msg_id: deterministic_uuid(row["id"] <> ":#{row["revision"]}:draft"),
      text:
        if(row["target_run_id"],
          do:
            "Please review the proposed update to the existing PR and confirm or cancel. No new Linear task will be created.",
          else: "Please review the proposed Linear task and confirm or cancel."
        ),
      blocks:
        TaskDraft.to_slack_blocks(
          draft,
          row["id"],
          row["revision"],
          if(row["target_run_id"], do: :pr_followup, else: :linear)
        ),
      unfurl_links: false,
      unfurl_media: false
    })
  end

  defp save_progress(row, ts) do
    case Store.exec(
           "UPDATE slack_task_drafts SET slack_progress_message_ts=$2,updated_at=now() WHERE id=$1 AND state='processing' AND revision=$3",
           [row["id"], ts, row["revision"]]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp persist_draft(row, transcript, draft) do
    case Store.exec(
           "UPDATE slack_task_drafts SET transcript=$2,task_draft=$3,updated_at=now() WHERE id=$1 AND state='processing' AND revision=$4",
           [row["id"], transcript, draft, row["revision"]]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp await_confirmation(row, ts) do
    case Store.exec(
           "UPDATE slack_task_drafts SET state='awaiting_confirmation',slack_message_ts=$2,expires_at=now()+interval '24 hours',claimed_at=NULL,error_category=NULL,updated_at=now() WHERE id=$1 AND state='processing' AND revision=$3",
           [row["id"], ts, row["revision"]]
         ) do
      %{num_rows: 1} -> :ok
      _ -> {:error, :state_changed}
    end
  end

  defp handle_processing_error(_row, :state_changed), do: :processed

  defp handle_processing_error(row, category) do
    category = safe_category(category)

    if row["error_category"] in ["audio_required", "input_required"] do
      with {:ok, token} <- slack_token(row),
           {:ok, ts} <- progress_ts(row) do
        case Slack.update_message(token, %{
               channel: row["channel_id"],
               ts: ts,
               text:
                 "Please mention me with a task description in text, or attach exactly one supported audio file (MP3, MP4, M4A, WAV, or WebM; up to 25 MB).",
               blocks: []
             }) do
          :ok -> mark_failed(row, row["error_category"])
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
      "UPDATE slack_task_drafts SET state='received',claimed_at=NULL,next_attempt_at=now()+($2 * interval '1 second'),error_category=$3,updated_at=now() WHERE id=$1 AND state='processing' AND revision=$4",
      [row["id"], delay, category, row["revision"]]
    )

    :retry
  end

  defp mark_failed(row, category) do
    Store.exec(
      "UPDATE slack_task_drafts SET state='failed',claimed_at=NULL,error_category=$2,updated_at=now() WHERE id=$1 AND state='processing' AND revision=$3",
      [row["id"], category, row["revision"]]
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
    case Store.one(
           "SELECT slack_progress_message_ts FROM slack_task_drafts WHERE id=$1 AND revision=$2 AND state='processing'",
           [
             row["id"],
             row["revision"]
           ]
         ) do
      %{"slack_progress_message_ts" => ts} when is_binary(ts) ->
        {:ok, ts}

      nil ->
        {:error, :state_changed}

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
    <<first::binary-size(6), version, second::binary-size(1), variant, rest::binary-size(7),
      _::binary>> =
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

  defp processing_failure_text(%{"target_run_id" => target}, category) when is_binary(target),
    do: followup_failure(category)

  defp processing_failure_text(%{"error_category" => "linear_not_configured"}, _category),
    do:
      "Connect Linear and configure this project's team and project before requesting a task. No issue was created."

  defp processing_failure_text(_row, "not_configured"),
    do: "Task intake is not configured with OpenAI yet. No Linear issue was created."

  defp processing_failure_text(_row, _category),
    do:
      "I couldn't prepare this task draft. Please check the text or audio and project connection, then try again."

  defp followup_failure("pr_closed"),
    do:
      "The pull request is closed or merged. I did not reopen it or create a new task. Send a new request if more work is needed."

  defp followup_failure("pr_changed"),
    do:
      "The PR head, repository or task attempt changed after this proposal. I did not modify it. Send a new reply in the current report thread to review a fresh update."

  defp followup_failure("pr_busy"),
    do:
      "This task is already being updated or is no longer ready for a PR follow-up. Wait for its result before requesting another adjustment."

  defp followup_failure("context_expired"),
    do:
      "The seven-day continuation window expired. I did not restart this task without its context. Send a new task request."

  defp followup_failure("executor_unavailable"),
    do:
      "The original executor is unavailable or no longer authorized. Restore its access and saved context before requesting a PR update."

  defp followup_failure("connector_upgrade_required"),
    do:
      "This task was not executed with a compatible connector. Its PR cannot be resumed through this thread."

  defp followup_failure(_),
    do:
      "I couldn't prepare or queue this PR update. Check the text or audio and project connections, then retry. No new Linear task was created."

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
              :input_required,
              :not_found,
              :state_changed,
              :pr_closed,
              :pr_changed,
              :pr_busy,
              :pr_unavailable,
              :context_expired,
              :executor_unavailable,
              :connector_upgrade_required
            ],
       do: Atom.to_string(category)

  defp safe_category(_), do: "slack_intake_failed"
end
