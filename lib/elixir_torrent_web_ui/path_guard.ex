defmodule ElixirTorrentWebUI.PathGuard do
  @moduledoc false

  @windows_absolute ~r/^[A-Za-z]:[\\\/]/

  @spec safe_join(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, :invalid_path}
  def safe_join(base, relative) when is_binary(base) and is_binary(relative) do
    base = Path.expand(base)

    with :ok <- validate_relative(relative),
         path <- Path.expand(Path.join(base, relative)),
         true <- within_base?(path, base) do
      {:ok, path}
    else
      _ -> {:error, :invalid_path}
    end
  end

  def safe_join(_base, _relative), do: {:error, :invalid_path}

  defp validate_relative(relative) do
    segments = String.split(relative, ["/", "\\"], trim: true)

    cond do
      relative == "" -> {:error, :invalid_path}
      String.contains?(relative, <<0>>) -> {:error, :invalid_path}
      Path.type(relative) != :relative -> {:error, :invalid_path}
      Regex.match?(@windows_absolute, relative) -> {:error, :invalid_path}
      String.starts_with?(relative, ["\\\\", "//"]) -> {:error, :invalid_path}
      Enum.any?(segments, &(&1 == "..")) -> {:error, :invalid_path}
      true -> :ok
    end
  end

  defp within_base?(path, base) do
    case Path.relative_to(path, base) do
      "." -> true
      relative -> Path.type(relative) == :relative and not escapes?(relative)
    end
  end

  defp escapes?(relative) do
    relative
    |> Path.split()
    |> List.first()
    |> Kernel.==("..")
  end
end
