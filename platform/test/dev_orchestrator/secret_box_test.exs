defmodule DevOrchestrator.SecretBoxTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Connections.SecretBox

  test "encrypted provider secrets require the same key and organization binding" do
    key = :crypto.strong_rand_bytes(32)
    ciphertext = SecretBox.seal("token-private", "org-a", key)
    refute ciphertext =~ "token-private"
    assert {:ok, "token-private"} = SecretBox.open(ciphertext, "org-a", key)
    assert {:error, :invalid_secret} = SecretBox.open(ciphertext, "org-b", key)

    assert {:error, :invalid_secret} =
             SecretBox.open(ciphertext, "org-a", :crypto.strong_rand_bytes(32))

    assert {:error, :invalid_secret} = SecretBox.open("truncated", "org-a", key)
  end
end
