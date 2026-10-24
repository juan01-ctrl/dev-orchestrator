defmodule DevOrchestrator.DownloadTransportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias DevOrchestrator.Connections.{Linear, OpenAI, Slack}
  alias DevOrchestrator.Intake.TaskDraft

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )
  @wav <<"RIFF", 40::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
         8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 4::little-32,
         0::little-16, 0::little-16>>

  setup do
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    old_openai = Application.get_env(:dev_orchestrator, :openai)
    {:ok, _} = Application.ensure_all_started(:plug)

    on_exit(fn ->
      restore(:provider_transport, old_transport)
      restore(:openai, old_openai)
    end)

    :ok
  end

  test "Linear images pass through real Req option validation and binary streaming" do
    real_transport(fn conn ->
      assert conn.host == "uploads.linear.app"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-linear-token"]
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]
      binary_response(conn, "image/png", @png)
    end)

    assert {:ok, file} =
             Linear.download_file("test-linear-token", "https://uploads.linear.app/reference",
               filename_hint: "reference.png"
             )

    assert file.body == @png
    assert file.filename == "reference.png"
    assert file.media_type == "image/png"
    assert file.sha256 == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
  end

  test "Slack audio downloads, transcribes through real multipart and produces a structured draft" do
    Application.put_env(:dev_orchestrator, :openai,
      api_key: "test-openai-token",
      transcription_model: "test-transcription-model",
      task_model: "test-task-model"
    )

    draft = %{
      "title" => "Corregir el botón",
      "context" => "El botón no responde.",
      "objective" => "Permitir guardar los cambios.",
      "scope" => ["Corregir la acción de guardar."],
      "acceptance_criteria" => ["El botón guarda los cambios."],
      "constraints_or_open_questions" => []
    }

    real_transport(fn conn ->
      case {conn.host, conn.request_path} do
        {"slack.com", "/api/files.info"} ->
          assert conn.query_params["file"] == "F-audio"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-slack-token"]
          Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})

        {"files.slack.com", "/private/audio.wav"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-slack-token"]
          binary_response(conn, "audio/wav", @wav)

        {"api.openai.com", "/v1/audio/transcriptions"} ->
          assert conn.method == "POST"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-openai-token"]
          assert conn.body_params["model"] == "test-transcription-model"

          assert %Plug.Upload{filename: "audio.wav", content_type: "audio/wav", path: path} =
                   conn.body_params["file"]

          assert File.read!(path) == @wav
          Req.Test.json(conn, %{"text" => "Corregir el botón para guardar los cambios."})

        {"api.openai.com", "/v1/responses"} ->
          assert conn.body_params["model"] == "test-task-model"
          assert conn.body_params["text"]["format"]["type"] == "json_schema"

          Req.Test.json(conn, %{
            "output" => [
              %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(draft)}]}
            ]
          })
      end
    end)

    assert {:ok, normalized} =
             Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
               send(self(), {:downloaded_audio, path})
               assert File.read!(path) == @wav
               assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
               refute Map.has_key?(metadata, :url)

               with {:ok, transcript} <- OpenAI.transcribe(path, metadata.type),
                    {:ok, result} <- OpenAI.structure_task(%{transcript: transcript}) do
                 TaskDraft.normalize(result)
               end
             end)

    assert normalized["title"] == "Corregir el botón"
    assert_receive {:downloaded_audio, path}
    refute File.exists?(path)
  end

  test "real Req does not follow a Linear redirect with provider credentials" do
    real_transport(fn conn ->
      assert conn.host == "uploads.linear.app"

      conn
      |> Plug.Conn.put_resp_header("location", "https://untrusted.example/reference.png")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :unsupported_file} =
             Linear.download_file("test-linear-token", "https://uploads.linear.app/reference")
  end

  test "Linear authentication failures and invalid image bytes keep distinct error categories" do
    for status <- [401, 403] do
      real_transport(fn conn -> Plug.Conn.send_resp(conn, status, "private provider detail") end)

      assert {:error, :provider_authentication} =
               Linear.download_file("test-linear-token", "https://uploads.linear.app/reference")
    end

    real_transport(fn conn -> binary_response(conn, "image/png", "<html>not an image</html>") end)

    assert {:error, :unsupported_file} =
             Linear.download_file("test-linear-token", "https://uploads.linear.app/reference")
  end

  test "Slack cleans the downloaded audio when downstream processing rejects it" do
    real_transport(fn conn ->
      case conn.host do
        "slack.com" -> Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})
        "files.slack.com" -> binary_response(conn, "audio/wav", @wav)
      end
    end)

    assert {:error, :provider_rejected} =
             Slack.with_audio("test-slack-token", "F-audio", fn path, _metadata ->
               send(self(), {:downloaded_audio, path})
               {:error, :provider_rejected}
             end)

    assert_receive {:downloaded_audio, path}
    refute File.exists?(path)
  end

  test "download exceptions identify the provider and exception class without exposing request details" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _opts ->
      raise ArgumentError, "private-token-and-source-url"
    end)

    log =
      capture_log(fn ->
        assert {:error, :provider_unavailable} =
                 Linear.download_file("test-linear-token", "https://uploads.linear.app/reference")

        assert {:error, :provider_unavailable} =
                 Slack.with_audio("test-slack-token", "F-audio", fn _, _ -> flunk("no audio") end)
      end)

    assert log =~ "provider=linear"
    assert log =~ "provider=slack"
    assert log =~ "exception=ArgumentError"
    refute log =~ "private-token-and-source-url"
    refute log =~ "test-linear-token"
    refute log =~ "uploads.linear.app/reference"
  end

  defp audio_metadata do
    %{
      "mode" => "hosted",
      "filetype" => "wav",
      "size" => byte_size(@wav),
      "name" => "audio.wav",
      "url_private_download" => "https://files.slack.com/private/audio.wav"
    }
  end

  defp binary_response(conn, type, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", type)
    |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
    |> Plug.Conn.send_resp(200, body)
  end

  defp real_transport(plug) do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      Req.request(Keyword.put(opts, :plug, plug))
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:dev_orchestrator, key, value)
end
