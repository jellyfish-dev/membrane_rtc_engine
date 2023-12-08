defmodule Membrane.RTC.Engine.Endpoint.SIP do
  @moduledoc """
  TODO: write me

  An Endpoint responsible for

  ## Limitations
  Incoming calls are unsupported.

  Currently, only the G711 A-law codec is supported.
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.{Logger, RawAudio, Time}
  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.SIP.{Call, OutgoingCall, RegisterCall, SippetCore}
  alias Membrane.RTC.Engine.Endpoint.WebRTC.{TrackReceiver, TrackSender}
  alias Membrane.RTC.Engine.Track
  alias Membrane.RTP.SessionBin

  defmodule RegistrarCredentials do
    @moduledoc """
    Module describing credentials needed to connect with SIP registrar server
    """

    @typedoc """
    Describes SIP registrar credentials structure.

    * `uri` - URI with address of the registrar server.
    * `username` - your username in registrar service
    * `password` - your password in registrar service
    """
    @type t() :: %__MODULE__{
            uri: Sippet.URI.t(),
            username: String.t(),
            password: String.t()
          }

    @enforce_keys [:uri, :username, :password]
    defstruct @enforce_keys

    @doc """
    Creates a RegistrarCredentials struct from strings. The address is parsed and can be:
      - a FQDN, e.g. "my-sip-registrar.net",
      - an IPv4 in string form, e.g. "1.2.3.4".
    Both can have a specified port, e.g. "5.6.7.8:9999".
    If not given, the default SIP port 5060 will be assumed.
    """
    @spec new(String.t(), String.t(), String.t()) :: __MODULE__.t() | no_return()
    def new(address, username, password) do
      %__MODULE__{
        uri: Sippet.URI.parse!("sip:" <> address),
        username: username,
        password: password
      }
    end
  end

  @doc """
  Starts calling a specified number
  """
  @spec dial(rtc_engine :: pid(), endpoint_id :: String.t(), phone_number :: String.t()) :: :ok
  def dial(rtc_engine, endpoint_id, phone_number) do
    Engine.message_endpoint(rtc_engine, endpoint_id, {:dial, phone_number})
  end

  @doc """
  Ends ongoing call or cancels call try
  """
  @spec end_call(rtc_engine :: pid(), endpoint_id :: String.t()) :: :ok
  def end_call(rtc_engine, endpoint_id) do
    Engine.message_endpoint(rtc_engine, endpoint_id, :end_call)
  end

  @rtp_port 21_000
  @sip_port 22_000
  @register_interval 45_000

  @audio_mixer_delay Time.milliseconds(200)

  def_output_pad(:output,
    demand_unit: :buffers,
    accepted_format: Membrane.RTP,
    availability: :on_request
  )

  def_input_pad(:input,
    demand_unit: :buffers,
    accepted_format: Membrane.RTP,
    availability: :on_request
  )

  def_options(
    rtc_engine: [
      spec: pid(),
      description: "PID of parent Engine"
    ],
    registrar_credentials: [
      spec: RegistrarCredentials.t(),
      description: "Credentials needed to connect with SIP registrar server"
    ],
    external_ip: [
      spec: String.t(),
      description:
        "External IPv4 address of the machine running the Endpoint, required for SDP negotiation"
    ],
    rtp_port: [
      spec: 1..65_535,
      description: "Local udp port RTP stream will be received at",
      default: @rtp_port
    ],
    sip_port: [
      spec: 1..65_535,
      description: "Local udp port SIP messages will be received at",
      default: @sip_port
    ],
    register_interval: [
      spec: non_neg_integer(),
      description: """
      Interval (in ms) in which keep-alive (keep-registered) REGISTER messages
      will be sent to the SIP registrar server
      """,
      default: @register_interval
    ]
  )

  @impl true
  def handle_init(ctx, opts) do
    Logger.debug("SIP Endpoint: Init")

    {:endpoint, endpoint_id} = ctx.name

    track =
      Track.new(
        :audio,
        Track.stream_id(),
        endpoint_id,
        :OPUS,
        48_000,
        %ExSDP.Attribute.FMTP{pt: Membrane.RTP.PayloadFormat.get(:OPUS)}
      )

    opts = Map.from_struct(opts)

    SippetCore.setup()
    {_register_call_id, _pid} = spawn_call(opts, RegisterCall)

    state =
      opts
      |> Map.merge(%{
        outgoing_track: track,
        incoming_tracks: %{},
        outgoing_ssrc: SessionBin.generate_receiver_ssrc([], []),
        incoming_ssrc: nil,
        registered?: false,
        pipelines_spawned?: false,
        call_id: nil,
        phone_number: nil,
        payload_type: nil
      })

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    track = Map.get(state.incoming_tracks, track_id)

    spec = [
      bin_input(pad)
      |> child({:track_receiver, track.id}, %TrackReceiver{
        track: track,
        initial_target_variant: :high
      })
      |> child({:depayloader, track.id}, Track.get_depayloader(track))
      |> child({:opus_decoder, track.id}, Membrane.Opus.Decoder)
      |> via_in(Pad.ref(:input, {:extra, track.id}))
      |> get_child(:audio_mixer)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {track_id, :high}) = pad, _ctx, state)
      when track_id == state.outgoing_track.id do
    Logger.debug("Pad added for track #{inspect(track_id)}, variant :high")

    spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, state.incoming_ssrc),
        options: [depayloader: Membrane.RTP.G711.Depayloader]
      )
      |> child({:g711_decoder, track_id}, Membrane.G711.FFmpeg.Decoder)
      |> child({:converter, track_id}, %Membrane.FFmpeg.SWResample.Converter{
        input_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: 8_000},
        output_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: 48_000}
      })
      |> child({:raw_audio_parser, track_id}, %Membrane.RawAudioParser{
        stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: 48_000},
        overwrite_pts?: true
      })
      |> child({:opus_encoder, track_id}, %Membrane.Opus.Encoder{
        input_stream_format: %Membrane.RawAudio{
          channels: 1,
          sample_rate: 48_000,
          sample_format: :s16le
        }
      })
      |> child({:opus_parser, track_id}, Membrane.Opus.Parser)
      |> child({:payloader, track_id}, %Membrane.RTP.PayloaderBin{
        payloader: Membrane.RTP.Opus.Payloader,
        ssrc: state.incoming_ssrc,
        payload_type: Membrane.RTP.PayloadFormat.get(:OPUS),
        clock_rate: 48_000
      })
      |> via_in(Pad.ref(:input, {track_id, :high}))
      |> child(
        {:track_sender, track_id},
        %TrackSender{
          track: state.outgoing_track,
          variant_bitrates: %{}
        }
      )
      |> via_out(pad)
      |> bin_output(pad)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, track_id), _ctx, state) do
    state = %{state | incoming_tracks: Map.delete(state.incoming_tracks, track_id)}
    {[remove_children: {:track_receiver, track_id}], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {_track_id, _variant}), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:dial, phone_number}, _ctx, %{registered?: false} = state) do
    Logger.info("SIP Endpoint: Postponing call until registered")
    {[], %{state | phone_number: phone_number}}
  end

  @impl true
  def handle_parent_notification({:dial, phone_number}, _ctx, state) do
    Logger.info("SIP Endpoint: Calling #{inspect(phone_number)}...")

    {call_id, _pid} = spawn_call(state)
    OutgoingCall.dial(call_id, phone_number)

    {[], %{state | call_id: call_id, phone_number: phone_number}}
  end

  @impl true
  def handle_parent_notification(:end_call, _ctx, state) when is_nil(state.call_id) do
    Logger.warning("SIP Endpoint: No ongoing call or call attempt to end")
    {[], %{state | phone_number: nil}}
  end

  @impl true
  def handle_parent_notification(:end_call, _ctx, state) do
    Logger.info("SIP Endpoint: Ending call")

    if state.pipelines_spawned?,
      do: OutgoingCall.bye(state.call_id),
      else: OutgoingCall.cancel(state.call_id)

    {[], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    state =
      tracks
      |> Enum.filter(fn track -> track.type == :audio end)
      |> Enum.reduce(state, fn track, state ->
        case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
          :ok ->
            put_in(state, [:incoming_tracks, track.id], track)

          {:error, :invalid_track_id} ->
            Logger.info("""
            Couldn't subscribe to the track: #{inspect(track.id)}. No such track.
            It had to be removed just after publishing it. Ignoring.
            """)

            state

          {:error, reason} ->
            raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
        end
      end)

    {[], state}
  end

  @impl true
  def handle_parent_notification({:remove_tracks, _tracks}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:ready, _endpoints}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification(msg, _ctx, state) do
    Logger.warning("SIP Endpoint: Unexpected message from parent: #{inspect(msg)}. Ignoring.")
    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, fmt, _extensions} = msg,
        :rtp,
        _ctx,
        state
      )
      when is_nil(state.incoming_ssrc) or ssrc == state.incoming_ssrc do
    Logger.debug("SIP Endpoint: New RTP stream connected: #{inspect(msg)}")

    state = %{state | incoming_ssrc: ssrc}

    if fmt != state.payload_type do
      raise("""
      Payload type mismatch between RTP mapping and received stream
      (expected #{inspect(state.payload_type)}, got #{inspect(fmt)})
      """)
    end

    {[
       notify_child: {:audio_mixer, {:start_mixing, @audio_mixer_delay}},
       notify_parent:
         {:track_ready, state.outgoing_track.id, :high, state.outgoing_track.encoding}
     ], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, _ssrc, _fmt, _extensions} = msg,
        :rtp,
        _ctx,
        _state
      ) do
    raise("Received unexpected, second RTP stream: #{inspect(msg)}")
  end

  @impl true
  def handle_child_notification({:connection_info, _address, _port}, :udp_endpoint, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_child_notification({:estimation, _data}, {:track_sender, _tid}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:variant_switched, _new, _old},
        {:track_receiver, _tid},
        _ctx,
        state
      ) do
    {[], state}
  end

  @impl true
  def handle_child_notification(notification, element, _ctx, state) do
    Logger.warning(
      "SIP Endpoint: Unexpected notification from `#{inspect(element)}`: #{inspect(notification)}. Ignoring."
    )

    {[], state}
  end

  @impl true
  def handle_info(:registered, _ctx, %{registered?: false} = state)
      when not is_nil(state.phone_number) do
    Logger.info("SIP Endpoint: Calling #{inspect(state.phone_number)}...")

    {call_id, _pid} = spawn_call(state)
    OutgoingCall.dial(call_id, state.phone_number)

    {[], %{state | call_id: call_id, registered?: true}}
  end

  @impl true
  def handle_info(:registered, _ctx, state) do
    {[], %{state | registered?: true}}
  end

  @impl true
  def handle_info({:call_info, :trying}, _ctx, state) do
    Logger.debug("SIP Endpoint: Trying...")
    {[], state}
  end

  @impl true
  def handle_info({:call_info, :ringing}, _ctx, state) do
    Logger.info("SIP Endpoint: Ringing...")
    {[], state}
  end

  @impl true
  def handle_info({:call_info, {:call_ready, _opts}}, _ctx, %{pipelines_spawned?: true} = state) do
    Logger.warning(
      "SIP Endpoint: Received `:call_ready` info, but the pipelines are already spawned. Ignoring"
    )

    {[], state}
  end

  @impl true
  def handle_info({:call_info, {:call_ready, options}}, _ctx, state) do
    Logger.debug("SIP Endpoint: Connected. Received source options: #{inspect(options)}")
    Logger.info("SIP Endpoint: Call answered")

    {payload_type, rtpmap} = options.rtp_payload_fmt

    receive_spec = [
      child(:udp_endpoint, %Membrane.UDP.Endpoint{
        local_port_no: state.rtp_port,
        destination_port_no: options.port,
        destination_address: options.connection_data.address
      })
      |> via_in(Pad.ref(:rtp_input, make_ref()))
      |> child(:rtp, %SessionBin{
        fmt_mapping: %{payload_type => {rtpmap.encoding_name, rtpmap.clock_rate}}
      })
    ]

    send_spec = [
      child(:audio_mixer, %Membrane.LiveAudioMixer{
        latency: nil,
        stream_format: %Membrane.RawAudio{
          channels: 1,
          sample_rate: 48_000,
          sample_format: :s16le
        }
      })
      |> child(:converter_out, %Membrane.FFmpeg.SWResample.Converter{
        input_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: 48_000},
        output_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: 8_000}
      })
      |> child(:g711_encoder, Membrane.G711.FFmpeg.Encoder)
      |> child(:g711_parser, %Membrane.G711.FFmpeg.Parser{overwrite_pts?: true})
      |> via_in(Pad.ref(:input, state.outgoing_ssrc),
        options: [payloader: Membrane.RTP.G711.Payloader]
      )
      |> get_child(:rtp)
      |> via_out(Pad.ref(:rtp_output, state.outgoing_ssrc), options: [encoding: :PCMA])
      |> get_child(:udp_endpoint)
    ]

    actions = [
      spec: receive_spec ++ send_spec,
      notify_parent: :ready,
      notify_parent: {:publish, {:new_tracks, [state.outgoing_track]}},
      # TODO: notify owner about call ready (and maybe trying/ringing)
      notify_parent: {:forward_to_parent, :call_ready}
    ]

    state = %{state | payload_type: payload_type, pipelines_spawned?: true}

    {actions, state}
  end

  @impl true
  def handle_info({:call_info, {:end, reason} = msg}, _ctx, state) do
    case reason do
      :cancelled ->
        Logger.info("SIP Endpoint: Call attempt cancelled by user")

      :user_hangup ->
        Logger.info("SIP Endpoint: Call ended by user")

      :normal_clearing ->
        Logger.info("SIP Endpoint: Call ended by other side (hangup)")

      reason ->
        Logger.warning("SIP Endpoint: Call ended with reason: #{inspect(reason)}")
    end

    {[notify_parent: {:forward_to_parent, msg}, terminate: :shutdown], state}
  end

  # @impl true
  # def handle_info({:sip_info, :disconnected}, _ctx, state) do
  #   Logger.error("""
  #   RTSP Endpoint disconnected from source.
  #   The endpoint is now functionally useless, it will not be able to reconnect and is thus shutting down
  #   """)

  #   {[notify_parent: {:forward_to_parent, :disconnected}, terminate: :shutdown], state}
  # end

  @impl true
  def handle_info(info, _ctx, state) do
    Logger.warning("SIP Endpoint: Unexpected info: #{inspect(info)}. Ignoring.")
    {[], state}
  end

  defp spawn_call(state, module \\ OutgoingCall) do
    state
    |> Map.put(:endpoint, self())
    |> then(&struct(Call.Settings, &1))
    |> module.start_link()
  end
end
