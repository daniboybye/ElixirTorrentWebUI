defmodule ElixirTorrentWebUI.UiState do
  @moduledoc false

  use GenServer

  @default_theme "dark"
  @valid_themes ~w(light dark)

  @type t :: %{
          theme: String.t(),
          expanded: MapSet.t(String.t())
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: t()
  def get, do: GenServer.call(__MODULE__, :get)

  @spec put_theme(String.t()) :: :ok
  def put_theme(theme) when theme in @valid_themes do
    GenServer.call(__MODULE__, {:put_theme, theme})
  end

  @spec put_expanded(MapSet.t(String.t())) :: :ok
  def put_expanded(%MapSet{} = expanded) do
    GenServer.call(__MODULE__, {:put_expanded, expanded})
  end

  @impl true
  def init(_opts) do
    {:ok, load_from_disk()}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:put_theme, theme}, _from, state) do
    {:reply, :ok, persist(%{state | theme: theme})}
  end

  @impl true
  def handle_call({:put_expanded, expanded}, _from, state) do
    {:reply, :ok, persist(%{state | expanded: expanded})}
  end

  @spec path() :: Path.t()
  defp path do
    Path.join([File.cwd!(), "session", "ui.json"])
  end

  @spec persist(t()) :: t()
  defp persist(state) do
    File.mkdir_p!(Path.dirname(path()))

    payload = %{
      "theme" => state.theme,
      "expanded" => MapSet.to_list(state.expanded)
    }

    path() |> then(&File.write!(&1, Jason.encode!(payload)))
    state
  end

  @spec load_from_disk() :: t()
  defp load_from_disk do
    case File.read(path()) do
      {:ok, body} -> decode(body)
      {:error, :enoent} -> default()
      _ -> default()
    end
  end

  @spec decode(String.t()) :: t()
  defp decode(body) do
    with {:ok, %{"theme" => theme, "expanded" => expanded}} <- Jason.decode(body),
         true <- theme in @valid_themes,
         true <- is_list(expanded) do
      %{theme: theme, expanded: MapSet.new(expanded)}
    else
      _ -> default()
    end
  end

  @spec default() :: t()
  defp default do
    %{theme: @default_theme, expanded: MapSet.new()}
  end
end
