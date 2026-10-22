defmodule DevOrchestrator.Connections.OAuth do
  alias DevOrchestrator.Connections.HTTP
  def config("github"), do: Application.get_env(:dev_orchestrator, :github, [])
  def config("linear"), do: Application.get_env(:dev_orchestrator, :linear, [])
  def config("slack"), do: Application.get_env(:dev_orchestrator, :slack, [])
  def config(_), do: []

  def configured?(provider) when provider in ~w(github linear slack) do
    config = config(provider)

    fields =
      if provider == "github",
        do: [:client_id, :client_secret, :app_id, :private_key_path, :app_slug],
        else: [:client_id, :client_secret]

    Enum.all?(fields, &(is_binary(config[&1]) and config[&1] != ""))
  end

  def configured?(_), do: false

  def redirect_uri(provider),
    do:
      Application.fetch_env!(:dev_orchestrator, :public_url) <>
        "/connections/" <> provider <> "/callback"

  def authorize_url(provider, state) do
    {url, scope} =
      case provider do
        "slack" ->
          {"https://slack.com/oauth/v2/authorize", "chat:write,channels:read,groups:read"}

        "linear" ->
          {"https://linear.app/oauth/authorize", "read,write"}

        "github" ->
          {"https://github.com/login/oauth/authorize", ""}
      end

    url <>
      "?" <>
      URI.encode_query(%{
        client_id: config(provider)[:client_id],
        redirect_uri: redirect_uri(provider),
        scope: scope,
        state: state,
        response_type: "code"
      })
  end

  def exchange(provider, code) when provider in ~w(slack linear github) and is_binary(code) do
    token_request(provider,
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri(provider)
    )
  end

  def refresh(provider, refresh_token) when provider in ~w(slack linear),
    do: token_request(provider, grant_type: "refresh_token", refresh_token: refresh_token)

  defp token_request(provider, grant) do
    url =
      case provider do
        "slack" -> "https://slack.com/api/oauth.v2.access"
        "linear" -> "https://api.linear.app/oauth/token"
        "github" -> "https://github.com/login/oauth/access_token"
      end

    form =
      [client_id: config(provider)[:client_id], client_secret: config(provider)[:client_secret]] ++
        grant

    with {:ok, %{"access_token" => token} = body} when is_binary(token) <-
           HTTP.request(:post, url, form: form, headers: [{"accept", "application/json"}]) do
      if body["ok"] == false do
        {:error, :provider_rejected}
      else
        expires =
          if is_integer(body["expires_in"]),
            do: System.system_time(:second) + body["expires_in"],
            else: nil

        {:ok, Map.merge(body, %{"expires_at" => expires})}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end
end
