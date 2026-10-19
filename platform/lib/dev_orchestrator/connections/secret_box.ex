defmodule DevOrchestrator.Connections.SecretBox do
  @moduledoc "AES-GCM envelopes bound to the organization owning each secret."
  def seal(plaintext, organization, key) when byte_size(key) == 32 do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, organization, 16, true)

    <<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>
  end

  def open(
        <<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        organization,
        key
      )
      when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           organization,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :invalid_secret}
    end
  rescue
    _ -> {:error, :invalid_secret}
  end

  def open(_, _, _), do: {:error, :invalid_secret}
end
