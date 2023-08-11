defmodule Membrane.RTC.Demo.RtspToHls.Pipeline do
  @moduledoc """
  The pipeline, which converts the RTP stream to HLS.
  """
  use Membrane.Pipeline

  require Logger

  alias Membrane.RTC.Demo.RtspToHls.ConnectionManager

  @impl true
  def handle_init(_ctx, options) do
    Logger.debug("Source handle_init options: #{inspect(options)}")

    connection_manager_spec = [
      %{
        id: "ConnectionManager",
        start:
          {ConnectionManager, :start_link,
           [
             [
               stream_url: options.stream_url,
               port: options.port,
               pipeline: self()
             ]
           ]},
        restart: :transient
      }
    ]

    Supervisor.start_link(connection_manager_spec,
      strategy: :one_for_one,
      name: Membrane.RTC.Demo.RtspToHls.Supervisor
    )

    state = %{
      video: nil,
      port: options.port,
      output_path: options.output_path,
      rtp_started: false
    }

    {[playback: :playing], state}
  end

  @impl true
  def handle_info({:rtsp_setup_complete, options}, _ctx, state) do
    Logger.debug("Source received pipeline options: #{inspect(options)}")

    structure = [
      child(:udp_source, %Membrane.UDP.Source{
        local_port_no: state[:port],
        recv_buffer_size: 500_000
      })
      |> via_in(Pad.ref(:rtp_input, make_ref()))
      |> child(:rtp, %Membrane.RTP.SessionBin{
        fmt_mapping: %{96 => {:H264, 90_000}}
      }),
      child(:hls, %Membrane.HTTPAdaptiveStream.Sink{
        manifest_config: %Membrane.HTTPAdaptiveStream.Sink.ManifestConfig{
          name: Membrane.HTTPAdaptiveStream.HLS,
          module: Membrane.HTTPAdaptiveStream.HLS
        },
        track_config: %Membrane.HTTPAdaptiveStream.Sink.TrackConfig{
          target_window_duration: 120 |> Membrane.Time.seconds()
        },
        # target_segment_duration: 4 |> Membrane.Time.seconds(),
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: state[:output_path]
        }
      })
    ]

    {[spec: structure], %{state | video: %{sps: options[:sps], pps: options[:pps]}}}
  end

  @impl true
  def handle_child_notification({:new_rtp_stream, ssrc, 96, _extensions}, :rtp, _ctx, state) do
    Logger.debug(":new_rtp_stream")

    structure = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc),
        options: [depayloader: Membrane.RTP.H264.Depayloader]
      )
      |> child(:video_nal_parser, %Membrane.H264.FFmpeg.Parser{
        sps: state.video.sps,
        pps: state.video.pps,
        skip_until_keyframe?: true,
        framerate: {30, 1},
        alignment: :au,
        attach_nalus?: true
      })
      |> child(:video_payloader, Membrane.MP4.Payloader.H264)
      |> child(:video_cmaf_muxer, Membrane.MP4.Muxer.CMAF)
      |> via_in(:input)
      |> get_child(:hls)
    ]

    actions = if state.rtp_started, do: [], else: [spec: structure]

    {actions, %{state | rtp_started: true}}
  end

  @impl true
  def handle_child_notification({:new_rtp_stream, ssrc, _payload_type, _list}, :rtp, _ctx, state) do
    Logger.warning("new_rtp_stream Unsupported stream connected")

    structure = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc))
      |> child(:fake_sink, Membrane.Element.Fake.Sink.Buffers)
    ]

    {[spec: structure], state}
  end

  @impl true
  def handle_child_notification(notification, element, _ctx, state) do
    Logger.warning("Unknown notification: #{inspect(notification)}, el: #{element}")

    {[], state}
  end
end
