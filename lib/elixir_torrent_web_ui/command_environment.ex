defmodule ElixirTorrentWebUI.CommandEnvironment do
  @moduledoc false

  @sensitive_variables ~w(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    DATABASE_URL
    GITHUB_TOKEN
    HEX_API_KEY
    RELEASE_COOKIE
    SECRET_KEY_BASE
  )

  @spec scrubbed() :: %{String.t() => nil}
  def scrubbed do
    Map.new(@sensitive_variables, &{&1, nil})
  end
end
