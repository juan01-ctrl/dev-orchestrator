defmodule DevOrchestrator.Mailer do
  use Swoosh.Mailer, otp_app: :dev_orchestrator
end

defmodule DevOrchestrator.Notifier do
  import Swoosh.Email

  def account_link(email, subject, path) do
    new()
    |> to(email)
    |> from({"Dev Orchestrator", Application.fetch_env!(:dev_orchestrator, :mail_from)})
    |> subject(subject)
    |> text_body(
      subject <> "\n\n" <> Application.fetch_env!(:dev_orchestrator, :public_url) <> path
    )
    |> DevOrchestrator.Mailer.deliver()
  end
end
