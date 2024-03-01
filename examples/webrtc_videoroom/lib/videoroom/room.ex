defmodule Videoroom.Room do
  @moduledoc false

  use GenServer

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint
  alias Membrane.RTC.Engine.Endpoint.WebRTC
  alias Membrane.RTC.Engine.Message.EndpointMessage
  alias Membrane.RTC.Engine.Message.TrackAdded

  @mix_env Mix.env()

  def start(init_arg, opts) do
    GenServer.start(__MODULE__, init_arg, opts)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(room_id) do
    Membrane.Logger.info("Spawning room proces: #{inspect(self())}")

    # When running via docker without using host network we
    # have to listen at 0.0.0.0 but our packets still need
    # valid IP address in their headers. We store it under `mock_ip`.
    mock_ip = Application.fetch_env!(:membrane_videoroom_demo, :external_ip)
    external_ip = if @mix_env == :prod, do: {0, 0, 0, 0}, else: mock_ip
    port_range = Application.fetch_env!(:membrane_videoroom_demo, :port_range)

    rtc_engine_options = [
      id: room_id
    ]

    integrated_turn_options = [
      ip: external_ip,
      mock_ip: mock_ip,
      ports_range: port_range
    ]

    network_options = [
      integrated_turn_options: integrated_turn_options,
      dtls_pkey: Application.get_env(:membrane_videoroom_demo, :dtls_pkey),
      dtls_cert: Application.get_env(:membrane_videoroom_demo, :dtls_cert)
    ]

    {:ok, pid} = Membrane.RTC.Engine.start(rtc_engine_options, [])
    Engine.register(pid, self())
    Process.monitor(pid)

    {:ok, %{rtc_engine: pid, peer_channels: %{}, network_options: network_options}}
  end

  @impl true
  def handle_info({:add_peer_channel, peer_channel_pid, peer_id}, state) do
    Process.monitor(peer_channel_pid)

    webrtc_endpoint = create_webrtc_endpoint(state.rtc_engine, peer_id, state.network_options)

    :ok = Engine.add_endpoint(state.rtc_engine, webrtc_endpoint, id: peer_id)

    {:noreply, put_in(state, [:peer_channels, peer_id], peer_channel_pid)}
  end

  @impl true
  def handle_info(%EndpointMessage{endpoint_id: to, message: {:media_event, data}}, state) do
    if state.peer_channels[to] != nil do
      send(state.peer_channels[to], {:media_event, data})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(%TrackAdded{endpoint_id: _i, endpoint_type: WebRTC}, state) do
    file_endpoint = create_file_endpoint(state.rtc_engine)

    :ok = Engine.add_endpoint(state.rtc_engine, file_endpoint, id: :file_endpoint)

    # Process.send_after(self(), :start_file, 2_500)

    {:noreply, state}
  end

  # @impl true
  # def handle_info(:start_file, state) do
  #   Endpoint.File.start_sending(state.rtc_engine, :file_endpoint)

  #   {:noreply, state}
  # end

  @impl true
  def handle_info({:media_event, from, event}, state) do
    Engine.message_endpoint(state.rtc_engine, from, {:media_event, event})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case state do
      %{rtc_engine: ^pid} ->
        {:stop, :normal, state}

      %{rtc_engine: rtc_engine, peer_channels: peer_channels} ->
        {peer_id, _peer_channel_id} =
          Enum.find(peer_channels, fn {_peer_id, peer_channel_pid} ->
            peer_channel_pid == pid
          end)

        Engine.remove_endpoint(rtc_engine, peer_id)

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp create_webrtc_endpoint(rtc_engine, peer_id, network_options) do
    handshake_opts =
      if network_options[:dtls_pkey] &&
           network_options[:dtls_cert] do
        [
          client_mode: false,
          dtls_srtp: true,
          pkey: network_options[:dtls_pkey],
          cert: network_options[:dtls_cert]
        ]
      else
        [
          client_mode: false,
          dtls_srtp: true
        ]
      end

    %WebRTC{
      rtc_engine: rtc_engine,
      ice_name: peer_id,
      extensions: %{},
      owner: self(),
      integrated_turn_options: network_options[:integrated_turn_options],
      handshake_opts: handshake_opts,
      log_metadata: [peer_id: peer_id]
    }
  end

  defp create_file_endpoint(rtc_engine) do
    video_track_config = %Endpoint.File.TrackConfig{
      type: :video,
      encoding: :H264,
      clock_rate: 90_000,
      fmtp: %ExSDP.Attribute.FMTP{
        pt: 96
      },
      opts: [framerate: {30, 1}]
    }

    %Endpoint.FileMPEG{
      rtc_engine: rtc_engine,
      file_path: "./test/fixtures/video_baseline.ts",
      track_config: video_track_config,
      payload_type: 96
      # playback_mode: :manual
    }
  end
end
