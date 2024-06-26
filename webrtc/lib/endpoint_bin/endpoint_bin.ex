defmodule Membrane.WebRTC.EndpointBin do
  @moduledoc """
  Module responsible for interacting with a WebRTC peer.

  New tracks are specified by SDP negotiation conducted by messages
  `t:signal_message/0`, and then linking corresponding
  `:input` and `:output` pads with ids reported via `t:new_track_notification/0`

  The tracks can be manipulated by sending `t:track_message/0`.

  To initiate or modify the connection, the bin sends and expects to receive
  `t:signal_message/0`.
  """
  use Membrane.Bin
  use Bunch

  require Membrane.Logger

  require Membrane.TelemetryMetrics

  alias __MODULE__.TracksState
  alias ExSDP.Attribute.{FMTP, RTPMapping}
  alias Membrane.ICE
  alias Membrane.RTP
  alias Membrane.WebRTC.{Extension, SDP, Track}
  alias Membrane.WebRTC.Utils

  # we always want to use ICE lite at the moment
  @ice_lite true

  @sdp_offer_event [Membrane.WebRTC, :sdp, :offer]
  @sdp_answer_event [Membrane.WebRTC, :sdp, :answer]

  @type new_track_notification ::
          {:new_track, Track.id(), nil | Track.rid(), RTP.ssrc_t(), Track.encoding_key(),
           depayloading_filter :: module()}
  @type signal_message ::
          {:signal, {:sdp_offer | :sdp_answer, String.t()} | {:candidate, String.t()}}

  @type track_message :: alter_tracks_message()

  @typedoc """
  Message that adds or removes tracks.
  """
  @type alter_tracks_message :: {:add_tracks, [Track.t()]} | {:remove_tracks, [Track.t()]}

  @typedoc """
  Type describing possible media flow directions.

  * `:recvonly` - only receive media from the peer
  * `:sendonly` - only send media to the peer
  * `:sendrecv` - both send and receive media from the peer
  """
  @type direction() :: :recvonly | :sendonly | :sendrecv

  def_options direction: [
                spec: direction(),
                default: :sendrecv,
                description: """
                Direction of EndpointBin. Determines whether
                EndpointBin can send, receive or both send and receive media.
                For more information refer to t:direction/0.
                """
              ],
              handshake_opts: [
                type: :list,
                spec: Keyword.t(),
                default: [],
                description: """
                Keyword list with options for handshake module. For more information please
                refer to `t:ExDTLS.opts_t/0`
                """
              ],
              rtcp_receiver_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Receiver reports's generation interval, set to nil to avoid reports generation"
              ],
              rtcp_sender_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Sender reports's generation interval, set to nil to avoid reports generation"
              ],
              filter_codecs: [
                spec: (Membrane.WebRTC.Track.Encoding.t() -> boolean()),
                default: &SDP.filter_encodings(&1),
                description: "Defines function which will filter SDP m-line by codecs"
              ],
              extensions: [
                spec: [Extension.t()],
                default: [],
                description: "List of WebRTC extensions that should be enabled"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ],
              integrated_turn_options: [
                spec: [ICE.Endpoint.integrated_turn_options_t()],
                default: [],
                description: "Integrated TURN Options"
              ],
              simulcast?: [
                spec: boolean(),
                default: true,
                description: """
                Whether to accept simulcast tracks or not.
                If set to `false`, simulcast tracks will be disabled i.e.
                sender will not send them.
                """
              ],
              telemetry_label: [
                spec: Membrane.TelemetryMetrics.label(),
                default: [],
                description: "Label passed to Membrane.TelemetryMetrics functions"
              ]

  def_input_pad :input,
    accepted_format: _any,
    availability: :on_request,
    options: [
      use_payloader?: [
        spec: boolean(),
        default: true,
        description: """
        Defines if incoming stream should be payloaded based on given encoding.
        Otherwise the stream is assumed  be in RTP format.
        """
      ]
    ]

  def_output_pad :output,
    accepted_format: _any,
    availability: :on_request,
    options: [
      extensions: [
        spec: [Membrane.RTP.SessionBin.extension_t()],
        default: [],
        description:
          "List of general extensions that will be applied to the SessionBin's output pad"
      ],
      use_depayloader?: [
        spec: boolean(),
        default: true,
        description: """
        Defines if the outgoing stream should get depayloaded.

        This option should be used as a convenience, it is not necessary as the new track notification
        returns a depayloading filter's definition that can be attached to the output pad
        to work the same way as with the option set to true.
        """
      ]
    ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    alias Membrane.WebRTC.EndpointBin.TracksState

    @type t :: %__MODULE__{
            log_metadata: Keyword.t(),
            tracks: TracksState.t(),
            endpoint_direction: Membrane.WebRTC.EndpointBin.direction(),
            rtcp_sender_report_interval: Membrane.Time.t() | nil,
            candidates: [any()],
            candidate_gathering_state: nil | :in_progress | :done,
            dtls_fingerprint: nil | {:sha256, binary()},
            pending_rtx: %{Track.id() => {Track.rid(), RTP.ssrc_t()}},
            filter_codecs: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
            extensions: [Extension.t()],
            integrated_turn_servers: [any()],
            component_path: String.t(),
            simulcast?: boolean(),
            telemetry_label: Membrane.TelemetryMetrics.label(),
            ice: %{
              restarting?: boolean(),
              waiting_restart?: boolean(),
              pwd: nil | String.t(),
              ufrag: nil | String.t(),
              first?: boolean()
            }
          }

    defstruct log_metadata: [],
              tracks: %TracksState{},
              endpoint_direction: :sendrecv,
              rtcp_sender_report_interval: nil,
              candidates: [],
              candidate_gathering_state: nil,
              dtls_fingerprint: nil,
              pending_rtx: %{},
              filter_codecs: &SDP.filter_encodings(&1),
              extensions: [],
              integrated_turn_servers: [],
              component_path: "",
              simulcast?: true,
              telemetry_label: [],
              ice: %{
                restarting?: false,
                waiting_restart?: false,
                pwd: nil,
                ufrag: nil,
                first?: true
              }
  end

  @impl true
  def handle_init(_ctx, %__MODULE__{} = opts) do
    Membrane.TelemetryMetrics.register(@sdp_offer_event, opts.telemetry_label)
    Membrane.TelemetryMetrics.register(@sdp_answer_event, opts.telemetry_label)

    rtp_input_ref = make_ref()

    spec = [
      child(:ice, %ICE.Endpoint{
        integrated_turn_options: opts.integrated_turn_options,
        handshake_opts: opts.handshake_opts,
        telemetry_label: opts.telemetry_label
      }),
      child(:rtp, %Membrane.RTP.SessionBin{
        secure?: true,
        rtcp_receiver_report_interval: opts.rtcp_receiver_report_interval,
        rtcp_sender_report_interval: opts.rtcp_sender_report_interval
      }),
      child(:ice_funnel, Membrane.Funnel),
      # always link :rtcp_receiver_output to handle FIR RTCP packets
      get_child(:rtp)
      |> via_out(Pad.ref(:rtcp_receiver_output, rtp_input_ref))
      |> get_child(:ice_funnel),
      get_child(:ice)
      |> via_out(Pad.ref(:output, 1))
      |> via_in(Pad.ref(:rtp_input, rtp_input_ref))
      |> get_child(:rtp),
      get_child(:ice_funnel)
      |> via_out(:output)
      |> via_in(Pad.ref(:input, 1))
      |> get_child(:ice)
    ]

    spec = {spec, log_metadata: opts.log_metadata}

    extensions = Enum.map(opts.extensions, &if(is_struct(&1), do: &1, else: &1.new()))

    state = %State{
      log_metadata: opts.log_metadata,
      endpoint_direction: opts.direction,
      rtcp_sender_report_interval: opts.rtcp_sender_report_interval,
      filter_codecs: opts.filter_codecs,
      integrated_turn_servers: ICE.TURNManager.get_launched_turn_servers(),
      extensions: extensions,
      component_path: Membrane.ComponentPath.get_formatted(),
      simulcast?: opts.simulcast?,
      telemetry_label: opts.telemetry_label
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    # TODO: check this one
    %{use_payloader?: use_payloader?} = ctx.pad_options

    %Track{
      ssrc: ssrc,
      selected_encoding_key: encoding_key,
      selected_encoding: encoding,
      extmaps: extmaps
    } = Map.fetch!(state.tracks.outbound, track_id)

    rtp_extension_mapping = Map.new(extmaps, &Extension.as_rtp_mapping(state.extensions, &1))

    options = [
      encoding: encoding_key,
      clock_rate: encoding.clock_rate,
      payload_type: encoding.payload_type,
      rtp_extension_mapping: rtp_extension_mapping
    ]

    encoding_specific_links =
      case encoding_key do
        :H264 when use_payloader? ->
          &child(&1, {:h264_parser, ssrc}, %Membrane.H264.Parser{output_alignment: :nalu})

        _other ->
          & &1
      end

    payloader =
      if use_payloader? do
        {:ok, payloader} = Membrane.RTP.PayloadFormatResolver.payloader(encoding_key)

        payloader
      else
        nil
      end

    rtp_extensions = to_rtp_extensions(extmaps, :outbound, state)

    actions = [
      spec:
        get_child(:rtp)
        |> via_out(Pad.ref(:rtcp_sender_output, ssrc))
        |> get_child(:ice_funnel),
      spec:
        bin_input(pad)
        |> then(encoding_specific_links)
        |> via_in(Pad.ref(:input, ssrc),
          options: [
            payloader: payloader,
            rtp_extensions: rtp_extensions,
            telemetry_label: state.telemetry_label ++ [track_id: "#{track_id}"]
          ]
        )
        |> get_child(:rtp)
        |> via_out(Pad.ref(:rtp_output, ssrc), options: options)
        |> get_child(:ice_funnel)
    ]

    {actions, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {track_id, rid}) = pad, ctx, state) do
    %Track{
      ssrc: ssrc,
      selected_encoding_key: encoding_key,
      selected_encoding: encoding,
      extmaps: extmaps
    } = track = Map.fetch!(state.tracks.inbound, track_id)

    # if `rid` is set, it is a request for specific encoding of simulcast track
    # choose ssrc which corresponds to given `rid`
    ssrc = if rid, do: Map.fetch!(track.rid_to_ssrc, rid), else: ssrc

    %{
      use_depayloader?: use_depayloader?
    } = ctx.pad_options

    depayloader =
      if use_depayloader? do
        {:ok, depayloader} = Membrane.RTP.PayloadFormatResolver.depayloader(encoding_key)

        depayloader
      else
        nil
      end

    telemetry_label = state.telemetry_label ++ [track_id: "#{track_id}:#{rid}"]

    output_pad_options = [
      extensions: ctx.pad_options.extensions,
      rtp_extensions: to_rtp_extensions(extmaps, :inbound, state),
      clock_rate: encoding.clock_rate,
      depayloader: depayloader,
      telemetry_label: telemetry_label,
      encoding: encoding_key
    ]

    spec =
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc), options: output_pad_options)
      |> bin_output(pad)

    state = put_in(state.tracks.inbound[track_id].status, :linked)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_pad_removed(:rtp, Pad.ref(pad_name, _id), _ctx, state)
      when pad_name in [:rtp_output, :rtcp_sender_output] do
    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, pt, _rtp_header_extensions},
        _from,
        _ctx,
        %State{endpoint_direction: :sendonly} = _state
      ) do
    raise """
    Received new RTP stream but EndpointBin is set to :sendonly.
    RTP stream params: SSRC: #{inspect(ssrc)}, PT: #{inspect(pt)}"
    """
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, pt, rtp_header_extensions},
        _from,
        _ctx,
        %State{} = state
      ) do
    stream_info =
      TracksState.identify_inbound_stream(
        state.tracks,
        ssrc,
        pt,
        rtp_header_extensions,
        state.extensions
      )

    state = %State{state | tracks: TracksState.register_stream(state.tracks, ssrc, stream_info)}
    {_cast_type, encoding_type, rid, track_id} = stream_info

    case encoding_type do
      :rtx -> handle_new_rtx_stream(ssrc, track_id, rid, state)
      :media -> handle_new_rtp_stream(ssrc, track_id, rid, state)
    end
  end

  @impl true
  def handle_child_notification(
        {:handshake_init_data, _component_id, fingerprint},
        _from,
        _ctx,
        state
      ) do
    {[], %{state | dtls_fingerprint: {:sha256, hex_dump(fingerprint)}}}
  end

  @impl true
  def handle_child_notification({:local_credentials, credentials}, _from, _ctx, state) do
    [ice_ufrag, ice_pwd] = String.split(credentials, " ")

    {actions, state} =
      if state.ice.first? and state.tracks.outbound == %{} do
        {[], state}
      else
        state = Map.update!(state, :ice, &%{&1 | first?: false})
        get_offer_data(state)
      end

    state = %{state | ice: %{state.ice | ufrag: ice_ufrag, pwd: ice_pwd}}
    {actions, state}
  end

  @impl true
  def handle_child_notification({:new_candidate_full, cand}, _from, _ctx, state) do
    state = Map.update!(state, :candidates, &[cand | &1])
    {notify_candidates([cand]), state}
  end

  @impl true
  def handle_child_notification(:candidate_gathering_done, _from, _ctx, state) do
    {[], %{state | candidate_gathering_state: :done}}
  end

  @impl true
  def handle_child_notification(
        {:connection_failed, _stream_id, _component_id},
        _from,
        _ctx,
        state
      ) do
    state = %{state | ice: %{state.ice | restarting?: false}}
    maybe_restart_ice(state, true)
  end

  @impl true
  def handle_child_notification(
        {:connection_ready, _stream_id, _component_id},
        _from,
        _ctx,
        state
      )
      when state.ice.restarting? do
    new_outbound_tracks =
      state.tracks.outbound
      |> Map.values()
      |> Enum.filter(&(&1.status === :ready && &1.selected_encoding != nil))

    negotiations = [notify_parent: {:negotiation_done, new_outbound_tracks}]

    state =
      state
      |> Map.update!(:tracks, &TracksState.change_outbound_status(&1, :ready, :linked))
      |> put_in([:ice, :restarting?], false)

    {restart_action, state} = maybe_restart_ice(state)

    actions = negotiations ++ restart_action

    {actions, state}
  end

  @impl true
  def handle_child_notification(
        {:connection_ready, _stream_id, _component_id},
        _from,
        _ctx,
        state
      ),
      do: {[], state}

  @impl true
  def handle_child_notification({:udp_integrated_turn, turn}, _from, _ctx, state) do
    state = %{state | integrated_turn_servers: [turn] ++ state.integrated_turn_servers}
    {[], state}
  end

  @impl true
  def handle_child_notification({:bandwidth_estimation, _estimation} = msg, _from, _ctx, state) do
    {[notify_parent: msg], state}
  end

  @impl true
  def handle_child_notification(notification, from, _ctx, state) do
    Membrane.Logger.warning(
      "Ignoring child #{inspect(from)} notification #{inspect(notification)}"
    )

    {[], state}
  end

  @impl true
  def handle_parent_notification({:signal, {:sdp_offer, raw_sdp, mid_to_track_id}}, _ctx, state) do
    Membrane.TelemetryMetrics.execute(
      @sdp_offer_event,
      %{sdp: Utils.anonymize_sdp(raw_sdp)},
      %{},
      state.telemetry_label
    )

    sdp = ExSDP.parse!(raw_sdp)

    {new_inbound_tracks, removed_inbound_tracks, inbound_tracks, outbound_tracks} =
      get_tracks_from_sdp(sdp, mid_to_track_id, state)

    tracks_state =
      state.tracks
      |> TracksState.update(outbound: outbound_tracks, inbound: inbound_tracks)
      |> TracksState.add_inbound_tracks(new_inbound_tracks)

    state = %State{state | tracks: tracks_state}

    new_actions = new_tracks_actions(new_inbound_tracks)

    answer =
      SDP.create_answer(
        inbound_tracks: inbound_tracks,
        outbound_tracks: outbound_tracks,
        ice_ufrag: state.ice.ufrag,
        ice_pwd: state.ice.pwd,
        fingerprint: state.dtls_fingerprint,
        extensions: state.extensions,
        ice_lite?: @ice_lite
      )

    {actions, state} =
      withl tracks_check: false <- TracksState.empty?(state.tracks),
            candidate_gathering_check: nil <- state.candidate_gathering_state do
        {[notify_child: {:ice, :gather_candidates}],
         %{state | candidate_gathering_state: :in_progress}}
      else
        tracks_check: _ -> {[], state}
        candidate_gathering_check: _ -> {notify_candidates(state.candidates), state}
      end

    inbound_tracks = SDP.filter_simulcast_tracks(inbound_tracks)
    mid_to_track_id = Map.new(inbound_tracks ++ outbound_tracks, &{&1.mid, &1.id})

    actions =
      if Enum.empty?(removed_inbound_tracks),
        do: actions,
        else: actions ++ [notify_parent: {:removed_tracks, removed_inbound_tracks}]

    answer_str = to_string(answer)

    Membrane.TelemetryMetrics.execute(
      @sdp_answer_event,
      %{sdp: Utils.anonymize_sdp(answer_str)},
      %{},
      state.telemetry_label
    )

    actions =
      new_actions ++
        [notify_parent: {:signal, {:sdp_answer, answer_str, mid_to_track_id}}] ++
        set_remote_credentials(sdp) ++
        actions

    {actions, state}
  end

  @impl true
  def handle_parent_notification({:signal, {:candidate, _candidate}}, _ctx, state) do
    # TODO: decide what to do with this candidate
    {[], state}
  end

  @impl true
  def handle_parent_notification({:signal, :renegotiate_tracks}, _ctx, state) do
    cond do
      state.ice.first? and state.ice.pwd != nil ->
        state = Map.update!(state, :ice, &%{&1 | first?: false})
        get_offer_data(state)

      state.ice.first? ->
        state = Map.update!(state, :ice, &%{&1 | first?: false})
        {[], state}

      state.ice.pwd == nil ->
        {[], state}

      true ->
        maybe_restart_ice(state, true)
    end
  end

  @impl true
  def handle_parent_notification({:add_tracks, _tracks}, _ctx, %State{
        endpoint_direction: :recvonly
      }) do
    raise """
    Cannot add outbound tracks when EndpointBin is set to :recvonly.
    You can add outbound tracks only when EndpointBin is set to :sendonly or :sendrecv.
    """
  end

  @impl true
  def handle_parent_notification({:add_tracks, []}, _ctx, state) do
    Membrane.Logger.warning("Got empty :add_tracks notification. Ignoring.")
    {[], state}
  end

  @impl true
  def handle_parent_notification({:add_tracks, tracks}, _ctx, state) do
    state = %State{state | tracks: TracksState.add_outbound_tracks(state.tracks, tracks)}

    if state.ice.first? do
      state
      |> put_in([:ice, :first?], false)
      |> Map.update!(:tracks, &TracksState.change_outbound_status(&1, :pending, :ready))
      |> case do
        %{ice: %{pwd: nil}} = state -> {[], state}
        state -> get_offer_data(state)
      end
    else
      maybe_restart_ice(state, true)
    end
  end

  @impl true
  def handle_parent_notification({:remove_tracks, tracks_to_remove}, _ctx, state) do
    state
    |> Map.update!(:tracks, &TracksState.disable_tracks(&1, tracks_to_remove))
    |> maybe_restart_ice(true)
  end

  defp maybe_restart_ice(state, set_waiting_restart? \\ false) do
    state =
      if set_waiting_restart?,
        do: %{state | ice: %{state.ice | waiting_restart?: true}},
        else: state

    if not state.ice.restarting? and state.ice.waiting_restart? do
      state =
        state
        |> put_in([:ice, :restarting?], true)
        |> put_in([:ice, :waiting_restart?], false)
        |> Map.update!(:tracks, &TracksState.change_outbound_status(&1, :pending, :ready))

      {[notify_child: {:ice, :restart_stream}], state}
    else
      {[], state}
    end
  end

  defp get_offer_data(state) do
    tracks_types =
      state.tracks.outbound
      |> Map.values()
      |> Enum.filter(&(&1.status != :pending))
      |> Enum.map(& &1.type)

    media_count = %{
      audio: Enum.count(tracks_types, &(&1 == :audio)),
      video: Enum.count(tracks_types, &(&1 == :video))
    }

    actions = [
      notify_parent: {:signal, {:offer_data, media_count, state.integrated_turn_servers}}
    ]

    state = Map.update!(state, :ice, &%{&1 | restarting?: true})

    {actions, state}
  end

  defp get_tracks_from_sdp(sdp, mid_to_track_id, state) do
    old_inbound_tracks = Map.values(state.tracks.inbound)

    outbound_tracks = Map.values(state.tracks.outbound) |> Enum.filter(&(&1.status != :pending))

    constraints = %Track.Constraints{
      codecs_filter: state.filter_codecs,
      enabled_extensions: state.extensions,
      simulcast?: state.simulcast?,
      endpoint_direction: state.endpoint_direction
    }

    SDP.get_tracks(sdp, constraints, old_inbound_tracks, outbound_tracks, mid_to_track_id)
  end

  defp new_tracks_actions([]) do
    []
  end

  defp new_tracks_actions(new_tracks) do
    notify = [notify_parent: {:new_tracks, new_tracks}]

    known_ssrcs =
      new_tracks
      |> Enum.flat_map(fn track ->
        List.wrap(track.ssrc) ++ List.wrap(track.rtx_ssrc)
      end)

    require_extensions =
      new_tracks
      |> Enum.filter(&Track.simulcast?/1)
      |> Enum.flat_map(fn track ->
        mid_ext = Enum.find(track.extmaps, &(&1.uri == Extension.Mid.uri()))
        rid_ext = Enum.find(track.extmaps, &(&1.uri == Extension.Rid.uri()))
        repaired_rid_ext = Enum.find(track.extmaps, &(&1.uri == Extension.RepairedRid.uri()))

        if is_nil(mid_ext) or is_nil(rid_ext) do
          raise "Simulcast without mid or rid extensions is not supported!"
        end

        pt_to_ext_id = %{track.selected_encoding.payload_type => [mid_ext.id, rid_ext.id]}

        cond do
          is_nil(track.selected_encoding.rtx) ->
            pt_to_ext_id

          is_nil(repaired_rid_ext) ->
            raise "RTX simulcast requires RepairedRid extension to be enabled!"

          true ->
            Map.put(pt_to_ext_id, track.selected_encoding.rtx.payload_type, [
              mid_ext.id,
              repaired_rid_ext.id
            ])
        end
      end)
      |> then(
        &[
          notify_child:
            {:rtp,
             %Membrane.RTP.SSRCRouter.StreamsInfo{
               require_extensions: Map.new(&1),
               accept_ssrcs: known_ssrcs
             }}
        ]
      )

    require_extensions ++ notify
  end

  defp notify_candidates(candidates) do
    Enum.flat_map(candidates, fn cand ->
      [notify_parent: {:signal, {:candidate, cand, 0}}]
    end)
  end

  defp set_remote_credentials(sdp) do
    case List.first(sdp.media) do
      nil ->
        []

      media ->
        {_key, ice_ufrag} = ExSDP.get_attribute(media, :ice_ufrag)
        {_key, ice_pwd} = ExSDP.get_attribute(media, :ice_pwd)
        remote_credentials = ice_ufrag <> " " <> ice_pwd
        [notify_child: {:ice, {:set_remote_credentials, remote_credentials}}]
    end
  end

  defp hex_dump(digest_str) do
    digest_str
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end

  defp handle_new_rtx_stream(ssrc, track_id, nil, state) do
    # non-simulcast RTX, track.ssrc is not a list
    track = Map.fetch!(state.tracks.inbound, track_id)
    actions = rtx_info_actions(ssrc, track.ssrc, track, state.extensions)
    {actions, state}
  end

  defp handle_new_rtx_stream(ssrc, track_id, rid, state) do
    # simulcast RTX, we need a mapping from rid to ssrc
    track = Map.fetch!(state.tracks.inbound, track_id)

    case Map.fetch(track.rid_to_ssrc, rid) do
      :error ->
        # Since we don't know the original_ssrc yet, we must wait for it and out the new ssrc in pending_rtx map
        {[], put_in(state.pending_rtx[{track_id, rid}], ssrc)}

      {:ok, original_ssrc} ->
        actions = rtx_info_actions(ssrc, original_ssrc, track, state.extensions)
        {actions, state}
    end
  end

  defp handle_new_rtp_stream(ssrc, track_id, rid, state) do
    track = Map.fetch!(state.tracks.inbound, track_id)
    depayloading_filter = depayloading_filter_for(track)

    notification = [
      notify_parent:
        {:new_track, track_id, rid, ssrc, track.selected_encoding_key, depayloading_filter}
    ]

    {pending_rtx, state} = pop_in(state.pending_rtx[{track_id, rid}])

    case pending_rtx do
      nil ->
        {notification, state}

      rtx_ssrc ->
        rtx_info_actions = rtx_info_actions(rtx_ssrc, ssrc, track, state.extensions)

        {notification ++ rtx_info_actions, state}
    end
  end

  defp rtx_info_actions(ssrc, original_ssrc, track, extensions) do
    rtp_extension_mapping = Map.new(track.extmaps, &Extension.as_rtp_mapping(extensions, &1))

    rtx_info = %Membrane.RTP.SessionBin.RTXInfo{
      ssrc: ssrc,
      original_ssrc: original_ssrc,
      original_payload_type: track.selected_encoding.payload_type,
      rid_id: rtp_extension_mapping[:rid],
      repaired_rid_id: rtp_extension_mapping[:repaired_rid]
    }

    [notify_child: {:rtp, rtx_info}]
  end

  defp depayloading_filter_for(track) do
    case Membrane.RTP.PayloadFormatResolver.depayloader(track.selected_encoding_key) do
      {:ok, depayloader} ->
        %Membrane.RTP.DepayloaderBin{
          depayloader: depayloader,
          clock_rate: track.selected_encoding.clock_rate
        }

      :error ->
        nil
    end
  end

  defp to_rtp_extensions(extmaps, track_type, state) do
    extmaps
    |> Enum.map(&Extension.as_rtp_extension(state.extensions, &1, track_type))
    |> Enum.reject(fn {_name, rtp_module} -> rtp_module == :no_rtp_module end)
  end
end
