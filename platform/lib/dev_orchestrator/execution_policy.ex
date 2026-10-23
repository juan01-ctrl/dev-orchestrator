defmodule DevOrchestrator.ExecutionPolicy do
  @moduledoc "Server-owned, immutable model and capability policy for each claimed task."

  @fallback_models %{
    routine: "gpt-6-luna",
    advanced: "gpt-6.1-sol",
    supported: ["gpt-6-luna", "gpt-6.1-sol"],
    network_hosts: [
      "registry.npmjs.org",
      "hex.pm",
      "repo.hex.pm",
      "pypi.org",
      "files.pythonhosted.org",
      "github.com"
    ]
  }

  def catalog do
    Application.get_env(:dev_orchestrator, :codex_models, @fallback_models)
    |> Map.new()
    |> Map.update(:supported, @fallback_models.supported, &normalize_models/1)
    |> Map.update(:network_hosts, @fallback_models.network_hosts, &normalize_hosts/1)
  end

  def supported_models, do: catalog().supported

  def valid_override?(nil), do: true
  def valid_override?(""), do: true
  def valid_override?(model) when is_binary(model), do: model in supported_models()
  def valid_override?(_), do: false

  def for_task(project, run) do
    config = catalog()
    classification = classify(run["title"], run["prompt"])
    recommended = if classification == "routine", do: config.routine, else: config.advanced
    override = project["model"]
    model = if is_binary(override) and override != "", do: override, else: recommended
    valid = model in config.supported

    %{
      "classification" => classification,
      "model" => if(valid, do: model, else: nil),
      "effort" => if(classification == "routine", do: "low", else: "high"),
      "valid" => valid,
      "error" => if(valid, do: nil, else: "unsupported_model"),
      "permissions" => %{
        "filesystem" => "project_workspace",
        "git" => ["local_branch", "commit"],
        "project_skills" => true,
        "global_configuration" => false,
        "deployment" => false
      },
      "network" => %{
        "mode" => "exact_host_amendments_only",
        "allowed_hosts" => config.network_hosts
      }
    }
  end

  defp classify(title, prompt) do
    text = [title, prompt] |> Enum.filter(&is_binary/1) |> Enum.join(" ")

    if Regex.match?(
         ~r/\b(plan(?:ning)?|review|fix(?:es|ing)?|bug|security|refactor|rework|repair|investigat(?:e|ion))\b/i,
         text
       ), do: "advanced", else: "routine"
  end

  defp normalize_models(values) when is_list(values),
    do: values |> Enum.filter(&valid_model_id?/1) |> Enum.uniq()

  defp normalize_models(_), do: @fallback_models.supported

  defp normalize_hosts(values) when is_list(values),
    do: values |> Enum.filter(&valid_hostname?/1) |> Enum.uniq()

  defp normalize_hosts(_), do: @fallback_models.network_hosts

  defp valid_model_id?(value),
    do: is_binary(value) and Regex.match?(~r/\Agpt-[a-z0-9.-]{2,80}\z/, value)

  defp valid_hostname?(value),
    do:
      is_binary(value) and
        Regex.match?(
          ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i,
          value
        )
end
