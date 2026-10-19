defmodule Mix.Tasks.Assets.Copy do
  use Mix.Task
  @shortdoc "Copy official Phoenix browser modules into the application assets"
  def run(_) do
    for {dependency, file} <- [
          {:phoenix_html, "phoenix_html.js"},
          {:phoenix, "phoenix.mjs"},
          {:phoenix_live_view, "phoenix_live_view.esm.js"}
        ] do
      root = Mix.Project.deps_paths() |> Map.fetch!(dependency)

      File.cp!(
        Path.join([root, "priv", "static", file]),
        Path.join(["priv", "static", "assets", file])
      )
    end
  end
end
