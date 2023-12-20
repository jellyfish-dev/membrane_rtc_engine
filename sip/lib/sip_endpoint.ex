defmodule Membrane.RTC.Engine.Endpoint.SIP do
  @moduledoc """
  TODO: write me

  An Endpoint responsible for

  ## Limitations
  Incoming calls are unsupported.

  Currently, only the G711 A-law codec is supported.

  ## Setup
  The range of ports available to SIP Endpoints can be modified by adding the following line to your `config.exs`:
  ```
  config :membrane_rtc_engine_sip, port_range: {from, to}
  ```
  (both ends inclusive).

  The Endpoints will open UDP sockets on ports from this range.
  Each SIP Endpoint uses 2 ports: one for SIP signaling messages, the other for the RTP media stream.
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.{Logger, RawAudio, Time}
  alias Membrane.RTC.Engine

  alias Membrane.RTC.Engine.Endpoint.SIP.{
    Call,
    OutgoingCall,
    PortAllocator,
    RegisterCall
  }

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
    @type t :: %__MODULE__{
            uri: Sippet.URI.t(),
            username: String.t(),
            password: String.t()
          }

    @enforce_keys [:uri, :username, :password]
    defstruct @enforce_keys

    @doc """
    Creates a RegistrarCredentials struct from strings. The address is parsed and can be:
      - an FQDN, e.g. "my-sip-registrar.net",
      - an IPv4 in string form, e.g. "1.2.3.4".
    Both can have a specified port, e.g. "5.6.7.8:9999".
    If not given, the default SIP port 5060 will be assumed.
    """
    @spec new(address: String.t(), username: String.t(), password: String.t()) ::
            t() | no_return()
    def new(opts) do
      uri =
        opts
        |> Keyword.fetch!(:address)
        |> then(&("sip:" <> &1))
        |> Sippet.URI.parse!()

      %__MODULE__{
        uri: uri,
        username: Keyword.fetch!(opts, :username),
        password: Keyword.fetch!(opts, :password)
      }
    end
  end

  defmodule State do
    @moduledoc false
    use Bunch.Access

    @typep endpoint_state ::
             :unregistered
             | :unregistered_call_pending
             | :registered
             | :calling
             | :in_call
             | :ending_call
             | :terminating

    @type t :: %__MODULE__{
            rtc_engine: pid(),
            registrar_credentials: RegistrarCredentials.t(),
            external_ip: String.t(),
            register_interval: non_neg_integer(),
            endpoint_state: endpoint_state(),
            rtp_port: 1..65_535,
            sip_port: 1..65_535,
            outgoing_track: Track.t(),
            incoming_tracks: %{Track.id() => Track.t()},
            outgoing_ssrc: Membrane.RTP.ssrc_t(),
            incoming_ssrc: Membrane.RTP.ssrc_t() | nil,
            register_call_id: Call.id(),
            call_id: Call.id() | nil,
            phone_number: String.t() | nil,
            payload_type: ExSDP.Attribute.RTPMapping.payload_type_t()
          }

    @enforce_keys [
      :rtc_engine,
      :registrar_credentials,
      :external_ip,
      :register_interval,
      :endpoint_state,
      :rtp_port,
      :sip_port,
      :outgoing_track,
      :incoming_tracks,
      :outgoing_ssrc,
      :incoming_ssrc,
      :register_call_id,
      :call_id,
      :phone_number,
      :payload_type
    ]

    defstruct @enforce_keys
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

  @register_interval 45_000

  @audio_mixer_delay Time.milliseconds(200)

  def_output_pad :output,
    accepted_format: Membrane.RTP,
    availability: :on_request

  def_input_pad :input,
    accepted_format: Membrane.RTP,
    availability: :on_request

  def_options rtc_engine: [
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
              register_interval: [
                spec: non_neg_integer(),
                description: """
                Interval (in ms) in which keep-alive (keep-registered) REGISTER messages
                will be sent to the SIP registrar server
                """,
                default: @register_interval
              ]

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

    {register_call_id, _pid} = spawn_call(opts, RegisterCall)

    self_pid = self()

    Membrane.ResourceGuard.register(
      ctx.resource_guard,
      fn -> PortAllocator.free_ports(self_pid) end
    )

    with {:ok, rtp_port} <- PortAllocator.get_port(),
         {:ok, sip_port} <- PortAllocator.get_port() do
      state =
        opts
        |> Map.merge(%{
          endpoint_state: :unregistered,
          rtp_port: rtp_port,
          sip_port: sip_port,
          outgoing_track: track,
          incoming_tracks: %{},
          outgoing_ssrc: SessionBin.generate_receiver_ssrc([], []),
          incoming_ssrc: nil,
          register_call_id: register_call_id,
          call_id: nil,
          phone_number: nil,
          payload_type: nil
        })
        |> then(&struct!(State, &1))

      {[], state}
    else
      {:error, :no_available_port} ->
        raise """
        No available ports! Consider increasing the port range used by PortAllocator.
          You can do that by adding the following line to your `config.exs` file:
          ```
          config :membrane_rtc_engine_sip, port_range: {from, to}
          ```
        """
    end
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

    children_to_remove =
      [:track_receiver, :depayloader, :opus_decoder] |> Enum.map(&{&1, track_id})

    {[remove_children: children_to_remove], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {_track_id, _variant}), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:dial, phone_number}, _ctx, state) do
    # Strip whitespace and separator characters
    phone_number = String.replace(phone_number, ~r/[-.() \t\r\n]+/, "")

    unless Regex.match?(~r/^\+?\d+$/, phone_number) do
      raise "Invalid phone number: #{inspect(phone_number)}. Only digits and `+` are allowed in number"
    end

    state =
      case state.endpoint_state do
        :unregistered ->
          Logger.info("SIP Endpoint: Postponing call until registered")
          %{state | phone_number: phone_number, endpoint_state: :unregistered_call_pending}

        :registered ->
          Logger.info("SIP Endpoint: Calling #{inspect(phone_number)}...")
          state = %{state | phone_number: phone_number}
          {call_id, _pid} = spawn_call(state)
          %{state | call_id: call_id, endpoint_state: :calling}

        _other ->
          Logger.warning("SIP Endpoint: Already calling, or endpoint is terminating")
          state
      end

    {[], state}
  end

  @impl true
  def handle_parent_notification(:end_call, _ctx, state) do
    new_endpoint_state =
      case state.endpoint_state do
        :unregistered_call_pending ->
          Logger.info("SIP Endpoint: Call attempt cancelled")
          :unregistered

        :calling ->
          Logger.info("SIP Endpoint: Cancelling call attempt")
          OutgoingCall.cancel(state.call_id)
          :ending_call

        :in_call ->
          Logger.info("SIP Endpoint: Ending call")
          OutgoingCall.bye(state.call_id)
          :ending_call

        other_state ->
          Logger.warning(
            "SIP Endpoint: No ongoing call or call attempt to end, or endpoint is already terminating"
          )

          other_state
      end

    {[], %{state | phone_number: nil, endpoint_state: new_endpoint_state}}
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
  def handle_parent_notification({topic, _data}, _ctx, state)
      when topic in [
             :remove_tracks,
             :ready,
             :endpoint_added,
             :endpoint_removed,
             :bitrate_estimation
           ] do
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
      raise """
      Payload type mismatch between RTP mapping and received stream
      (expected #{inspect(state.payload_type)}, got #{inspect(fmt)})
      """
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
    raise "Received unexpected, second RTP stream: #{inspect(msg)}"
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
  def handle_child_notification(
        {:voice_activity_changed, _new},
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
  def handle_info(:registered, _ctx, state) do
    state =
      case state.endpoint_state do
        :unregistered ->
          %{state | endpoint_state: :registered}

        :unregistered_call_pending ->
          Logger.info("SIP Endpoint: Calling #{inspect(state.phone_number)}...")
          {call_id, _pid} = spawn_call(state)
          %{state | call_id: call_id, endpoint_state: :calling}

        _other_state ->
          state
      end

    {[], state}
  end

  @impl true
  def handle_info({:call_info, call_info}, _ctx, %{endpoint_state: :terminating} = state) do
    Logger.debug("SIP Endpoint: Received call info #{inspect(call_info)} in state :terminating")
    {[], state}
  end

  @impl true
  def handle_info({:call_info, :trying}, _ctx, state) do
    Logger.debug("SIP Endpoint: Trying...")
    {[], state}
  end

  @impl true
  def handle_info({:call_info, :ringing}, _ctx, state) do
    Logger.info("SIP Endpoint: Ringing...")

    {[notify_parent: {:forward_to_parent, :ringing}], state}
  end

  @impl true
  def handle_info({:call_info, {:call_ready, options}}, _ctx, %{endpoint_state: :calling} = state) do
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
      notify_parent: {:forward_to_parent, :call_ready}
    ]

    state = %{state | payload_type: payload_type, endpoint_state: :in_call}

    {actions, state}
  end

  @impl true
  def handle_info({:call_info, {:call_ready, _opts}}, _ctx, %{endpoint_state: :in_call} = state) do
    Logger.warning(
      "SIP Endpoint: Received `:call_ready` info, but the pipelines are already spawned. Ignoring"
    )

    {[], state}
  end

  @impl true
  def handle_info({:call_info, {:end, reason} = msg}, _ctx, state) do
    case reason do
      :cancelled ->
        Logger.info("SIP Endpoint: Call attempt cancelled by user")

      :user_hangup ->
        Logger.info("SIP Endpoint: Call ended by user")

      :busy ->
        Logger.info("SIP Endpoint: Call declined, other side is busy")

      :declined ->
        Logger.info("SIP Endpoint: Call declined by other side")

      :normal_clearing ->
        Logger.info("SIP Endpoint: Call ended by other side (hangup)")

      reason ->
        Logger.warning("SIP Endpoint: Call ended with reason: #{inspect(reason)}")
    end

    actions = [
      notify_parent: :ready,
      notify_parent: {:forward_to_parent, msg},
      notify_parent: :finished
    ]

    {actions, %{state | endpoint_state: :terminating}}
  end

  @impl true
  def handle_info(info, _ctx, state) do
    Logger.warning("SIP Endpoint: Unexpected info: #{inspect(info)}. Ignoring.")
    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    Logger.debug("SIP Endpoint: Received terminate request")

    case state.endpoint_state do
      :calling ->
        OutgoingCall.cancel(state.call_id)
        Process.sleep(50)

      :in_call ->
        OutgoingCall.bye(state.call_id)
        Process.sleep(50)

      _other ->
        nil
    end

    unless state.endpoint_state in [:unregistered, :unregistered_call_pending, :registered] do
      Call.stop(state.call_id)
    end

    Call.stop(state.register_call_id)

    {[terminate: :normal], %{state | endpoint_state: :terminating}}
  end

  defp spawn_call(state, module \\ OutgoingCall) do
    state
    |> case do
      %State{} = struct -> Map.from_struct(struct)
      %{} = map -> map
      _other -> raise "State is not map nor struct"
    end
    |> Map.put(:endpoint, self())
    |> then(&struct(Call.Settings, &1))
    |> module.start_link()
  end
end
