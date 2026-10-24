# Provider file downloads: verified failure and correction

## Root cause

The deployed Linear reference downloader and Slack audio downloader passed
`decompress_body: false` to Req 0.7.5. `decompress_body` is a response step name,
not a registered request option. Req raises `ArgumentError` before sending the
download request. Provider rescue clauses converted that exception to
`provider_unavailable`, masking a local configuration error as an upstream outage.

The Linear executor endpoint consequently returned HTTP 503, and the connector
reported the required image as unavailable. Slack exhausted its draft-processing
retries before reaching transcription. Neither result proved that the uploaded
file was missing.

Both downloaders now use `raw: true`, the supported Req option for preserving raw
response bytes without automatic decoding or decompression. Existing streaming
limits, content checks, authentication and redirect restrictions remain in place.
Unexpected download exceptions log only a fixed provider/stage and exception
class; exception messages, tokens, file contents and private URLs are not logged.

## Research and implementation decisions

| Source | Verified behavior | Decision |
| --- | --- | --- |
| [Req response options](https://req.hexdocs.pm/Req.html#new/1-options) and the installed `Req.Steps` source | `raw: true` disables decoding/decompression; `into` runs a streaming callback. | Use the installed client's supported API rather than assuming step names are options. |
| [Req testing](https://req.hexdocs.pm/Req.Test.html) | A Plug adapter replaces the remote server while retaining real Req request construction and response processing. | Exercise actual option validation, authentication headers, streaming and multipart encoding in regression tests. |
| [Linear file storage authentication](https://linear.app/developers/file-storage-authentication) | Private uploads accept the same authorization header as GraphQL. Signed URLs are optional. | Keep server-side OAuth download; do not expose tokens to the connector or add a signed-URL service. |
| [Slack file downloads](https://docs.slack.dev/messaging/working-with-files/#downloading-files) | Private downloads require bearer authorization and `files:read`; hosts and redirects must be checked before forwarding credentials. | Keep exact-host checks and automatic redirects disabled. |
| [linear-cli attachment client](https://github.com/joa23/linear-cli/blob/main/pkg/linear/attachments/client.go) | `DownloadBytes` and `DownloadToFile` fetch authenticated private files for local consumption; the client distinguishes HTTP failures and bounds reads. | Retain the current local-file materialization design rather than replacing the orchestrator. Our existing SHA-256 verification and per-run byte limits remain useful. |
| [OpenAI file transcription](https://developers.openai.com/api/docs/guides/speech-to-text) | Completed audio files use multipart POST to `/v1/audio/transcriptions`; `gpt-transcribe` returns JSON containing `text`. | Verify the real multipart request in tests. Preserve the configured models. |

## Why earlier tests missed this

The injected provider transport accepted arbitrary keyword arguments and directly
called the streaming collector. It bypassed Req's option validation; one test
even required the invalid option. That expectation has been corrected.

`download_transport_test.exs` keeps Req real and simulates only the remote HTTP
server. It covers binary Linear downloads, authorization, redirect rejection,
invalid image bytes, Slack file metadata and download, OpenAI multipart
transcription, structured draft parsing, temporary-file cleanup and safe logging.

Run all database-independent checks after dependencies are compiled:

```sh
cd platform
elixir test/offline.exs
```

Run `mix test` with the local test database for the complete platform suite and
`npm test` in `connector/` for connector checks. Offline tests do not replace the
database-backed suite or prove access to a production provider account.

## Deployment verification

This correction is in the control plane; it does not require a connector package
release. After deploying the server, retry one reference-image task and send one
Slack mention with an audio attachment. Verify the downloaded-file count and the
Slack draft before confirming Linear issue creation. Provider-backed smoke tests
remain opt-in; never print credentials or private download URLs to diagnose them.
