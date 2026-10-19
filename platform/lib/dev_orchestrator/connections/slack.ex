defmodule DevOrchestrator.Connections.Slack do
  alias DevOrchestrator.Connections.HTTP

  def deliver(token, payload) do
    case HTTP.request(:post, "https://slack.com/api/chat.postMessage",
           headers: [{"authorization", "Bearer " <> token}],
           json: payload
         ) do
      {:ok, %{"ok" => true}} ->
        :ok

      {:ok, %{"ok" => false}} ->
        :rejected

      {:error, reason}
      when reason in [:provider_rejected, :provider_authentication, :provider_rate_limit] ->
        :rejected

      _ ->
        :ambiguous
    end
  end

  def report(payload, channel) do
    result = payload["result"]

    text =
      String.slice(payload["title"], 0, 240) <>
        "\nResult: " <> payload["state"] <> "\n" <> (result["summary"] || "Task finished.")

    blocks = [%{type: "section", text: %{type: "plain_text", text: text}}]

    blocks =
      if result["pr_url"],
        do:
          blocks ++
            [
              %{
                type: "section",
                text: %{type: "mrkdwn", text: "<" <> result["pr_url"] <> "|Review pull request>"}
              }
            ],
        else: blocks

    %{channel: channel, text: text, blocks: blocks, unfurl_links: false, unfurl_media: false}
  end
end
