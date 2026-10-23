defmodule DevOrchestrator.Intake.Signature do
  def valid_linear?(body, signature, secret, timestamp, now)
      when is_binary(body) and is_binary(signature) and is_binary(secret) and
             is_integer(timestamp) and is_integer(now) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    byte_size(secret) > 0 and byte_size(signature) == byte_size(expected) and
      abs(now - timestamp) <= 60_000 and :crypto.hash_equals(expected, signature)
  end

  def valid_linear?(_, _, _, _, _), do: false

  def valid_slack?(body, signature, timestamp, secret, now)
      when is_binary(body) and is_binary(signature) and is_binary(timestamp) and
             is_binary(secret) and is_integer(now) do
    with {seconds, ""} <- Integer.parse(timestamp),
         true <- byte_size(secret) > 0 and abs(now - seconds) <= 300 do
      expected =
        :crypto.mac(:hmac, :sha256, secret, "v0:" <> timestamp <> ":" <> body)
        |> Base.encode16(case: :lower)

      supplied = String.replace_prefix(signature, "v0=", "")

      String.starts_with?(signature, "v0=") and byte_size(supplied) == byte_size(expected) and
        :crypto.hash_equals(expected, supplied)
    else
      _ -> false
    end
  end

  def valid_slack?(_, _, _, _, _), do: false
end
