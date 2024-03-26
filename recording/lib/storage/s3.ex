defmodule Membrane.RTC.Engine.Endpoint.Recording.Storage.S3 do
  @moduledoc """
  `Membrane.RTC.Engine.Endpoint.Recording.Storage` implementation that saves the stream to the pointed AWS S3 bucket.
  """
  @behaviour Membrane.RTC.Engine.Endpoint.Recording.Storage

  require Membrane.Logger

  alias Membrane.RTC.Engine.Endpoint.Recording.Storage

  # minimal chunk size based on aws specification (in bytes)
  @chunk_size 5_242_880

  @type credentials_t :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          region: String.t(),
          bucket: String.t()
        }

  @type storage_opts :: %{:credentials => credentials_t(), optional(:path_prefix) => Path.t()}
  @type file_config :: %{files: [String.t()], storage: module(), opts: map()}
  @type s3_config :: %{config: map(), opts: storage_opts()}

  @impl true
  @spec get_sink(Storage.recording_config(), storage_opts()) :: struct()
  def get_sink(config, storage_opts) do
    path_prefix = Map.get(storage_opts, :path_prefix, "")
    path = Path.join([path_prefix, config.recording_id, config.filename])

    %__MODULE__.Sink{
      path: path,
      credentials: storage_opts.credentials,
      chunk_size: @chunk_size
    }
  end

  @impl true
  def save_object(config, storage_opts) do
    path_prefix = Map.get(storage_opts, :path_prefix, "")
    path = Path.join([path_prefix, config.recording_id, config.filename])
    credentials = storage_opts.credentials
    aws_config = create_aws_config(credentials)

    result =
      credentials.bucket
      |> ExAws.S3.put_object(path, config.object, [])
      |> ExAws.request(aws_config)

    case result do
      {:ok, %{status_code: 200}} -> :ok
      {:error, response} -> {:error, response}
    end
  end

  @spec create_aws_config(credentials_t()) :: list()
  def create_aws_config(credentials) do
    credentials
    |> Enum.reject(fn {key, _value} -> key == :bucket end)
    |> then(&ExAws.Config.new(:s3, &1))
    |> Map.to_list()
  end

  @spec try_to_fix_objects(file_config(), s3_config()) :: :ok | :error
  def try_to_fix_objects(file_config, s3_config) do
    with {:ok, objects} <- list_objects(s3_config),
         :ok <- fix_objects(file_config, s3_config, objects) do
      :ok
    else
      {:error, _reason} = error -> handle_error(error, s3_config.config)
    end
  end

  defp fix_objects(file_config, s3_config, objects) do
    if perform_object_fixes(file_config, s3_config, objects) do
      :ok
    else
      objects = Enum.map(objects, fn {filename, _size} -> filename end)

      case clean_objects(objects, s3_config.opts) do
        {:ok, _term} -> {:error, :failed_to_fix_objects}
        {:error, _reason} -> {:error, :failed_to_clean_objects}
      end
    end
  end

  defp perform_object_fixes(
         %{files: files, storage: file_storage, opts: file_opts},
         s3_config,
         objects
       ) do
    Enum.all?(files, fn {filename, size} ->
      s3_size_result = Map.fetch(objects, filename)

      case s3_size_result do
        {:ok, s3_size} when s3_size >= size ->
          true

        _else ->
          file = filename |> file_storage.file_path(file_opts) |> File.read!()
          config = save_object_config(file, s3_config.config, filename)

          case save_object(config, s3_config.opts) do
            :ok -> true
            {:error, _response} -> false
          end
      end
    end)
  end

  defp save_object_config(object, config, filename) do
    %{
      object: object,
      recording_id: config.recording_id,
      filename: filename
    }
  end

  defp list_objects(%{opts: opts, config: config}) do
    path_prefix =
      opts
      |> Map.get(:path_prefix, "")
      |> Path.join(config.recording_id)

    credentials = opts.credentials
    config = create_aws_config(credentials)

    response =
      credentials.bucket
      |> ExAws.S3.list_objects(prefix: path_prefix)
      |> ExAws.request(config)

    case response do
      {:ok, %{body: %{contents: contents}}} ->
        objects =
          Enum.map(contents, fn stats ->
            filename = stats.key |> String.split("/") |> List.last()
            size = String.to_integer(stats.size)
            {filename, size}
          end)
          |> Enum.into(%{})

        {:ok, objects}

      _else ->
        {:error, :list_objects}
    end
  end

  defp clean_objects(objects, %{credentials: credentials}) do
    config = create_aws_config(credentials)

    credentials.bucket
    |> ExAws.S3.delete_all_objects(objects)
    |> ExAws.request(config)
  end

  defp handle_error({:error, :list_objects}, options) do
    Membrane.Logger.error(
      "Couldn't list objects on S3 bucket, recording id: #{options.recording_id}"
    )

    :error
  end

  defp handle_error({:error, :failed_to_clean_objects}, options) do
    Membrane.Logger.error(
      "Couldn't clean objects on S3 bucket, recording id: #{options.recording_id}"
    )

    :error
  end

  defp handle_error(_error, _options), do: :error
end
