defmodule ElixirTorrentWebUI.CommandEnvironmentTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.CommandEnvironment

  test "clears credentials before spawning desktop commands" do
    assert CommandEnvironment.scrubbed() == %{
             "AWS_ACCESS_KEY_ID" => nil,
             "AWS_SECRET_ACCESS_KEY" => nil,
             "AWS_SESSION_TOKEN" => nil,
             "DATABASE_URL" => nil,
             "GITHUB_TOKEN" => nil,
             "HEX_API_KEY" => nil,
             "RELEASE_COOKIE" => nil,
             "SECRET_KEY_BASE" => nil
           }
  end
end
