defmodule Membrane.RTC.RecordingEndpointTest do
  use ExUnit.Case

  import Mox

  import FileEndpointGenerator
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.Recording, as: RecordingEndpoint
  alias Membrane.RTC.Engine.Endpoint.Recording.Storage
  alias Membrane.RTC.Engine.Message.{EndpointCrashed, EndpointRemoved, TrackAdded, TrackRemoved}

  @fixtures_dir "./test/fixtures/"
  @report_filename "report.json"
  @tracks_added_delay 500
  @tracks_removed_delay 15_000
  @report_delay 1_000

  # AWS test configuration
  @credentials %{
    access_key_id: "123456789",
    secret_access_key: "987654321",
    region: "eu-central-1",
    bucket: "bucket"
  }

  @etag 1
  @recording_id "recording_id"
  @upload_id "upload_id"
  @bucket_prefix "https://s3.eu-central-1.amazonaws.com/#{@credentials.bucket}/"
  @url_prefix @bucket_prefix <> "#{@recording_id}"

  setup do
    options = [id: "test_rtc"]
    {:ok, pid} = Engine.start_link(options, [])
    Engine.register(pid, self())
    on_exit(fn -> Engine.terminate(pid) end)

    [rtc_engine: pid]
  end

  setup :set_mox_from_context

  @tag :tmp_dir
  test "creates correct recording, one input", %{rtc_engine: rtc_engine, tmp_dir: output_dir} do
    recording_endpoint_id = "recording-endpoint"
    video_file_endpoint_id = "video-file-endpoint"

    video_file_path = Path.join(@fixtures_dir, "recorded_video.h264")
    deserialized_file_path = Path.join(output_dir, "deserialized.h264")
    report_file_path = Path.join(output_dir, @report_filename)

    recording_endpoint =
      create_recording_endpoint(rtc_engine, [{Storage.File, %{output_dir: output_dir}}])

    video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

    :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id}, @tracks_added_delay
    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay

    [filename] = File.ls!(output_dir)

    video_deserializer =
      create_video_deserializer(%{
        source: Path.join(output_dir, filename),
        output: deserialized_file_path,
        owner: self(),
        type: :video
      })

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: video_deserializer)

    assert_end_of_stream(pipeline, :sink)

    assert File.read!(video_file_path) == File.read!(deserialized_file_path)

    Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
    assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}

    await_report(report_file_path)
    validate_report(report_file_path)
  end

  @tag :tmp_dir
  test "creates correct recording, multiple inputs", %{
    rtc_engine: rtc_engine,
    tmp_dir: output_dir
  } do
    recording_endpoint_id = "recording-endpoint"
    audio_file_endpoint_id = "audio-file-endpoint"
    video_file_endpoint_id = "video-file-endpoint"

    audio_file_path = Path.join(@fixtures_dir, "audio.aac")
    video_file_path = Path.join(@fixtures_dir, "video_baseline.h264")
    report_file_path = Path.join(output_dir, @report_filename)

    deserialized_audio_path = Path.join(output_dir, "deserialized_audio.aac")
    deserialized_video_path = Path.join(output_dir, "deserialized_video.h264")

    recording_endpoint =
      create_recording_endpoint(rtc_engine, [{Storage.File, %{output_dir: output_dir}}])

    audio_file_endpoint = create_audio_file_endpoint(rtc_engine, audio_file_path)
    video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

    :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id}, @tracks_added_delay
    assert_receive %TrackAdded{endpoint_id: ^audio_file_endpoint_id}, @tracks_added_delay
    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay
    assert_receive %TrackRemoved{endpoint_id: ^audio_file_endpoint_id}

    Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
    assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}

    await_report(report_file_path)
    assert %{"tracks" => tracks} = report_file_path |> File.read!() |> Jason.decode!()

    {audio_file, _metadata} =
      Enum.find(tracks, fn {_filename, track} -> track["type"] == "audio" end)

    {video_file, _metadata} =
      Enum.find(tracks, fn {_filename, track} -> track["type"] == "video" end)

    audio_deserializer =
      create_audio_deserializer(%{
        source: Path.join(output_dir, audio_file),
        output: deserialized_audio_path,
        owner: self()
      })

    video_deserializer =
      create_video_deserializer(%{
        source: Path.join(output_dir, video_file),
        output: deserialized_video_path,
        owner: self()
      })

    audio_pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: audio_deserializer)
    video_pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: video_deserializer)

    assert_end_of_stream(audio_pipeline, :sink)
    assert_end_of_stream(video_pipeline, :sink)

    assert deserialized_audio_path |> File.read!() |> byte_size() > 0
    assert deserialized_video_path |> File.read!() |> byte_size() > 0
  end

  @tag :tmp_dir
  test "creates correct recording, multiple videos and audios", %{
    rtc_engine: rtc_engine,
    tmp_dir: output_dir
  } do
    recording_endpoint_id = "recording-endpoint"
    audio_file_endpoint_id1 = "audio-file-endpoint1"
    video_file_endpoint_id1 = "video-file-endpoint1"
    audio_file_endpoint_id2 = "audio-file-endpoint2"
    video_file_endpoint_id2 = "video-file-endpoint2"

    audio_file_path = Path.join(@fixtures_dir, "audio.aac")
    video_file_path = Path.join(@fixtures_dir, "video_baseline.h264")
    report_file_path = Path.join(output_dir, @report_filename)

    deserialized_audio_path = Path.join(output_dir, "deserialized_audio.aac")
    deserialized_video_path = Path.join(output_dir, "deserialized_video.h264")

    recording_endpoint =
      create_recording_endpoint(rtc_engine, [{Storage.File, %{output_dir: output_dir}}])

    audio_file_endpoint = create_audio_file_endpoint(rtc_engine, audio_file_path)
    video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

    :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id1)
    :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id1)

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id1}, @tracks_added_delay
    assert_receive %TrackAdded{endpoint_id: ^audio_file_endpoint_id1}, @tracks_added_delay

    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id2)
    :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id2)

    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id1}, @tracks_removed_delay
    assert_receive %TrackRemoved{endpoint_id: ^audio_file_endpoint_id1}, @tracks_removed_delay

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id2}, @tracks_added_delay
    assert_receive %TrackAdded{endpoint_id: ^audio_file_endpoint_id2}, @tracks_added_delay

    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id2}, @tracks_removed_delay
    assert_receive %TrackRemoved{endpoint_id: ^audio_file_endpoint_id2}, @tracks_removed_delay

    Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
    assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}

    await_report(report_file_path)
    validate_report(report_file_path)
    assert %{"tracks" => tracks} = report_file_path |> File.read!() |> Jason.decode!()

    audio_tracks = Enum.filter(tracks, fn {_filename, track} -> track["type"] == "audio" end)

    video_tracks = Enum.filter(tracks, fn {_filename, track} -> track["type"] == "video" end)

    audio_pipelines =
      audio_tracks
      |> Enum.with_index()
      |> Enum.map(fn {{filename, _track}, idx} ->
        output_filename = "#{deserialized_audio_path}_#{idx}"

        audio_deserializer =
          create_audio_deserializer(%{
            source: Path.join(output_dir, filename),
            output: output_filename,
            owner: self()
          })

        pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: audio_deserializer)

        {pid, output_filename}
      end)

    video_pipelines =
      video_tracks
      |> Enum.with_index()
      |> Enum.map(fn {{filename, _track}, idx} ->
        output_filename = "#{deserialized_video_path}_#{idx}"

        video_deserializer =
          create_video_deserializer(%{
            source: Path.join(output_dir, filename),
            output: output_filename,
            owner: self()
          })

        pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: video_deserializer)

        {pid, output_filename}
      end)

    Enum.each(audio_pipelines ++ video_pipelines, fn {pid, filename} ->
      assert_end_of_stream(pid, :sink)
      assert filename |> File.read!() |> byte_size() > 0
    end)
  end

  test "recording endpoint with aws storage", %{rtc_engine: rtc_engine} do
    recording_endpoint_id = "recording-endpoint"
    video_file_endpoint_id = "video-file-endpoint"

    video_file_path = Path.join(@fixtures_dir, "recorded_video.h264")
    setup_mock_http_request(5)

    recording_endpoint =
      create_recording_endpoint(rtc_engine, [{Storage.S3, %{credentials: @credentials}}])

    video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

    :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id}, @tracks_added_delay
    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay

    Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
    assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}

    assert_receive :upload_initialized
    assert_receive :chunk_uploaded
    assert_receive :upload_completed
    assert_receive :get_chunk_list
    assert_receive :report_uploaded

    verify!()
  end

  @tag :tmp_dir
  test "recording endpoint with aws and file storage", %{
    rtc_engine: rtc_engine,
    tmp_dir: output_dir
  } do
    recording_endpoint_id = "recording-endpoint"
    video_file_endpoint_id = "video-file-endpoint"

    video_file_path = Path.join(@fixtures_dir, "recorded_video.h264")
    setup_mock_http_request(7)

    recording_endpoint =
      create_recording_endpoint(rtc_engine, [
        {Storage.S3, %{credentials: @credentials}},
        {Storage.File, %{output_dir: output_dir}}
      ])

    video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

    :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
    :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

    assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id}, @tracks_added_delay
    assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay

    Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
    assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}

    assert_receive :upload_initialized
    assert_receive :chunk_uploaded
    assert_receive :upload_completed
    assert_receive :get_chunk_list

    # when file and s3 storage are used recording endpoint will try to fix uploaded files
    # based on locally saved files by file storage
    assert_receive :get_object_list
    assert_receive :object_uploaded

    assert_receive :report_uploaded

    verify!()
  end

  describe "crash groups" do
    setup :set_mox_from_context

    @tag :tmp_dir
    test "ensure the endpoint keeps working when a s3 sink crashes - file sink is also added", %{
      rtc_engine: rtc_engine,
      tmp_dir: output_dir
    } do
      recording_endpoint_id = "recording-endpoint"
      audio_file_endpoint_id = "audio-file-endpoint"
      video_file_endpoint_id = "video-file-endpoint"

      setup_mock_http_request(10)

      audio_file_path = Path.join(@fixtures_dir, "audio.aac")
      video_file_path = Path.join(@fixtures_dir, "recorded_video.h264")

      recording_endpoint =
        create_recording_endpoint(rtc_engine, [
          {Storage.S3, %{credentials: @credentials}},
          {Storage.File, %{output_dir: output_dir}}
        ])

      audio_file_endpoint = create_audio_file_endpoint(rtc_engine, audio_file_path)
      video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

      :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

      assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id, track_id: track_id},
                     @tracks_added_delay

      assert_receive %TrackAdded{endpoint_id: ^audio_file_endpoint_id}, @tracks_added_delay

      # After a while, simulate the crashing of some element in a track pipeline
      Process.sleep(2000)

      pid =
        Membrane.Testing.Pipeline.get_child_pid!(rtc_engine, [
          {:endpoint, recording_endpoint_id},
          {:sink, track_id, Storage.S3}
        ])

      Process.exit(pid, :brutal_kill)

      assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay
      assert_receive %TrackRemoved{endpoint_id: ^audio_file_endpoint_id}, @tracks_removed_delay

      refute_received %EndpointCrashed{endpoint_id: ^recording_endpoint_id}

      Engine.remove_endpoint(rtc_engine, recording_endpoint_id)
      assert_receive %EndpointRemoved{endpoint_id: ^recording_endpoint_id}
    end

    test "ensure the endpoint crashes when a s3 sink crases - file sink is not added", %{
      rtc_engine: rtc_engine
    } do
      recording_endpoint_id = "recording-endpoint"
      audio_file_endpoint_id = "audio-file-endpoint"
      video_file_endpoint_id = "video-file-endpoint"

      setup_mock_http_request(10)

      audio_file_path = Path.join(@fixtures_dir, "audio.aac")
      video_file_path = Path.join(@fixtures_dir, "recorded_video.h264")

      recording_endpoint =
        create_recording_endpoint(rtc_engine, [{Storage.S3, %{credentials: @credentials}}])

      audio_file_endpoint = create_audio_file_endpoint(rtc_engine, audio_file_path)
      video_file_endpoint = create_video_file_endpoint(rtc_engine, video_file_path)

      :ok = Engine.add_endpoint(rtc_engine, recording_endpoint, id: recording_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

      assert_receive %TrackAdded{endpoint_id: ^video_file_endpoint_id, track_id: track_id},
                     @tracks_added_delay

      assert_receive %TrackAdded{endpoint_id: ^audio_file_endpoint_id}, @tracks_added_delay

      # After a while, simulate the crashing of some element in a track pipeline
      Process.sleep(2000)

      pid =
        Membrane.Testing.Pipeline.get_child_pid!(rtc_engine, [
          {:endpoint, recording_endpoint_id},
          {:sink, track_id, Storage.S3}
        ])

      Process.exit(pid, :brutal_kill)

      assert_receive %TrackRemoved{endpoint_id: ^video_file_endpoint_id}, @tracks_removed_delay
      assert_receive %TrackRemoved{endpoint_id: ^audio_file_endpoint_id}, @tracks_removed_delay

      assert_received %EndpointCrashed{endpoint_id: ^recording_endpoint_id}
    end
  end

  defp create_recording_endpoint(rtc_engine, stores) do
    %RecordingEndpoint{
      rtc_engine: rtc_engine,
      recording_id: @recording_id,
      stores: stores
    }
  end

  defp create_video_deserializer(opts) do
    [
      child(:source, %Membrane.File.Source{location: opts.source})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:rtp, %Membrane.RTP.DepayloaderBin{
        depayloader: Membrane.RTP.H264.Depayloader,
        clock_rate: 90_000
      })
      |> child(:parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {60, 1}}
      })
      |> child(:sink, %Membrane.File.Sink{location: opts.output})
    ]
  end

  defp create_audio_deserializer(opts) do
    [
      child(:source, %Membrane.File.Source{location: opts.source})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:rtp, %Membrane.RTP.DepayloaderBin{
        depayloader: Membrane.RTP.Opus.Depayloader,
        clock_rate: 48_000
      })
      |> child(:sink, %Membrane.File.Sink{location: opts.output})
    ]
  end

  defp await_report(report_path) do
    # ms
    interval = 100
    iterations = div(@report_delay, interval)

    assert Enum.any?(1..iterations, fn _ ->
             Process.sleep(interval)
             File.exists?(report_path)
           end)
  end

  defp validate_report(report_path) do
    assert report_path |> File.read!() |> byte_size() > 0
  end

  defp setup_mock_http_request(request_no) do
    pid = self()

    expect(ExAws.Request.HttpMock, :request, request_no, fn method, url, body, _headers, _opts ->
      case %{method: method, url: url, body: body} do
        %{
          method: :post,
          url: @url_prefix <> _rest,
          body: <<>>
        } ->
          send(pid, :upload_initialized)

          {:ok,
           %{
             status_code: 200,
             body: """
             <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Bucket>#{@credentials.bucket}</Bucket>
               <Key>#{@recording_id}</Key>
               <UploadId>#{@upload_id}</UploadId>
             </InitiateMultipartUploadResult>
             """
           }}

        %{
          method: :post,
          url: @url_prefix <> _rest
        } ->
          send(pid, :upload_completed)

          {:ok,
           %{
             status_code: 200,
             body: """
             <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Location>https://s3-eu-west-1.amazonaws.com/#{@credentials.bucket}/#{@recording_id}</Location>
               <Bucket>#{@credentials.bucket}</Bucket>
               <Key>#{@recording_id}</Key>
               <ETag>&quot;17fbc0a106abbb6f381aac6e331f2a19-1&quot;</ETag>
             </CompleteMultipartUploadResult>
             """
           }}

        %{
          method: :put,
          url: @url_prefix <> "/report.json"
        } ->
          send(pid, :report_uploaded)
          {:ok, %{status_code: 200}}

        %{
          method: :put,
          url: @url_prefix <> url_suffix
        } ->
          if String.contains?(url_suffix, "partNumber"),
            do: send(pid, :chunk_uploaded),
            else: send(pid, :object_uploaded)

          {:ok,
           %{
             status_code: 200,
             headers: %{"ETag" => @etag}
           }}

        %{
          method: :get,
          url: @url_prefix <> _rest
        } ->
          send(pid, :get_chunk_list)
          {:ok, %{status_code: 400, reason: "reason"}}

        %{
          method: :get,
          url: @bucket_prefix <> _rest
        } ->
          send(pid, :get_object_list)

          {:ok,
           %{
             status_code: 200,
             # returns an empty list
             body: """
             <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Name>example-bucket</Name>
              <Prefix></Prefix>
              <Marker></Marker>
              <MaxKeys>1000</MaxKeys>
              <Delimiter>/</Delimiter>
              <IsTruncated>false</IsTruncated>
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
