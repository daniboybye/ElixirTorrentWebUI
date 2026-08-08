defmodule ElixirTorrentWebUI.UiState do
  @moduledoc false

  use GenServer

  alias ElixirTorrentWebUI.Languages

  @default_theme "dark"
  @default_locale Languages.default()
  @valid_themes ~w(light dark)

  @type t :: %{
          theme: String.t(),
          locale: String.t(),
          download_folder: Path.t(),
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

  @spec put_locale(String.t()) :: :ok
  def put_locale(locale) when is_binary(locale) do
    GenServer.call(__MODULE__, {:put_locale, locale})
  end

  @spec put_download_folder(Path.t()) :: :ok
  def put_download_folder(folder) when is_binary(folder) do
    GenServer.call(__MODULE__, {:put_download_folder, folder})
  end

  @spec default_download_folder() :: Path.t()
  def default_download_folder do
    default_download_folder(:os.type(), &System.get_env/1)
  end

  @doc false
  @spec default_download_folder({atom(), atom()}, (String.t() -> String.t() | nil)) :: Path.t()
  def default_download_folder({:win32, _}, env) do
    base =
      env.("USERPROFILE") ||
        case {env.("HOMEDRIVE"), env.("HOMEPATH")} do
          {drive, path} when is_binary(drive) and is_binary(path) -> drive <> path
          _ -> File.cwd!()
        end

    Path.expand(Path.join(base, "Downloads"))
  end

  def default_download_folder(_os_type, env) do
    home =
      env.("HOME") ||
        raise "HOME is not set; cannot resolve default download folder"

    Path.expand(Path.join(home, "Downloads"))
  end

  @impl GenServer
  def init(_opts) do
    {:ok, load_from_disk()}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call({:put_theme, theme}, _from, state) do
    {:reply, :ok, persist(%{state | theme: theme})}
  end

  @impl GenServer
  def handle_call({:put_expanded, expanded}, _from, state) do
    {:reply, :ok, persist(%{state | expanded: expanded})}
  end

  @impl GenServer
  def handle_call({:put_locale, locale}, _from, state) do
    locale = normalize_locale(locale)
    {:reply, :ok, persist(%{state | locale: locale})}
  end

  @impl GenServer
  def handle_call({:put_download_folder, folder}, _from, state) do
    folder = normalize_download_folder(folder)
    {:reply, :ok, persist(%{state | download_folder: folder})}
  end

  @spec path() :: Path.t()
  defp path do
    Path.join([ElixirTorrentWebUI.DataDir.root(), "session", "ui.json"])
  end

  @spec persist(t()) :: t()
  defp persist(state) do
    File.mkdir_p!(Path.dirname(path()))

    payload = %{
      "theme" => state.theme,
      "locale" => state.locale,
      "download_folder" => state.download_folder,
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
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, theme, locale, download_folder, expanded} <- decode_fields(decoded) do
      %{
        theme: theme,
        locale: locale,
        download_folder: download_folder,
        expanded: MapSet.new(expanded)
      }
    else
      _ -> default()
    end
  end

  @spec decode_fields(map()) ::
          {:ok, String.t(), String.t(), Path.t(), list()} | :error
  defp decode_fields(%{"theme" => theme, "expanded" => expanded} = decoded)
       when theme in @valid_themes and is_list(expanded) do
    locale =
      decoded
      |> Map.get("locale", @default_locale)
      |> normalize_locale()

    download_folder =
      decoded
      |> Map.get("download_folder", default_download_folder())
      |> normalize_download_folder()

    {:ok, theme, locale, download_folder, expanded}
  end

  defp decode_fields(_), do: :error

  @spec normalize_locale(String.t()) :: String.t()
  defp normalize_locale(locale) do
    if Languages.valid?(locale), do: locale, else: @default_locale
  end

  @spec normalize_download_folder(Path.t()) :: Path.t()
  defp normalize_download_folder(folder) when is_binary(folder) do
    folder = Path.expand(folder)
    File.mkdir_p!(folder)
    folder
  end

  @spec default() :: t()
  defp default do
    %{
      theme: @default_theme,
      locale: @default_locale,
      download_folder: default_download_folder(),
      expanded: MapSet.new()
    }
  end
end
