defmodule DevOrchestrator.Intake.LinearAssetsTest do
  use ExUnit.Case, async: true

  alias DevOrchestrator.Intake.LinearAssets

  test "extracts markdown images and file links" do
    markdown = """
    See ![diagram](https://uploads.linear.app/team/diagram.png) and [dataset.csv](https://uploads.linear.app/team/data.csv).
    """

    assert %{assets: [image, csv], skipped_count: 0} = LinearAssets.extract(markdown)
    assert image["source_url"] == "https://uploads.linear.app/team/diagram.png"
    assert image["filename_hint"] == "diagram.png"
    assert csv["filename_hint"] == "data.csv"
    assert image["id"] =~ ~r/^[0-9a-f-]{36}$/
    assert csv["id"] =~ ~r/^[0-9a-f-]{36}$/
    refute image["id"] == csv["id"]
  end

  test "deduplicates repeated upload URLs" do
    url = "https://uploads.linear.app/team/file.csv?signature=private"

    assert %{assets: [asset], skipped_count: 0} =
             LinearAssets.extract("![same](#{url})\n[again](#{url})")

    assert asset["source_url"] == url
  end

  test "rejects non Linear and lookalike hosts" do
    markdown = """
    [external](https://example.com/a.csv)
    [lookalike](https://uploads.linear.app.evil.example/a.csv)
    [userinfo](https://user@uploads.linear.app/a.csv)
    [http](http://uploads.linear.app/a.csv)
    """

    assert %{assets: [], skipped_count: 0} = LinearAssets.extract(markdown)
  end

  test "caps the manifest at ten assets" do
    markdown = Enum.map_join(1..12, "\n", fn n -> "https://uploads.linear.app/team/#{n}.csv" end)

    assert %{assets: assets, skipped_count: 2} = LinearAssets.extract(markdown)
    assert length(assets) == 10
    assert Enum.map(assets, & &1["filename_hint"]) == Enum.map(1..10, &"#{&1}.csv")
  end

  test "removes private Linear upload URLs from the task prompt but preserves other references" do
    description =
      "See [diagram](https://uploads.linear.app/team/image.png?signature=private). Also https://example.com/spec"

    sanitized = LinearAssets.sanitize_description(description)

    assert sanitized =~ "[diagram]([Linear attachment])."
    assert sanitized =~ "https://example.com/spec"
    refute sanitized =~ "uploads.linear.app"
    refute sanitized =~ "signature=private"
  end
end
