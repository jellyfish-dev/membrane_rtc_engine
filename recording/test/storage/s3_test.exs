defmodule Membrane.RTC.Engine.Endpoint.Recording.Storage.S3Test do
  use ExUnit.Case, async: false

  import MockTrack
  import Mox

  alias Membrane.RTC.Engine.Endpoint.Recording.{Reporter, Storage}

  @credentials %{
    access_key_id: "123456789",
    secret_access_key: "987654321",
    region: "eu-central-1",
    bucket: "bucket"
  }

  @path_prefix "path_prefix"
  @file_config %{output_dir: "test/fixtures"}
  @storage_config %{credentials: @credentials, path_prefix: @path_prefix}
  @url_prefix "https://s3.eu-central-1.amazonaws.com/#{@credentials.bucket}/"

  @correct_files """
  <Contents>
    <Key>empty.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>0</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>small.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>5242880</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>big.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>12582912</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  """

  @one_smaller_file """
  <Contents>
    <Key>empty.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>0</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>small.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>524288</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>big.txt</Key>
    <LastModified>2011-02-26T01:56:20.000Z</LastModified>
    <ETag>&quot;bf1d737a4d46a19f3bced6905cc8b902&quot;</ETag>
    <Size>12582912</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  """

  @no_files ""

  test "create s3 sink" do
    filename = "track_1"
    recording_id = "recording_id"

    config = %{
      track: %{},
      recording_id: recording_id,
      filename: filename
    }

    path = Path.join(recording_id, filename)
    path_with_prefix = Path.join([@path_prefix, recording_id, filename])

    assert %Storage.S3.Sink{
             credentials: @credentials,
             path: ^path_with_prefix,
             chunk_size: _chunk_size
           } = Storage.S3.get_sink(config, @storage_config)

    assert %Storage.S3.Sink{credentials: @credentials, path: ^path, chunk_size: _chunk_size} =
             Storage.S3.get_sink(config, %{credentials: @credentials})
  end

  setup :verify_on_exit!
  setup :set_mox_from_context

  test "save report" do
    {:ok, reporter} = Reporter.start(UUID.uuid4())

    filename = "track_1.msr"
    recording_id = "recording_id"
    track = create_track(:video)
    offset = 0

    :ok = Reporter.add_track(reporter, track, filename, offset)
    :ok = Reporter.start_timestamp(reporter, track.id, offset)

    report_json =
      reporter
      |> Reporter.get_report()
      |> Jason.encode!()

    config = %{
      object: report_json,
      recording_id: recording_id,
      filename: "report.json"
    }

    setup_mock_http_request(report_json)

    :ok = Storage.S3.save_object(config, @storage_config)
    :ok = Reporter.stop(reporter)
  end

  describe "fix recrodings" do
    setup :verify_on_exit!
    setup :set_mox_from_context

    test "sends all files when bucket is empty" do
      setup_aws_mock_request(4, @no_files)

      file_config = %{
        files: Storage.File.list_files(@file_config),
        opts: @file_config,
        storage: Storage.File
      }

      s3_config = %{config: %{recording_id: "recording_id"}, opts: @storage_config}

      Storage.S3.try_to_fix_objects(file_config, s3_config)

      assert_received :get_object_list

      assert_received :object_uploaded
      assert_received :object_uploaded
      assert_received :object_uploaded
    end

    test "sends no files when bucket is correct" do
      setup_aws_mock_request(1, @correct_files)

      file_config = %{
        files: Storage.File.list_files(@file_config),
        opts: @file_config,
        storage: Storage.File
      }

      s3_config = %{config: %{recording_id: "recording_id"}, opts: @storage_config}

      Storage.S3.try_to_fix_objects(file_config, s3_config)

      assert_received :get_object_list
      refute_received :object_uploaded
    end

    test "sends one file when bucket has no file smaller" do
      setup_aws_mock_request(2, @one_smaller_file)

      file_config = %{
        files: Storage.File.list_files(@file_config),
        opts: @file_config,
        storage: Storage.File
      }

      s3_config = %{config: %{recording_id: "recording_id"}, opts: @storage_config}

      Storage.S3.try_to_fix_objects(file_config, s3_config)

      assert_received :get_object_list
      assert_received :object_uploaded
    end

    test "cleanup bucket when error occured while sending a file to s3 bucket" do
      setup_aws_mock_request(3, @one_smaller_file, true)

      file_config = %{
        files: Storage.File.list_files(@file_config),
        opts: @file_config,
        storage: Storage.File
      }

      s3_config = %{config: %{recording_id: "recording_id"}, opts: @storage_config}

      Storage.S3.try_to_fix_objects(file_config, s3_config)

      assert_received :get_object_list
      assert_received :object_rejected
      assert_receive :objects_deleted
    end
  end

  defp setup_mock_http_request(report) do
    expect(ExAws.Request.HttpMock, :request, 1, fn method, _url, body, _headers, _opts ->
      assert report == body
      assert method == :put

      {:ok, %{status_code: 200}}
    end)
  end

  defp setup_aws_mock_request(request_no, contents, should_fail \\ false) do
    pid = self()

    expect(ExAws.Request.HttpMock, :request, request_no, fn method, url, _body, _headers, _opts ->
      case %{method: method, url: url, should_fail: should_fail} do
        %{
          method: :post,
          url: @url_prefix <> _rest
        } ->
          send(pid, :objects_deleted)
          {:ok, %{status_code: 200}}

        %{
          method: :put,
          url: @url_prefix <> _rest,
          should_fail: false
        } ->
          send(pid, :object_uploaded)
          {:ok, %{status_code: 200}}

        %{
          method: :put,
          url: @url_prefix <> _rest,
          should_fail: true
        } ->
          send(pid, :object_rejected)

          {:ok,
           %{
             status_code: 400,
             reason: "reason"
           }}

        %{
          method: :get,
          url: @url_prefix <> _rest
        } ->
          send(pid, :get_object_list)

          {:ok,
           %{
             status_code: 200,
             body: """
             <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Name>example-bucket</Name>
              <Prefix></Prefix>
              <Marker></Marker>
              <MaxKeys>1000</MaxKeys>
              <Delimiter>/</Delimiter>
              <IsTruncated>false</IsTruncated>
              #{contents}
              <CommonPrefixes>
                <Prefix>photos/</Prefix>
              </CommonPrefixes>
             </ListBucketResult>
             """
           }}
      end
    end)
  end
end
