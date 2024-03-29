defmodule Membrane.RTC.Engine.Endpoint.SIP do
  @moduledoc """
  An Endpoint responsible for:
  * registering at a SIP provider,
  * dialing a phone number,
  * receiving audio from the callee and forwarding it to other Endpoints,
  * mixing audio tracks from other Endpoints and sending them to the callee.

  ## Limitations
  * Incoming calls are unsupported,
  * only the G.711 A-law audio codec is supported (SDP negotiation will fail if the SIP provider doesn't support it).

  ## Setup
  All SIP Endpoints share a single UDP socket for SIP signaling messages.
  By default, it is opened on `0.0.0.0:5060`; this can be changed by adding the following line to your `config.exs`:
  ```
  config :membrane_rtc_engine_sip, sip_address: "1.2.3.4", sip_port: 5061
  ```

  The range of UDP ports (available to all SIP Endpoints) used for RTP media stream exchange
  can be modified by adding the following line to your `config.exs`:
  ```
  config :membrane_rtc_engine_sip, port_range: {from, to}     # (both ends inclusive)
  ```
  """

  use Membrane.Bin

  require Membrane.G711
  require Membrane.Logger

  alias Membrane.{Logger, RawAudio, Time}
  alias Membrane.RTC.Engine

  alias Membrane.RTC.Engine.Endpoint.SIP.{
    Call,
    OutgoingCall,
    PortAllocator,
    RegisterCall,
    RegistrarCredentials
  }

  alias Membrane.RTC.Engine.Endpoint.WebRTC.{TrackReceiver, TrackSender}
  alias Membrane.RTC.Engine.Notifications.TrackNotification
  alias Membrane.RTC.Engine.Subscriptions
  alias Membrane.RTC.Engine.Track
  alias Membrane.RTP.SessionBin

  @default_sip_port 5060
  @register_interval_ms 45_000
  @audio_mixer_delay Time.milliseconds(200)
  @opus_sample_rate 48_000

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
                description: "Credentials needed to connect with the SIP registrar server"
              ],
              external_ip: [
                spec: String.t(),
                description:
                  "External IPv4 address of the machine running the Endpoint, required for SDP negotiation"
              ],
              register_interval_ms: [
                spec: non_neg_integer(),
                description: """
                Interval (in ms) in which keep-alive (keep-registered) REGISTER messages
                will be sent to the SIP registrar server
                """,
                default: @register_interval_ms
              ],
              disconnect_if_alone: [
                spec: boolean(),
                description: """
                Whether the Endpoint should disconnect from the call when all incoming tracks are removed,
                i.e. when all other Endpoints publishing audio are removed from the Engine
                """,
                default: true
              ]

  @doc """
  Starts calling a specified number
  """
  @spec dial(rtc_engine :: pid(), endpoint_id :: String.t(), phone_number :: String.t()) :: :ok
  def dial(rtc_engine, endpoint_id, phone_number) do
    Engine.message_endpoint(rtc_engine, endpoint_id, {:dial, phone_number})
  end

  @doc """
  Ends ongoing call or cancels call attempt
  """
  @spec end_call(rtc_engine :: pid(), endpoint_id :: String.t()) :: :ok
  def end_call(rtc_engine, endpoint_id) do
    Engine.message_endpoint(rtc_engine, endpoint_id, :end_call)
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
            register_interval_ms: non_neg_integer(),
            disconnect_if_alone: boolean(),
            endpoint_state: endpoint_state(),
            rtp_port: 1..65_535,
            sip_port: 1..65_535,
            outgoing_track: Track.t(),
            subscriptions_state: Subscriptions.State.t(),
            outgoing_ssrc: Membrane.RTP.ssrc_t(),
            first_ssrc: Membrane.RTP.ssrc_t() | nil,
            register_call_id: Call.id(),
            call_id: Call.id() | nil,
            phone_number: String.t() | nil,
            payload_type: ExSDP.Attribute.RTPMapping.payload_type_t()
          }

    @enforce_keys [
      :rtc_engine,
      :registrar_credentials,
      :external_ip,
      :register_interval_ms,
      :disconnect_if_alone,
      :endpoint_state,
      :rtp_port,
      :sip_port,
      :outgoing_track,
      :subscriptions_state,
      :outgoing_ssrc,
      :first_ssrc,
      :register_call_id,
      :call_id,
      :phone_number,
      :payload_type
    ]

    defstruct @enforce_keys
  end

  @impl true
  def handle_init(ctx, opts) do
    Logger.debug("SIP Endpoint: Init")

    {:endpoint, endpoint_id} = ctx.name

    subscriptions_state = %Subscriptions.State{
      subscribe_mode: :auto,
      endpoint_id: endpoint_id,
      rtc_engine: opts.rtc_engine
    }

    track =
      Track.new(
        :audio,
        Track.stream_id(),
        endpoint_id,
        :OPUS,
        @opus_sample_rate,
        %ExSDP.Attribute.FMTP{pt: Membrane.RTP.PayloadFormat.get(:OPUS)}
      )

    {register_call_id, _pid} = spawn_call(opts, RegisterCall)

    self_pid = self()

    Membrane.ResourceGuard.register(
      ctx.resource_guard,
      fn -> PortAllocator.free_ports(self_pid) end
    )

    with {:ok, rtp_port} <- PortAllocator.get_port() do
      state =
        opts
        |> Map.from_struct()
        |> Map.merge(%{
          endpoint_state: :unregistered,
          rtp_port: rtp_port,
          sip_port: Application.get_env(:membrane_rtc_engine_sip, :sip_port, @default_sip_port),
          outgoing_track: track,
          subscriptions_state: subscriptions_state,
          outgoing_ssrc: SessionBin.generate_receiver_ssrc([], []),
          first_ssrc: nil,
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
  def handle_playing(ctx, state) do
    state =
      if state.phone_number != nil,
        do: try_calling(state, ctx.playback, state.phone_number),
        else: state

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    track = get_in(state, [:subscriptions_state, :tracks, track_id])

    spec = [
      bin_input(pad)
      |> child({:track_receiver, track.id}, %TrackReceiver{
        track: track,
        initial_target_variant: :high
      })
      |> child({:depayloader, track.id}, Track.get_depayloader(track))
      |> child({:opus_decoder, track.id}, Membrane.Opus.Decoder)
      |> via_in(Pad.ref(:input, track.id))
      |> get_child(:audio_mixer)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {track_id, :high}) = pad, _ctx, state)
      when track_id == state.outgoing_track.id do
    Logger.debug("Pad added for track #{inspect(track_id)}, variant :high")

    spec = [
      get_rtp_stream_pipeline(state.first_ssrc)
      |> child(:funnel, %Membrane.Funnel{})
      |> child({:payloader, track_id}, %Membrane.RTP.PayloaderBin{
        payloader: Membrane.RTP.Opus.Payloader,
        ssrc: state.first_ssrc,
        payload_type: Membrane.RTP.PayloadFormat.get(:OPUS),
        clock_rate: @opus_sample_rate
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
    {_track, state} = pop_in(state, [:subscriptions_state, :tracks, track_id])

    children_to_remove =
      [:track_receiver, :depayloader, :opus_decoder] |> Enum.map(&{&1, track_id})

    actions = [remove_children: children_to_remove]

    if state.disconnect_if_alone and map_size(state.subscriptions_state.tracks) == 0 do
      {actions ++ [notify_parent: :finished], state}
    else
      {actions, state}
    end
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {_track_id, _variant}), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:dial, phone_number}, ctx, state) do
    # Strip whitespace and separator characters
    phone_number = String.replace(phone_number, ~r/[-.() \t\r\n]+/, "")

    unless Regex.match?(~r/^\+?\d+$/, phone_number) do
      raise "Invalid phone number: #{inspect(phone_number)}. Only digits and `+` are allowed in number"
    end

    state = try_calling(state, ctx.playback, phone_number)

    {[], state}
  end

  @impl true
  def handle_parent_notification(:end_call, _ctx, state) do
    new_endpoint_state =
      case state.endpoint_state do
        :unregistered_call_pending ->
          Logger.info("SIP Endpoint: Cancelling call attempt")
          send(self(), {:call_info, {:end, :cancelled}})
          :ending_call

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
  def handle_parent_notification({:new_tracks, tracks}, _ctx, state) do
    tracks = Enum.filter(tracks, fn track -> track.type == :audio end)

    subscriptions_state = Subscriptions.State.handle_new_tracks(tracks, state.subscriptions_state)
    {[], %{state | subscriptions_state: subscriptions_state}}
  end

  @impl true
  def handle_parent_notification({topic, _data}, _ctx, state)
      when topic in [:remove_tracks, :ready, :endpoint_added, :endpoint_removed] do
    {[], state}
  end

  @impl true
  def handle_parent_notification(%TrackNotification{}, _ctx, state) do
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
      when is_nil(state.first_ssrc) or ssrc == state.first_ssrc do
    Logger.debug("SIP Endpoint: New RTP stream connected: #{inspect(msg)}")

    state = %{state | first_ssrc: ssrc}

    if fmt != state.payload_type do
      raise """
      Payload type mismatch between RTP mapping and received stream
      (expected #{inspect(state.payload_type)}, got #{inspect(fmt)})
      """
    end

    {[
       notify_child: {:audio_mixer, {:start_mixing, @audio_mixer_delay}},
       notify_parent:
         {:track_ready, state.outgoing_track.id, :high, state.outgoing_track.encoding},
       notify_parent: {:forward_to_parent, :received_rtp_stream}
     ], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, fmt, _extensions},
        :rtp,
        _ctx,
        state
      ) do
    Logger.debug("Received another RTP stream with ssrc: #{ssrc}")

    if fmt != state.payload_type do
      raise """
      Payload type mismatch between RTP mapping and received stream
      (expected #{inspect(state.payload_type)}, got #{inspect(fmt)})
      """
    end

    spec =
      ssrc
      |> get_rtp_stream_pipeline()
      |> get_child(:funnel)

    {[spec: spec], state}
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
    Logger.debug("SIP Endpoint: Ringing...")
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
          sample_rate: @opus_sample_rate,
          sample_format: :s16le
        }
      })
      |> child(:converter_out, %Membrane.FFmpeg.SWResample.Converter{
        input_stream_format: %RawAudio{
          channels: 1,
          sample_format: :s16le,
          sample_rate: @opus_sample_rate
        },
        output_stream_format: %RawAudio{
          channels: 1,
          sample_format: :s16le,
          sample_rate: Membrane.G711.sample_rate()
        }
      })
      |> child(:audio_codec_encoder, Membrane.G711.Encoder)
      |> child(:audio_codec_parser, %Membrane.G711.Parser{overwrite_pts?: true})
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
      notify_parent: {:forward_to_parent, msg},
      notify_parent: :finished
    ]

    actions =
      if state.endpoint_state != :in_call do
        [notify_parent: :ready] ++ actions
      else
        actions
      end

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

      :in_call ->
        OutgoingCall.bye(state.call_id)

      _other ->
        nil
    end

    Call.stop(state.register_call_id)

    {[terminate: :normal], %{state | endpoint_state: :terminating}}
  end

  defp try_calling(state, playback_state, phone_number) do
    case state.endpoint_state do
      _any when playback_state != :playing ->
        Logger.info("SIP Endpoint: Postponing call until in state playing")
        %{state | phone_number: phone_number}

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
  end

  defp spawn_call(state, module \\ OutgoingCall) do
    state
    |> Call.Settings.new()
    |> module.start_link()
  end

  defp get_rtp_stream_pipeline(ssrc) do
    get_child(:rtp)
    |> via_out(Pad.ref(:output, ssrc),
      options: [depayloader: Membrane.RTP.G711.Depayloader]
    )
    |> child({:audio_codec_decoder, ssrc}, Membrane.G711.Decoder)
    |> child({:converter, ssrc}, %Membrane.FFmpeg.SWResample.Converter{
      input_stream_format: %RawAudio{
        channels: 1,
        sample_format: :s16le,
        sample_rate: Membrane.G711.sample_rate()
      },
      output_stream_format: %RawAudio{
        channels: 1,
        sample_format: :s16le,
        sample_rate: @opus_sample_rate
      }
    })
    |> child({:raw_audio_parser, ssrc}, %Membrane.RawAudioParser{
      stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: @opus_sample_rate},
      overwrite_pts?: true
    })
    |> child({:opus_encoder, ssrc}, %Membrane.Opus.Encoder{
      input_stream_format: %Membrane.RawAudio{
        channels: 1,
        sample_rate: @opus_sample_rate,
        sample_format: :s16le
      }
    })
    |> child({:opus_parser, ssrc}, Membrane.Opus.Parser)
  end
end
