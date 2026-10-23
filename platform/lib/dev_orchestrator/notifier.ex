defmodule DevOrchestrator.Mailer do
  use Swoosh.Mailer, otp_app: :dev_orchestrator
end

defmodule DevOrchestrator.Notifier do
  require Logger
  import Swoosh.Email

  def account_link(email, event, subject, path) do
    result =
      new()
      |> to(email)
      |> from({"Dev Orchestrator", Application.fetch_env!(:dev_orchestrator, :mail_from)})
      |> subject(subject)
      |> text_body(
        subject <> "\n\n" <> Application.fetch_env!(:dev_orchestrator, :public_url) <> path
      )
      |> DevOrchestrator.Mailer.deliver()

    case result do
      {:ok, _response} ->
        result

      {:error, {status, _provider_error}} when is_integer(status) ->
        Logger.error("transactional_email_delivery_failed event=#{event} status=#{status}")
        result

      {:error, reason} ->
        Logger.error(
          "transactional_email_delivery_failed event=#{event} reason=#{error_class(reason)}"
        )

        result
    end
  end

  defp error_class(%{__struct__: module}), do: inspect(module)
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_reason), do: "unknown"
end
