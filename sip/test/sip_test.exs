defmodule Membrane.RTC.SIPEndpointTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.File, as: FileEndpoint
  alias Membrane.RTC.Engine.Endpoint.File.TrackConfig
  alias Membrane.RTC.Engine.Endpoint.HLS
  alias Membrane.RTC.Engine.Endpoint.HLS.{HLSConfig}
  alias Membrane.RTC.Engine.Endpoint.SIP
  alias Membrane.RTC.Engine.Endpoint.SIP.{RegistrarCredentials}
  alias Membrane.RTC.Engine.Message

  @fixtures_dir "./test/fixtures/"
  @tracks_added_delay 2_500
  @call_sound0_extn0 "1230"
  @call_sound0_extn1 "1231"
  @call_sound0_extn2 "1232"
  @call_sound0_extn3 "1233"
  @call_sound0_extn4 "1234"
  @call_sound1_extn0 "1240"
  @call_sound1_extn1 "1241"
  @wait_hangup_extn "1250"
  @transfer_call_extn "1260"
  @call_long_extn "1270"


  @sip_id "sip-endpoint"
  @file_id "file-endpoint"
  @hls_id "hls-endpoint-id"
  @track_id "test-track-id"
  @stream_id "test-stream"

  setup do
    options = [
      id: "test_rtc"
    ]

    {:ok, pid} = Engine.start_link(options, [])

    Engine.register(pid, self())

    on_exit(fn ->
      Membrane.Pipeline.terminate(pid)
    end)

    [rtc_engine: pid]
  end

  describe "SIP Endpoint test" do
    @tag :tmp_dir
    test "happy path", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      one_sip_endpoint_test(@call_sound0_extn0, tmp_dir, rtc_engine)
    end

    @tag :tmp_dir
    test "SIP connection with transfer", %{
      rtc_engine: rtc_engine,
      tmp_dir: tmp_dir
    } do
      one_sip_endpoint_test(@transfer_call_extn, tmp_dir, rtc_engine)
    end

    @tag :tmp_dir
    test "two parallel rooms with SIP", %{
      tmp_dir: tmp_dir
    } do
      id_to_extn = %{0 => @call_sound0_extn1, 1 => @call_sound1_extn0}

      [room1, room2] =
        rooms =
        for id <- 0..1 do
          options = [
            id: "test_rtc#{id}"
          ]

          {:ok, rtc_engine} = Engine.start_link(options, [])
          Engine.register(rtc_engine, self())

          sip_endpoint_id = "#{@sip_id}#{id}"
          file_endpoint_id = "#{@file_id}#{id}"
          hls_endpoint_id = "#{@hls_id}#{id}"
          track_id = "#{@track_id}#{id}"
          stream_id = "#{@stream_id}#{id}"

          asterisk_output = "./asterisk/recordings/my-file#{id_to_extn[id]}-out.alaw"
          File.rm(asterisk_output)

          output_dir = Path.join([tmp_dir, stream_id])

          hls_endpoint = create_hls_endpoint(rtc_engine, output_dir)
          file_endpoint = create_audio_file_endpoint(rtc_engine, stream_id, track_id)

          :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: hls_endpoint_id)

          %{
            engine: rtc_engine,
            sip_id: sip_endpoint_id,
            file_id: file_endpoint_id,
            file: file_endpoint,
            hls_id: hls_endpoint_id,
            hls: hls_endpoint,
            asterisk_output: asterisk_output,
            hls_output: output_dir,
            track_id: track_id,
            stream_id: stream_id
          }
        end

      sip_endpoint = create_sip_endpoint(room1.engine)
      :ok = Engine.add_endpoint(room1.engine, sip_endpoint, id: room1.sip_id)

      sip_endpoint = create_sip_endpoint(room2.engine, "mymediaserver1")
      :ok = Engine.add_endpoint(room2.engine, sip_endpoint, id: room2.sip_id)

      for room <- rooms do
        :ok = Engine.add_endpoint(room.engine, room.file, id: room.file_id)
        file_endpoint_id = room.file_id

        assert_receive %Message.EndpointMessage{
                         endpoint_id: ^file_endpoint_id,
                         message: :tracks_added
                       },
                       @tracks_added_delay
      end

      SIP.dial(room1.engine, room1.sip_id, @call_sound0_extn1)
      SIP.dial(room2.engine, room2.sip_id, @call_sound1_extn0)

      for room <- rooms do
        FileEndpoint.start_sending(room.engine, room.file_id)
      end

      for room <- rooms do
        sip_endpoint_id = room.sip_id

        assert_receive %Message.TrackAdded{
                         endpoint_id: ^sip_endpoint_id,
                         track_id: sip_track_id
                       },
                       15_000

        :ok = Engine.message_endpoint(room.engine, room.hls_id, {:subscribe, [sip_track_id]})
      end

      assert_receive {:playlist_playable, _content, _output_path}, 30_000
      assert_receive {:playlist_playable, _content, _output_path}, 30_000

      for room <- rooms do
        sip_endpoint_id = room.sip_id

        assert_receive %Message.EndpointRemoved{
          endpoint_id: ^sip_endpoint_id
        }, 50_000
      end

      for room <- rooms do
        hls_endpoint_id = room.hls_id
        Engine.remove_endpoint(room.engine, hls_endpoint_id)

        assert_receive %Message.EndpointRemoved{
          endpoint_id: ^hls_endpoint_id
        }, 50_000
      end


      for room <- rooms do
        assert File.exists?(room.asterisk_output)
        check_alaw_file(room.asterisk_output)

        assert File.dir?(room.hls_output)
        check_hls_file(room.hls_output)
      end
    end

    @tag :tmp_dir
    test "two sip endpoints", %{
      rtc_engine: rtc_engine
    } do
      sip_endpoint_id1 = "#{@sip_id}1"
      sip_endpoint_id2 = "#{@sip_id}2"
      asterisk_output0 = "./asterisk/recordings/my-file#{@call_sound0_extn2}-out.alaw"
      asterisk_output1 = "./asterisk/recordings/my-file#{@call_sound1_extn1}-out.alaw"

      for output <- [asterisk_output0, asterisk_output1], do: File.rm(output)

      sip_endpoint = create_sip_endpoint(rtc_engine)
      :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: sip_endpoint_id1)

      sip_endpoint = create_sip_endpoint(rtc_engine, "mymediaserver1")
      :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: sip_endpoint_id2)

      SIP.dial(rtc_engine, sip_endpoint_id1, @call_sound0_extn2)
      SIP.dial(rtc_engine, sip_endpoint_id2, @call_sound1_extn1)

      assert_receive %Message.TrackAdded{
                       endpoint_id: ^sip_endpoint_id1,
                       track_id: _sip_track_id
                     },
                     15_000

      assert_receive %Message.TrackAdded{
                       endpoint_id: ^sip_endpoint_id2,
                       track_id: _sip_track_id
                     },
                     15_000

      Process.sleep(15_000)

      Engine.remove_endpoint(rtc_engine, sip_endpoint_id1)
      Engine.remove_endpoint(rtc_engine, sip_endpoint_id2)

      Process.sleep(15_000)

      Membrane.Pipeline.terminate(rtc_engine, asynchronous?: true, timeout: 10_000)

      for output <- [asterisk_output0, asterisk_output1] do
        assert File.exists?(output)
        check_alaw_file(output)
      end
    end

    test "sip call declined", %{
      rtc_engine: rtc_engine
    } do
      sip_endpoint_id = @sip_id
      asterisk_output = "./asterisk/recordings/my-file#{@wait_hangup_extn}-out.alaw"

      File.rm(asterisk_output)

      sip_endpoint = create_sip_endpoint(rtc_engine)
      :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: sip_endpoint_id)

      SIP.dial(rtc_engine, sip_endpoint_id, @wait_hangup_extn)

      assert_receive %Message.EndpointRemoved{endpoint_id: ^sip_endpoint_id}, 15_000
    end

    @tag :tmp_dir
    test "one endpoint leaves before end", %{
      rtc_engine: rtc_engine
    } do
      asterisk_output = "./asterisk/recordings/my-file#{@call_sound0_extn3}-out.alaw"
      File.rm(asterisk_output)

      file_endpoint_id1 = "#{@file_id}1"
      file_endpoint_id2 = "#{@file_id}2"
      sip_endpoint_id = @sip_id

      track_id1 = "#{@track_id}1"
      track_id2 = "#{@track_id}2"
      stream_id1 = "#{@stream_id}1"
      stream_id2 = "#{@stream_id}2"

      sip_endpoint = create_sip_endpoint(rtc_engine)
      :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: sip_endpoint_id)

      file_endpoint = create_audio_file_endpoint(rtc_engine, stream_id1, track_id1)
      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id1)

      file_endpoint = create_audio_file_endpoint(rtc_engine, stream_id2, track_id2)
      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: file_endpoint_id2)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id1,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      assert_receive %Message.EndpointMessage{
                       endpoint_id: ^file_endpoint_id2,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      SIP.dial(rtc_engine, sip_endpoint_id, @call_sound0_extn3)

      FileEndpoint.start_sending(rtc_engine, file_endpoint_id1)
      FileEndpoint.start_sending(rtc_engine, file_endpoint_id2)

      assert_receive %Message.EndpointMessage{endpoint_id: sip_endpoint_id, message: :call_ready},
                     20_000

      Engine.remove_endpoint(rtc_engine, file_endpoint_id1)

      assert_receive %Message.EndpointRemoved{
                       endpoint_id: ^file_endpoint_id1
                     },
                     1_000

      assert_receive %Message.EndpointRemoved{
                       endpoint_id: ^sip_endpoint_id
                     },
                     40_000

      assert File.exists?(asterisk_output)
      check_alaw_file(asterisk_output)
    end

    @tag :tmp_dir
    test "sip endpoint is removed after other endpoints leave engine", %{
      rtc_engine: rtc_engine
    } do
      asterisk_output = "./asterisk/recordings/my-file#{@call_long_extn}-out.alaw"
      File.rm(asterisk_output)

      sip_endpoint = create_sip_endpoint(rtc_engine)
      :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: @sip_id)

      file_endpoint = create_audio_file_endpoint(rtc_engine, @stream_id, @track_id, "audio0_short.aac")
      :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: @file_id)

      assert_receive %Message.EndpointMessage{
                       endpoint_id: @file_id,
                       message: :tracks_added
                     },
                     @tracks_added_delay

      SIP.dial(rtc_engine, @sip_id, @call_long_extn)

      FileEndpoint.start_sending(rtc_engine, @file_id)

      assert_receive %Message.TrackAdded{
        endpoint_id: @sip_id,
      },
      15_000

      assert_receive %Message.EndpointRemoved{
                       endpoint_id: @file_id,
                     },
                     25_000

      assert_receive %Message.EndpointRemoved{
                       endpoint_id: @sip_id
                     },
                     10_000

      assert File.exists?(asterisk_output)
      check_alaw_file(asterisk_output)
    end
  end

  defp one_sip_endpoint_test(extension, tmp_dir, rtc_engine) do
    file_extension = if extension == @transfer_call_extn, do: @call_sound0_extn4, else: extension
    asterisk_output = "./asterisk/recordings/my-file#{file_extension}-out.alaw"

    File.rm(asterisk_output)

    output_dir = Path.join([tmp_dir, @stream_id])
    hls_endpoint = create_hls_endpoint(rtc_engine, output_dir)
    :ok = Engine.add_endpoint(rtc_engine, hls_endpoint, id: @hls_id)

    assert_receive %Message.EndpointAdded{
      endpoint_id: @hls_id
    }, 1_000

    sip_endpoint = create_sip_endpoint(rtc_engine)
    :ok = Engine.add_endpoint(rtc_engine, sip_endpoint, id: @sip_id)

    file_endpoint = create_audio_file_endpoint(rtc_engine, @stream_id, @track_id)

    :ok = Engine.add_endpoint(rtc_engine, file_endpoint, id: @file_id)

    assert_receive %Message.EndpointMessage{
                     endpoint_id: @file_id,
                     message: :tracks_added
                   },
                   @tracks_added_delay

    SIP.dial(rtc_engine, @sip_id, extension)

    assert_receive %Message.TrackAdded{
                     endpoint_id: @sip_id,
                     track_id: sip_track_id
                   },
                   15_000

    :ok = Engine.message_endpoint(rtc_engine, @hls_id, {:subscribe, [sip_track_id]})

    FileEndpoint.start_sending(rtc_engine, @file_id)


    assert_receive {:playlist_playable, _content, _output_path}, 30_000

    assert_receive %Message.EndpointRemoved{
      endpoint_id: @sip_id
    }, 50_000

    Engine.remove_endpoint(rtc_engine, @hls_id)

    assert_receive %Message.EndpointRemoved{
      endpoint_id: @hls_id
    }, 50_000

    assert File.exists?(asterisk_output)
    check_alaw_file(asterisk_output)

    assert File.dir?(output_dir)
    check_hls_file(output_dir)
  end

  defp create_hls_endpoint(rtc_engine, output_dir) do
    %HLS{
      rtc_engine: rtc_engine,
      owner: self(),
      output_directory: output_dir,
      synchronize_tracks?: false,
      mixer_config: nil,
      hls_config: %HLSConfig{
        mode: :vod,
        target_window_duration: :infinity,
        hls_mode: :separate_av,
        segment_duration: Membrane.Time.seconds(3)
      },
      subscribe_mode: :manual
    }
  end

  defp create_sip_endpoint(rtc_engine, username \\ "mymediaserver0") do
    %SIP{
      rtc_engine: rtc_engine,
      registrar_credentials:
        RegistrarCredentials.new(
          address: System.fetch_env!("SIP_DOMAIN"),
          username: username,
          password: "yourpassword"
        ),
      external_ip: System.fetch_env!("EXTERNAL_IP")
    }
  end

  defp create_audio_file_endpoint(rtc_engine, stream_id, audio_track_id, audio_file \\ nil) do
    track_config = %TrackConfig{
      type: :audio,
      stream_id: stream_id,
      encoding: :OPUS,
      clock_rate: 48_000,
      fmtp: nil,
      opts: [id: audio_track_id]
    }

    audio_file = if is_nil(audio_file), do: "audio#{:rand.uniform(7) - 1}.aac", else: audio_file

    %FileEndpoint{
      rtc_engine: rtc_engine,
      file_path: Path.join(@fixtures_dir, audio_file),
      track_config: track_config,
      ssrc: 2345,
      payload_type: 108,
      after_source_transformation: &transform_aac_to_opus/1,
      autoplay: false
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

  defp check_alaw_file(audio_file_path) do
    cmd =
      "ffprobe -v quiet -print_format json -show_format -show_streams -f alaw -ar 8000 " <>
        audio_file_path

    {output, 0} = System.cmd("sh", ["-c", cmd])
    data = Jason.decode!(output)

    audio_stream = Enum.find(data["streams"], fn stream -> stream["codec_type"] == "audio" end)

    assert audio_stream != nil

    assert audio_stream["codec_name"] == "pcm_alaw"

    assert audio_stream["sample_rate"] == "8000"


    duration = data["format"]["duration"]
    assert not is_nil(duration)
    new_duration = Float.parse(duration) |> elem(0)

    assert new_duration >= 5
  end

  defp check_hls_file(audio_directory) do
    cmd = "cd #{audio_directory} && cat ./*/audio_header_*.mp4 ./*/audio_segment_* > audio.mp4"
    {_output, _exit_code} = System.cmd("sh", ["-c", cmd])

    audio_file_path = Path.join([audio_directory, "audio.mp4"])

    assert File.exists?(audio_file_path)

    cmd = "ffprobe -v quiet -print_format json -show_format -show_streams " <> audio_file_path
    {output, 0} = System.cmd("sh", ["-c", cmd])
    data = Jason.decode!(output)

    audio_stream = Enum.find(data["streams"], fn stream -> stream["codec_type"] == "audio" end)

    assert audio_stream != nil

    duration = Float.parse(data["format"]["duration"]) |> elem(0)

    assert duration >= 5
  end
end
