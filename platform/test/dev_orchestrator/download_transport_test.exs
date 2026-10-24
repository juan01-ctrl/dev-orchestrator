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
  @mp4 <<24::32, "ftypM4A ", 0::32, "M4A ", "isom">>

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

  test "native Slack clips use the downloaded MP4 format and size for transcription" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-openai-token")
    body = @mp4 <> :binary.copy(<<0>>, 38_934 - byte_size(@mp4))

    real_transport(fn conn ->
      case conn.host do
        "slack.com" ->
          metadata =
            Map.merge(audio_metadata(), %{
              "subtype" => "slack_audio",
              "filetype" => "webm",
              "name" => "audio_message.webm",
              "size" => 70_365
            })

          Req.Test.json(conn, %{"ok" => true, "file" => metadata})

        "files.slack.com" ->
          binary_response(conn, "video/mp4", body)

        "api.openai.com" ->
          assert conn.request_path == "/v1/audio/transcriptions"

          assert %Plug.Upload{filename: "audio.mp4", content_type: "audio/mp4", path: path} =
                   conn.body_params["file"]

          assert File.read!(path) == body
          Req.Test.json(conn, %{"text" => "Corregir el botón."})
      end
    end)

    assert {:ok, "Corregir el botón."} =
             Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
               assert metadata.type == "mp4"
               assert metadata.size == 38_934
               assert metadata.name == "audio_message.mp4"
               send(self(), {:downloaded_clip, path})
               OpenAI.transcribe(path, metadata.type)
             end)

    assert_receive {:downloaded_clip, path}
    refute File.exists?(path)
  end

  test "the streamed transcription preserves binary CRLF and sends the declared multipart length" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-openai-token")
    body = binary_part(@wav, 0, 44) <> <<13, 10, 255, 0>>

    real_transport(fn conn ->
      case conn.host do
        "slack.com" -> Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})
        "files.slack.com" -> binary_response(conn, "audio/wav", body)
        "api.openai.com" -> Req.Test.json(conn, %{"text" => "Corregir el botón."})
      end
    end)

    transport = Application.fetch_env!(:dev_orchestrator, :provider_transport)

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      if opts[:url] == "https://api.openai.com/v1/audio/transcriptions" do
        multipart = Req.Utils.encode_form_multipart(opts[:form_multipart])
        bytes = multipart.body |> Enum.to_list() |> IO.iodata_to_binary()
        send(self(), {:transcription_multipart, bytes, multipart.size})
        assert bytes =~ "filename=\"audio.wav\""
        assert opts[:receive_timeout] == 120_000
        assert opts[:retry] == false
      end

      transport.(opts)
    end)

    assert {:ok, "Corregir el botón."} =
             Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
               OpenAI.transcribe(path, metadata.type)
             end)

    assert_receive {:transcription_multipart, bytes, declared_size}
    assert byte_size(bytes) == declared_size
    assert :binary.match(bytes, body) != :nomatch
  end

  test "native clip handling does not bypass HTTP integrity or file validation" do
    for {subtype, body, content_type, length} <- [
          {nil, @mp4, "video/mp4", 24},
          {"slack_audio", "<html>not audio</html>", "text/html", 21},
          {"slack_audio", @mp4, "text/html", 24},
          {"slack_audio", @mp4, "video/mp4", 25}
        ] do
      real_transport(fn conn ->
        case conn.host do
          "slack.com" ->
            metadata = Map.merge(audio_metadata(), %{"subtype" => subtype, "size" => 100})
            Req.Test.json(conn, %{"ok" => true, "file" => metadata})

          "files.slack.com" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", content_type)
            |> Plug.Conn.put_resp_header("content-length", Integer.to_string(length))
            |> Plug.Conn.send_resp(200, body)
        end
      end)

      assert {:error, :invalid_provider_response} =
               Slack.with_audio("test-slack-token", "F-audio", fn _, _ ->
                 flunk("invalid downloads must not reach transcription")
               end)
    end
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

  test "Slack reports download validation failures without logging private response data" do
    for {status, body, length, reason} <- [
          {206, @wav, byte_size(@wav), "unexpected_status"},
          {200, "private-response-body", 21, "size_mismatch"},
          {200, @wav, 999, "content_length_mismatch"}
        ] do
      real_transport(fn conn ->
        case conn.host do
          "slack.com" ->
            Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})

          "files.slack.com" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "audio/wav")
            |> Plug.Conn.put_resp_header("content-length", Integer.to_string(length))
            |> Plug.Conn.send_resp(status, body)
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, :invalid_provider_response} =
                   Slack.with_audio("test-slack-token", "F-audio", fn _, _ ->
                     flunk("invalid downloads must not reach transcription")
                   end)
        end)

      assert log =~ "provider=slack stage=audio_download"
      assert log =~ "reason=#{reason}"
      assert log =~ "status=#{status}"
      assert log =~ "expected_bytes=48"
      assert log =~ "received_bytes=#{byte_size(body)}"
      refute log =~ "private-response-body"
      refute log =~ "test-slack-token"
      refute log =~ "/private/audio.wav"
    end
  end

  test "Slack download diagnostics distinguish media from HTML without exposing bytes or headers" do
    for {body, content_type, format, media_type} <- [
          {<<24::32, "ftypM4A ", 0::32>>, "video/mp4", "mp4", "video"},
          {@wav, "audio/wav", "wav", "audio"},
          {<<0x1A, 0x45, 0xDF, 0xA3, 0, 0>>, "audio/webm", "webm", "audio"},
          {"  <!DOCTYPE html><html>private-body</html>", "text/html", "html", "html"},
          {<<255, 0, 254, 1>>, "private-header-value", "unknown", "other"}
        ] do
      real_transport(fn conn ->
        case conn.host do
          "slack.com" ->
            metadata = Map.put(audio_metadata(), "size", 100)
            Req.Test.json(conn, %{"ok" => true, "file" => metadata})

          "files.slack.com" ->
            binary_response(conn, content_type, body)
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, :invalid_provider_response} =
                   Slack.with_audio("test-slack-token", "F-audio", fn _, _ ->
                     flunk("diagnostics must not bypass download validation")
                   end)
        end)

      assert log =~ "detected_format=#{format}"
      assert log =~ "media_type=#{media_type}"
      refute log =~ "private-body"
      refute log =~ "private-header-value"
      refute log =~ "test-slack-token"
    end
  end

  test "OpenAI failures report HTTP status and allowlisted codes without private error details" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-openai-token")

    for {status, code, category, logged_code} <- [
          {401, "invalid_api_key", :provider_authentication, "invalid_api_key"},
          {429, "insufficient_quota", :provider_rate_limit, "insufficient_quota"},
          {503, "server_error", :provider_unavailable, "server_error"},
          {404, "model_not_found", :provider_rejected, "model_not_found"},
          {500, "private-provider-code", :provider_unavailable, "other"}
        ] do
      real_transport(fn conn ->
        case conn.host do
          "slack.com" ->
            Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})

          "files.slack.com" ->
            binary_response(conn, "audio/wav", @wav)

          "api.openai.com" ->
            conn
            |> Plug.Conn.put_status(status)
            |> Req.Test.json(%{
              "error" => %{"code" => code, "message" => "private-provider-body"}
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, ^category} =
                   Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
                     OpenAI.transcribe(path, metadata.type)
                   end)
        end)

      assert log =~ "provider=openai stage=transcription kind=http"
      assert log =~ "status=#{status} code=#{logged_code}"
      assert log =~ "elapsed_ms="
      refute log =~ "private-provider"
      refute log =~ "test-openai-token"
    end
  end

  test "OpenAI transport failures identify timeout or TLS without exposing transport details" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-openai-token")

    for {reason, logged_reason} <- [
          {:timeout, "timeout"},
          {{:tls_alert, {:unknown_ca, "private-tls-detail"}}, "tls_alert"},
          {"private-transport-detail", "other"}
        ] do
      real_transport(fn conn ->
        case conn.host do
          "slack.com" -> Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})
          "files.slack.com" -> binary_response(conn, "audio/wav", @wav)
        end
      end)

      download_transport = Application.fetch_env!(:dev_orchestrator, :provider_transport)

      Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
        if opts[:url] == "https://api.openai.com/v1/audio/transcriptions" do
          {:error, %Req.TransportError{reason: reason}}
        else
          download_transport.(opts)
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} =
                   Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
                     OpenAI.transcribe(path, metadata.type)
                   end)
        end)

      assert log =~ "provider=openai stage=transcription kind=transport"
      assert log =~ "reason=#{logged_reason}"
      refute log =~ "private-"
      refute log =~ "test-openai-token"
    end
  end

  test "OpenAI local exceptions identify their class without exposing exception messages" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-openai-token")

    real_transport(fn conn ->
      case conn.host do
        "slack.com" -> Req.Test.json(conn, %{"ok" => true, "file" => audio_metadata()})
        "files.slack.com" -> binary_response(conn, "audio/wav", @wav)
        "api.openai.com" -> raise ArgumentError, "private-exception-detail"
      end
    end)

    log =
      capture_log(fn ->
        assert {:error, :provider_unavailable} =
                 Slack.with_audio("test-slack-token", "F-audio", fn path, metadata ->
                   OpenAI.transcribe(path, metadata.type)
                 end)
      end)

    assert log =~ "provider=openai stage=transcription kind=exception"
    assert log =~ "exception=ArgumentError"
    refute log =~ "private-exception-detail"
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
