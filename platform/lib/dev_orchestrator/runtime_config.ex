defmodule DevOrchestrator.RuntimeConfig do
  def public_origin!(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and uri.path in [nil, "", "/"] and is_nil(uri.query) and
         is_nil(uri.fragment) do
      String.trim_trailing(value, "/")
    else
      raise ArgumentError, "PUBLIC_URL must be an HTTPS origin without credentials, path or query"
    end
  end
end
