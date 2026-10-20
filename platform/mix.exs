defmodule DevOrchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :dev_orchestrator,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: ["test/offline.exs"],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application,
    do: [
      mod: {DevOrchestrator.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl]
    ]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.4"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.10"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.19"},
      {:gen_smtp, "~> 1.3"},
      {:pbkdf2_elixir, "~> 2.3"},
      {:lazy_html, "~> 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.copy", "ecto.create", "ecto.migrate"],
      "phx.server": ["assets.copy", "phx.server"],
      test: ["assets.copy", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
