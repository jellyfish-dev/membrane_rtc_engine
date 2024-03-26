defmodule Membrane.RTC.Engine.Endpoint.Recording.Storage.File do
  @moduledoc """
  `Membrane.RTC.Engine.Endpoint.Recording.Storage` implementation that saves the stream to files locally.
  """
  @behaviour Membrane.RTC.Engine.Endpoint.Recording.Storage

  @impl true
  def get_sink(config, %{output_dir: output_dir}) do
    location = Path.join(output_dir, config.filename)
    File.touch!(location)
    %Membrane.File.Sink{location: location}
  end

  @impl true
  def save_object(config, %{output_dir: output_dir}) do
    location = Path.join(output_dir, config.filename)

    with :ok <- File.touch(location) do
      File.write(location, config.object)
    end
  end

  @spec list_files(%{output_dir: Path.t()}) :: %{String.t() => size :: pos_integer()}
  def list_files(%{output_dir: output_dir}) do
    output_dir
    |> File.ls!()
    |> Enum.map(fn file ->
      path = Path.join(output_dir, file)
      %{size: size} = File.stat!(path)
      {file, size}
    end)
    |> Enum.into(%{})
  end

  @spec file_path(Path.t(), map()) :: Path.t()
  def file_path(filename, %{output_dir: output_dir}) do
    Path.join(output_dir, filename)
  end
end
