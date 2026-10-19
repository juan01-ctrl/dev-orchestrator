defmodule DevOrchestrator.Intake.Signature do
  def valid_linear?(body, signature, secret, timestamp, now)
      when is_binary(body) and is_binary(signature) and is_binary(secret) and
             is_integer(timestamp) and is_integer(now) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    byte_size(secret) > 0 and byte_size(signature) == byte_size(expected) and
      abs(now - timestamp) <= 60_000 and :crypto.hash_equals(expected, signature)
  end

  def valid_linear?(_, _, _, _, _), do: false
end
