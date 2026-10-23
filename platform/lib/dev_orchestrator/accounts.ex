defmodule DevOrchestrator.Accounts do
  @moduledoc "Accounts, expiring hashed session tokens and organization membership."
  alias DevOrchestrator.{Store, Notifier}
  alias DevOrchestrator.Accounts.Scope

  def register(%{"email" => email, "password" => password} = attrs)
      when is_binary(email) and is_binary(password) do
    email = String.downcase(String.trim(email))
    name = Map.get(attrs, "name", "My workspace")

    if byte_size(email) <= 254 and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email) and
         String.length(password) >= 12 and byte_size(password) <= 1024 and is_binary(name) and
         byte_size(name) in 1..100 do
      result =
        Store.transaction(fn ->
          if Store.one("SELECT id FROM users WHERE email=$1", [email]),
            do: Store.halt(:email_unavailable)

          user_id = Store.id()
          organization_id = Store.id()

          Store.exec("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)", [
            user_id,
            email,
            Pbkdf2.hash_pwd_salt(password)
          ])

          Store.exec("INSERT INTO organizations(id,name) VALUES($1,$2)", [organization_id, name])
          Store.exec("INSERT INTO memberships VALUES($1,$2,'owner')", [organization_id, user_id])
          token = issue_token(user_id, "verify", 3600)
          {%{id: user_id, email: email}, token}
        end)

      case result do
        {:ok, {user, token}} ->
          Notifier.account_link(
            email,
            :account_verification,
            "Verify your email",
            "/verify/" <> token
          )

          {:ok, user}

        error ->
          error
      end
    else
      {:error, :invalid_registration}
    end
  rescue
    Postgrex.Error -> {:error, :email_unavailable}
  end

  def register(_), do: {:error, :invalid_registration}

  def login(email, password)
      when is_binary(email) and is_binary(password) and byte_size(password) <= 1024 do
    user =
      Store.one("SELECT id,password_hash,verified_at FROM users WHERE email=$1", [
        String.downcase(String.trim(email))
      ])

    valid =
      if user,
        do: Pbkdf2.verify_pass(password, user["password_hash"]),
        else: Pbkdf2.no_user_verify()

    cond do
      valid != true -> {:error, :invalid_credentials}
      is_nil(user["verified_at"]) -> {:error, :unverified}
      true -> {:ok, issue_token(user["id"], "session", 60 * 60 * 24 * 7)}
    end
  end

  def login(_, _), do: {:error, :invalid_credentials}

  def from_session(token) when is_binary(token) do
    case Store.one(
           "SELECT user_id FROM account_tokens WHERE hash=$1 AND purpose='session' AND expires_at>now()",
           [Store.digest(token)]
         ) do
      nil -> {:error, :unauthenticated}
      row -> scope(row["user_id"])
    end
  end

  def from_session(_), do: {:error, :unauthenticated}

  def scope(user_id) do
    case Store.one(
           "SELECT u.id,u.email,u.verified_at,m.organization_id,m.role FROM users u JOIN memberships m ON m.user_id=u.id WHERE u.id=$1 ORDER BY m.organization_id LIMIT 1",
           [user_id]
         ) do
      nil ->
        {:error, :unauthenticated}

      %{"verified_at" => nil} ->
        {:error, :unverified}

      row ->
        {:ok,
         %Scope{
           user_id: row["id"],
           email: row["email"],
           organization_id: row["organization_id"],
           role: row["role"]
         }}
    end
  end

  def owner?(%Scope{role: "owner"}), do: true
  def owner?(_), do: false

  def logout(token) when is_binary(token),
    do: Store.exec("DELETE FROM account_tokens WHERE hash=$1", [Store.digest(token)])

  def logout(_), do: :ok

  def verify(token) when is_binary(token) do
    Store.transaction(fn ->
      case Store.one(
             "DELETE FROM account_tokens WHERE hash=$1 AND purpose='verify' AND expires_at>now() RETURNING user_id",
             [Store.digest(token)]
           ) do
        nil ->
          Store.halt(:invalid_token)

        row ->
          Store.exec("UPDATE users SET verified_at=now() WHERE id=$1", [row["user_id"]])
          :verified
      end
    end)
  end

  def request_reset(email) when is_binary(email) do
    if user =
         Store.one("SELECT id,email FROM users WHERE email=$1", [
           String.downcase(String.trim(email))
         ]) do
      token = issue_token(user["id"], "reset", 1800)

      Notifier.account_link(
        user["email"],
        :password_reset,
        "Reset your password",
        "/reset/" <> token
      )
    end

    :ok
  end

  def reset_password(token, password) when is_binary(token) and is_binary(password) do
    if String.length(password) >= 12 and byte_size(password) <= 1024 do
      Store.transaction(fn ->
        row =
          Store.one(
            "DELETE FROM account_tokens WHERE hash=$1 AND purpose='reset' AND expires_at>now() RETURNING user_id",
            [Store.digest(token)]
          ) || Store.halt(:invalid_token)

        Store.exec("UPDATE users SET password_hash=$2 WHERE id=$1", [
          row["user_id"],
          Pbkdf2.hash_pwd_salt(password)
        ])

        Store.exec(
          "DELETE FROM account_tokens WHERE user_id=$1 AND purpose IN ('session','reset')",
          [row["user_id"]]
        )

        :reset
      end)
    else
      {:error, :invalid_password}
    end
  end

  defp issue_token(user_id, purpose, seconds) do
    token = Store.token()

    Store.exec(
      "INSERT INTO account_tokens(hash,user_id,purpose,expires_at) VALUES($1,$2,$3,now()+$4::integer*interval '1 second')",
      [Store.digest(token), user_id, purpose, seconds]
    )

    token
  end
end
