defmodule Membrane.RTC.HLSEndpointTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias ExSDP.Attribute.FMTP
  alias Membrane.HTTPAdaptiveStream.Storages.SendStorage
  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.File, as: FileEndpoint
  alias Membrane.RTC.Engine.Endpoint.HLS
  alias Membrane.RTC.Engine.Endpoint.HLS.{HLSConfig, MixerConfig}
  alias Membrane.RTC.Engine.Message

  @fixtures_dir "./test/fixtures/"
  @playlist_playable_delay 20_000
  @segment_delay 25_000
  @tracks_added_delay 500

  setup do
    options = [
      id: "test_rtc"
    ]

    {:ok, pid} = Engine.start_link(options, [])

    Engine.register(pid, self())

    on_exit(fn ->
      Engine.terminate(pid)
    end)

    [rtc_engine: pid]
  end

  describe "HLS Endpoint test" do
    @describetag :tmp_dir

    # FIXME: Test prints logs informing of parent crashing (HLS Endpoint)
    test "creates correct hls stream from single (h264) input", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      file_endpoint_id = "file-endpoint-id"

      file_name = "video.h264"
      file_path = Path.join(@fixtures_dir, file_name)

      hls_endpoint_id = "hls-endpoint"
      stream_id = "test-stream"

      output_dir = Path.join([tmp_dir, stream_id])

      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :single)
      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)

      file_endpoint = create_video_file_endpoint(rtc_engine, file_path, stream_id: stream_id)

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :video, ^output_dir}, @playlist_playable_delay)
      assert_receive({:segment, "video_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{video_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_separate_hls_playlist(output_dir, 2, 2)
    end

    test "creates correct hls stream with manual track addition", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      file_endpoint_id = "file-endpoint-id"

      file_name = "video.h264"
      file_path = Path.join(@fixtures_dir, file_name)

      hls_endpoint_id = "hls-endpoint"
      stream_id = "test-stream"

      output_dir = Path.join([tmp_dir, stream_id])

      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :single)
      hls_endpoint = %{hls_endpoint | subscribe_mode: :manual}
      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)

      file_endpoint =
        create_video_file_endpoint(rtc_engine, file_path, stream_id: stream_id, autoplay: false)

      :erlang.trace(:all, true, [:call])
      :erlang.trace_pattern({Engine, :subscribe, 4}, true, [:local])

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive %Message.TrackAdded{track_id: track_id}

      refute_receive {:trace, _pid, :call,
                      {Membrane.RTC.Engine, :subscribe,
                       [^rtc_engine, "hls-endpoint", ^track_id, _opts]}},
                     @tracks_added_delay

      Engine.message_endpoint(rtc_engine, hls_endpoint_id, {:subscribe, [track_id]})

      assert_receive {:trace, _pid, :call,
                      {Membrane.RTC.Engine, :subscribe,
                       [^rtc_engine, "hls-endpoint", ^track_id, _opts]}},
                     @tracks_added_delay

      FileEndpoint.start_sending(rtc_engine, file_endpoint_id)

      assert_receive({:playlist_playable, :video, ^output_dir}, @playlist_playable_delay)
      assert_receive({:segment, "video_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{video_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_separate_hls_playlist(output_dir, 2, 2)
    end

    test "creates correct hls stream from multiple (h264, opus) inputs belonging to the same stream",
         %{rtc_engine: rtc_engine, tmp_dir: tmp_dir} do
      video_file_endpoint_id = "video-file-endpoint"
      audio_file_endpoint_id = "audio-file-endpoint"

      video_file_name = "video.h264"
      video_file_path = Path.join(@fixtures_dir, video_file_name)

      hls_endpoint_id = "hls-endpoint"
      stream_id = "test-stream"

      output_dir = Path.join([tmp_dir, stream_id])

      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :multiple)

      audio_file_endpoint = create_audio_file_endpoint(rtc_engine, stream_id)

      video_file_endpoint =
        create_video_file_endpoint(
          rtc_engine,
          video_file_path,
          stream_id: stream_id
        )

      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^video_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^audio_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :video, ^output_dir}, @playlist_playable_delay)
      assert_receive({:playlist_playable, :audio, ^output_dir}, @playlist_playable_delay)

      assert_receive({:segment, "video_segment_1" <> _}, @segment_delay)
      assert_receive({:segment, "audio_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{audio_segments: 2}})
      assert_receive({:manifest, %{video_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_separate_hls_playlist(output_dir, 2, 3)
    end

    test "cleanup work properly", %{rtc_engine: rtc_engine, tmp_dir: tmp_dir} do
      video_file_endpoint_id = "video-file-endpoint"
      audio_file_endpoint_id = "audio-file-endpoint"

      video_file_name = "video.h264"
      video_file_path = Path.join(@fixtures_dir, video_file_name)

      hls_endpoint_id = "hls-endpoint"
      stream_id = "test-stream"

      output_dir = Path.join([tmp_dir, stream_id])

      pid = self()

      storage = fn _directory -> %SendStorage{destination: pid} end

      hls_endpoint = %HLS{
        rtc_engine: rtc_engine,
        owner: self(),
        output_directory: tmp_dir,
        synchronize_tracks?: false,
        hls_config: %HLSConfig{
          mode: :vod,
          target_window_duration: :infinity,
          hls_mode: :separate_av,
          segment_duration: Membrane.Time.seconds(3),
          cleanup_after: Membrane.Time.seconds(1),
          storage: storage
        }
      }

      audio_file_endpoint = create_audio_file_endpoint(rtc_engine, stream_id, autoend: false)

      video_file_endpoint =
        create_video_file_endpoint(
          rtc_engine,
          video_file_path,
          stream_id: stream_id,
          autoend: false
        )

      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^video_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^audio_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :video, ^output_dir}, @playlist_playable_delay)
      assert_receive({:playlist_playable, :audio, ^output_dir}, @playlist_playable_delay)

      Enum.each(1..7, fn _idx ->
        assert_receive {SendStorage, :store, %{type: :segment}}, 5000
      end)

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      manifests_no = 2
      headers_no = 2
      segments_no = 7

      assert_receive {SendStorage, :remove, %{type: :manifest, name: "index.m3u8"}}, 5000

      Enum.each(1..manifests_no, fn _idx ->
        assert_receive {SendStorage, :remove, %{type: :manifest}}, 5000
      end)

      Enum.each(1..headers_no, fn _idx ->
        assert_receive {SendStorage, :remove, %{type: :header}}, 5000
      end)

      Enum.each(1..segments_no, fn _idx ->
        assert_receive {SendStorage, :remove, %{type: :segment}}, 5000
      end)
    end

    @tag :gpu
    test "creates correct hls stream from multiple (h264, opus) inputs belonging to the same stream, muxed segments plus mixer",
         %{rtc_engine: rtc_engine, tmp_dir: tmp_dir} do
      video_file_endpoint_id = "video-file-endpoint"
      audio_file_endpoint_id = "audio-file-endpoint"

      video_file_name = "video.h264"
      video_file_path = Path.join(@fixtures_dir, video_file_name)

      hls_endpoint_id = "hls-endpoint"
      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :muxed, %MixerConfig{})

      audio_file_endpoint = create_audio_file_endpoint(rtc_engine)

      video_file_endpoint =
        create_video_file_endpoint(
          rtc_engine,
          video_file_path
        )

      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)
      :ok = Engine.add_endpoint(rtc_engine, video_file_endpoint, id: video_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^video_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      :ok = Engine.add_endpoint(rtc_engine, audio_file_endpoint, id: audio_file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^audio_file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :video, ^tmp_dir}, @playlist_playable_delay)
      assert_receive({:segment, "muxed_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{muxed_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_muxed_hls_playlist(tmp_dir, 2, 2)
    end

    @tag :gpu
    test "video mixer works properly", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      file_name = "video.h264"
      file_path = Path.join(@fixtures_dir, file_name)

      hls_endpoint_id = "hls-endpoint"
      file_endpoint_id = "video-mixer-file-endpoint-id"
      file_endpoint_id_2 = "video-mixer-file-endpoint-id_2"

      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :multiple, %MixerConfig{})
      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)

      file_endpoint = create_video_file_endpoint(rtc_engine, file_path)

      file_endpoint_2 =
        create_video_file_endpoint(
          rtc_engine,
          file_path
        )

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint_2, id: file_endpoint_id_2)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id_2,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :audio, ^tmp_dir}, @playlist_playable_delay)
      assert_receive({:playlist_playable, :video, ^tmp_dir}, @playlist_playable_delay)

      assert_receive({:segment, "video_segment_1" <> _}, @segment_delay)
      assert_receive({:segment, "audio_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{audio_segments: 2}})
      assert_receive({:manifest, %{video_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_separate_hls_playlist(tmp_dir, 2, 3)
    end

    @tag :gpu
    test "audio mixer works properly", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      hls_endpoint_id = "hls-endpoint"

      file_endpoint_id = "audio-mixer-file-endpoint-id"
      file_endpoint_id_2 = "audio-mixer-file-endpoint-id_2"

      hls_endpoint = create_hls_endpoint(rtc_engine, tmp_dir, :multiple, %MixerConfig{})
      :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)

      file_endpoint = create_audio_file_endpoint(rtc_engine)

      file_endpoint_2 = create_audio_file_endpoint(rtc_engine)

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      :ok = Engine.add_endpoint(rtc_engine, file_endpoint_2, id: file_endpoint_id_2)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id_2,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive({:playlist_playable, :audio, ^tmp_dir}, @playlist_playable_delay)
      assert_receive({:playlist_playable, :video, ^tmp_dir}, @playlist_playable_delay)

      assert_receive({:segment, "video_segment_1" <> _}, @segment_delay)
      assert_receive({:segment, "audio_segment_1" <> _}, @segment_delay)
      assert_receive({:manifest, %{audio_segments: 2}})
      assert_receive({:manifest, %{video_segments: 2}})

      Engine.remove_endpoint(rtc_engine, hls_endpoint_id)

      check_separate_hls_playlist(tmp_dir, 2, 3)
    end
  end

  defp create_hls_endpoint(rtc_engine, output_dir, input_type, mixer_config \\ nil) do
    pid = self()

    should_stop? =
      case input_type do
        :single ->
          fn
            %{video_segments: video} ->
              video > 1
          end

        :muxed ->
          fn
            %{muxed_segments: muxed} ->
              muxed > 1
          end

        :multiple ->
          fn
            %{video_segments: video, audio_segments: audio} ->
              video > 1 and audio > 1
          end
      end

    storage = fn directory ->
      %Membrane.RTC.Engine.Support.HLSStorage{
        pid: pid,
        file_storage: Membrane.RTC.Engine.Endpoint.HLS.HLSConfig.default_storage(directory),
        should_stop?: should_stop?
      }
    end

    hls_mode = if input_type == :muxed, do: :muxed_av, else: :separate_av

    %HLS{
      rtc_engine: rtc_engine,
      owner: self(),
      output_directory: output_dir,
      synchronize_tracks?: false,
      mixer_config: mixer_config,
      hls_config: %HLSConfig{
        mode: :vod,
        target_window_duration: :infinity,
        hls_mode: hls_mode,
        segment_duration: Membrane.Time.seconds(3),
        storage: storage
      }
    }
  end

  defp check_muxed_hls_playlist(output_dir, segments_number, manifests_number) do
    output_files = File.ls!(output_dir) |> Enum.sort()

    manifest_files = Enum.filter(output_files, &is_m3u8_file?(&1))
    muxed_manifest = find_muxed_manifest(manifest_files, output_dir)
    headers = find_headers(output_files)

    segment_sizes = extract_segment_sizes(muxed_manifest, output_dir, segments_number)

    assert Enum.count(manifest_files) == manifests_number

    # There should exactly one header for each manifest, except for master manifest
    assert Enum.count(headers) == manifests_number - 1

    assert Enum.count(segment_sizes) == segments_number
    assert Enum.all?(segment_sizes, &(&1 > 0))
  end

  defp check_separate_hls_playlist(output_dir, segments_number, manifests_number) do
    output_files = File.ls!(output_dir) |> Enum.sort()

    manifest_files = Enum.filter(output_files, &is_m3u8_file?(&1))
    stream_manifests = find_stream_manifests(manifest_files, output_dir)
    headers = find_headers(output_files)

    segment_sizes =
      Enum.map(stream_manifests, &extract_segment_sizes(&1, output_dir, segments_number))

    assert Enum.count(manifest_files) == manifests_number

    # There should exactly one header for each manifest, except for master manifest
    assert Enum.count(headers) == manifests_number - 1

    Enum.each(segment_sizes, fn segment_sizes ->
      assert Enum.count(segment_sizes) == segments_number
      assert Enum.all?(segment_sizes, &(&1 > 0))
    end)
  end

  defp is_m3u8_file?(filename) do
    String.match?(filename, ~r/.*\.m3u8$/)
  end

  defp find_muxed_manifest(manifest_files, output_dir) do
    manifest_files
    |> Enum.find(nil, &String.match?(&1, ~r/^(?!index).*$/))
    |> then(&Path.join(output_dir, &1))
  end

  defp find_stream_manifests(manifest_files, output_dir) do
    manifest_files
    |> Enum.filter(&String.match?(&1, ~r/^(?!index).*$/))
    |> Enum.map(&Path.join(output_dir, &1))
  end

  defp find_headers(files) do
    Enum.filter(files, &String.match?(&1, ~r/.*header.*$/))
  end

  defp extract_segment_sizes(manifest_path, output_dir, segments_number) do
    File.stream!(manifest_path)
    |> Enum.filter(&String.match?(&1, ~r/.*\.m4s/))
    |> Enum.take(segments_number)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Path.join(output_dir, &1))
    |> Enum.map(&File.stat!/1)
    |> Enum.map(& &1.size)
  end

  defp create_video_file_endpoint(
         rtc_engine,
         video_file_path,
         opts \\ []
       ) do
    video_track_config = %FileEndpoint.TrackConfig{
      type: :video,
      stream_id: Keyword.get(opts, :stream_id),
      encoding: :H264,
      clock_rate: 90_000,
      fmtp: %FMTP{
        pt: 96
      },
      opts: [
        metadata: %{"mainPresenter" => true, "isScreenSharing" => false},
        framerate: {60, 1}
      ]
    }

    %FileEndpoint{
      rtc_engine: rtc_engine,
      file_path: video_file_path,
      track_config: video_track_config,
      payload_type: 96,
      autoplay: Keyword.get(opts, :autoplay, true),
      autoend: Keyword.get(opts, :autoend, true)
    }
  end

  defp create_audio_file_endpoint(rtc_engine, stream_id \\ nil, opts \\ []) do
    audio_track_config = %FileEndpoint.TrackConfig{
      type: :audio,
      stream_id: stream_id,
      encoding: :OPUS,
      clock_rate: 48_000,
      fmtp: %FMTP{
        pt: 108
      }
    }

    %FileEndpoint{
      rtc_engine: rtc_engine,
      file_path: Path.join(@fixtures_dir, "audio.aac"),
      track_config: audio_track_config,
      payload_type: 108,
      after_source_transformation: &transform_aac_to_opus/1,
      autoplay: Keyword.get(opts, :autoplay, true),
      autoend: Keyword.get(opts, :autoend, true)
    }
  end

  defp transform_aac_to_opus(link_builder) do
    link_builder
    |> child(:decoder, Membrane.AAC.FDK.Decoder)
    |> child(:encoder, %Membrane.Opus.Encoder{
      input_stream_format: %Membrane.RawAudio{
        channels: 1,
        sample_rate: 48_000,
        sample_format: :s16le
      }
    })
  end
end
