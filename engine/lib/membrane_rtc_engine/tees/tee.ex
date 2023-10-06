defmodule Membrane.RTC.Engine.Tee do
  @moduledoc false
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RTC.Engine.Exception.VoiceActivityError

  alias Membrane.RTC.Engine.Event.{
    RequestTrackVariant,
    TrackVariantBitrate,
    TrackVariantPaused,
    TrackVariantResumed,
    TrackVariantSwitched,
    VoiceActivityChanged
  }

  alias Membrane.RTC.Engine.Exception.{RequestTrackVariantError, TrackVariantStateError}

  @supported_codecs [:H264, :VP8, :OPUS]

  def_options track: [
                type: :struct,
                spec: Membrane.RTC.Engine.Track.t(),
                description: "Track this tee is going to forward to other endpoints"
              ]

  def_input_pad :input,
    availability: :on_request,
    mode: :pull,
    demand_mode: :auto,
    accepted_format: Membrane.RTP

  def_output_pad :output,
    availability: :on_request,
    mode: :push,
    accepted_format: Membrane.RTP

  @impl true
  def handle_init(_ctx, opts) do
    if opts.track.encoding not in @supported_codecs do
      raise("""
      #{inspect(__MODULE__)} does not support codec #{inspect(opts.track.encoding)}.
      Supported codecs: #{inspect(@supported_codecs)}
      """)
    end

    {[],
     %{
       track: opts.track,
       routes: %{},
       inactive_variants: MapSet.new(opts.track.variants),
       variant_bitrates: %{},
       vad: %{}
     }}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, {_track_id, _variant}), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:output, {:endpoint, _endpoint_id}) = pad,
        %{playback: playback},
        state
      ) do
    state =
      put_in(state, [:routes, pad], %{
        target_variant: nil,
        current_variant: nil
      })

    actions =
      if playback == :playing do
        actions =
          state
          |> active_variants()
          |> Enum.flat_map(
            &[
              event: {pad, %TrackVariantResumed{variant: &1}}
            ]
          )

        activate_pad_actions(pad, state) ++ actions
      else
        []
      end

    {actions, state}
  end

  @impl true
  def handle_pad_added(pad, _ctx, _state) do
    raise "Pad #{inspect(pad)} not allowed for #{inspect(__MODULE__)}"
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {:endpoint, _endpoint_id}) = pad, _ctx, state) do
    {_route, state} = pop_in(state, [:routes, pad])
    {[], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, {_track_id, _rid}), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    actions =
      ctx.pads
      |> Enum.filter(fn {_pad, %{name: name}} -> name == :output end)
      |> Enum.flat_map(fn {pad, _pad_data} ->
        activate_pad_actions(pad, state)
      end)

    {actions, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, {_track_id, _variant}), %VoiceActivityChanged{}, _ctx, state)
      when state.track.type != :audio,
      do: raise(VoiceActivityError, track: state.track)

  @impl true
  def handle_event(
        Pad.ref(:input, {_track_id, variant}),
        %VoiceActivityChanged{voice_activity: vad} = event,
        _ctx,
        state
      ) do
    state = put_in(state, [:vad, variant], vad)

    # only forward to subscribed routes
    actions =
      state.routes
      |> Enum.filter(fn {_pad, config} -> config.current_variant == variant end)
      |> Enum.map(fn {pad, _config} -> {:event, {pad, event}} end)

    {actions, state}
  end

  @impl true
  def handle_event(
        Pad.ref(:input, _id),
        %TrackVariantBitrate{variant: variant, bitrate: bitrate} = event,
        _ctx,
        state
      ),
      do: {[forward: event], put_in(state, [:variant_bitrates, variant], bitrate)}

  @impl true
  def handle_event(Pad.ref(:input, id), %TrackVariantPaused{} = event, _ctx, state) do
    Membrane.Logger.info("Track variant #{inspect(id)} paused.")
    {_track_id, variant} = id
    state = Map.update!(state, :inactive_variants, &MapSet.put(&1, variant))

    # reset all target and current variants set to `variant`
    # when `variant` becomes active again
    # endpoints are expected to request it once again
    state =
      Enum.reduce(state.routes, state, fn
        {output_pad, %{target_variant: ^variant}}, state ->
          put_in(state, [:routes, output_pad, :target_variant], nil)

        {output_pad, %{current_variant: ^variant}}, state ->
          put_in(state, [:routes, output_pad, :current_variant], nil)

        _route, state ->
          state
      end)

    {[forward: event], state}
  end

  @impl true
  def handle_event(Pad.ref(:input, id), %TrackVariantResumed{} = event, _ctx, state) do
    Membrane.Logger.info("Track variant #{inspect(id)} resumed.")
    {_track_id, variant} = id
    state = Map.update!(state, :inactive_variants, &MapSet.delete(&1, variant))
    {[forward: event], state}
  end

  @impl true
  def handle_event(
        Pad.ref(:output, {:endpoint, endpoint_id}) = output_pad,
        %RequestTrackVariant{variant: requested_variant} = event,
        _ctx,
        state
      ) do
    cond do
      requested_variant not in state.track.variants ->
        raise RequestTrackVariantError,
          requester: endpoint_id,
          requested_variant: requested_variant,
          track: state.track

      requested_variant in state.inactive_variants ->
        Membrane.Logger.debug("""
        Endpoint #{endpoint_id} requested track variant: #{requested_variant} but it is inactive. \
        Ignoring.\
        """)

        {[], state}

      true ->
        Membrane.Logger.debug("""
        Endpoint #{endpoint_id} requested track variant #{requested_variant}. \
        Requesting keyframe.
        """)

        handle_track_variant_request(output_pad, event, state)
    end
  end

  @impl true
  def handle_event(
        Pad.ref(:output, {:endpoint, endpoint_id}) = pad,
        %Membrane.KeyframeRequestEvent{} = event,
        _ctx,
        state
      ) do
    %{current_variant: current_variant} = state.routes[pad]

    if current_variant do
      {[event: {Pad.ref(:input, {state.track.id, current_variant}), event}], state}
    else
      Membrane.Logger.warning("""
      Endpoint #{endpoint_id} requested keyframe but we don't send any variant to it. Ignoring.
      """)

      {[], state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_process(Pad.ref(:input, {_track_id, variant}), buffer, ctx, state) do
    if variant in state.inactive_variants do
      raise TrackVariantStateError, track: state.track, variant: variant
    end

    Enum.flat_map_reduce(state.routes, state, fn route, state ->
      handle_route(buffer, variant, route, ctx, state)
    end)
  end

  @impl true
  def handle_end_of_stream(_pad, ctx, state) do
    all_end_of_streams? =
      ctx.pads
      |> Enum.filter(fn {_pad_name, pad_data} ->
        pad_data.direction == :input
      end)
      |> Enum.all?(fn {_pad_name, pad_data} ->
        pad_data.end_of_stream?
      end)

    if all_end_of_streams? do
      {[forward: :end_of_stream], state}
    else
      {[], state}
    end
  end

  defp handle_track_variant_request(output_pad, event, state) do
    %RequestTrackVariant{variant: requested_variant, reason: reason} = event
    pad = Pad.ref(:input, {state.track.id, requested_variant})

    actions = [event: {pad, %Membrane.KeyframeRequestEvent{}}]

    state =
      state
      |> put_in([:routes, output_pad, :target_variant], requested_variant)
      |> put_in([:routes, output_pad, :reason], reason)

    {actions, state}
  end

  defp handle_route(buffer, variant, {output_pad, %{current_variant: variant}}, _ctx, state) do
    {[buffer: {output_pad, buffer}], state}
  end

  defp handle_route(buffer, variant, {output_pad, %{target_variant: variant}}, _ctx, state) do
    if buffer.metadata.is_keyframe do
      event = %TrackVariantSwitched{new_variant: variant, reason: state.routes[output_pad].reason}

      state =
        state
        |> put_in([:routes, output_pad, :current_variant], variant)
        |> put_in([:routes, output_pad, :target_variant], nil)
        |> put_in([:routes, output_pad, :reason], nil)

      vad_event_action =
        if Map.has_key?(state.vad, variant),
          do: [event: {output_pad, %VoiceActivityChanged{voice_activity: state.vad[variant]}}],
          else: []

      actions = [event: {output_pad, event}] ++ vad_event_action ++ [buffer: {output_pad, buffer}]
      {actions, state}
    else
      {[], state}
    end
  end

  defp handle_route(_buffer, _variant, _route, _ctx, state), do: {[], state}

  defp activate_pad_actions(Pad.ref(:output, _id) = pad, state) do
    [stream_format: {pad, %Membrane.RTP{}}] ++
      Enum.flat_map(state.variant_bitrates, fn {variant, bitrate} ->
        [event: {pad, %TrackVariantBitrate{variant: variant, bitrate: bitrate}}]
      end)
  end

  defp active_variants(state),
    do:
      state.track.variants
      |> MapSet.new()
      |> MapSet.difference(state.inactive_variants)
end
