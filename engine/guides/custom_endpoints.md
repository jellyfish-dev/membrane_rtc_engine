# Custom endpoint

This section outlines how to implement a custom RTC Engine endpoint that
saves tracks published by the WebRTC endpoint.

> #### Before you continue {: .tip}
> It is recommended to read [Track Lifecycle](guides/track_lifecycle.md) section before
> diving deeper in this guide.
> You will also find there some information about publishing a track.

> #### HLS endpoint {: .tip}
> Another endpoint that saves WebRTC tracks and is shipped with the engine is [the HLS endpoint](https://hexdocs.pm/membrane_rtc_engine_hls/readme.html).

## General rules

Each RTC Engine endpoint has to:
* implement `Membrane.Bin` behavior
* have at least one Membrane element that will be responsible for producing or
consuming data as Membrane bins are used only for logical grouping - they
don't process data
* publish or/and subscribe to tracks

## Implementing `Membrane.Bin`

To implement `Membrane.Bin` behavior we have to:
* `use Membrane.Bin`
* specify some configuration options (if needed)
* specify input and/or output pads
* implement some callbacks.

Pads definition depends on what our bin is intended to do.
For example, if our endpoint does not publish any tracks but only subscribes for tracks from other
endpoints it can specify only input pads.
Pads should be in the following form

```elixir
def_input_pad :input,
    demand_unit: :buffers,
    stream_format: Membrane.RTP,
    availability: :on_request

def_output_pad :output,
    demand_unit: :buffers,
    stream_format: Membrane.RTP,
    availability: :on_request
```

When it comes to endpoint options we will have:
* `rtc_engine` - pid of RTC engine. It will be used for subscribing for a track
* `output_dir_path` - output directory path i.e. where our tracks should be saved.

Putting it all together we have

```elixir
defmodule RecordingEndpoint do
  @moduledoc """
  Endpoint for saving tracks to a disk.

  Each track will be saved in a separate file.
  """
  use Membrane.Bin

  alias Membrane.RTC.Engine

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              output_dir_path: [
                spec: Path.t(),
                description: "Path to directory, where tracks will be saved."
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      output_dir_path: opts.output_dir_path,
      rtc_engine: opts.rtc_engine,
    }

    {[], state}
  end
end
```

## Consuming data

Because `Membrane.Bin`s are not capable of sending or consuming any data on their own
(they can be more thought of as logical containers) we have to add at least one
casual Membrane element that will do this for us.

In our case, we will need three elements:
* `Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver` - responsible for requesting the highest
possible track variant and switching to other variants when the currently used one becomes inactive
* [`Membrane.Stream.Serializer`](https://hexdocs.pm/membrane_stream_plugin/Membrane.Stream.Serializer.html) -
used for serializing incoming Membrane stream
* `Membrane.File.Sink` - used for saving serialized data into a file

For each incoming track we will create separate serializer and sink.

## Subscribing to a track

Whenever some endpoint publishes its tracks, all other endpoints receive a message
in form of `{:new_tracks, tracks}` where `tracks` is a list of `t:Membrane.RTC.Engine.Track.t/0`.

To subscribe to any of the published tracks, an endpoint has to call `Membrane.RTC.Engine.subscribe/4`.

After subscribing to a track, the endpoint will be notified about its readiness in
`c:Membrane.Bin.handle_pad_added/3` callback. An example implementation of `handle_pad_added`
callback can look like this

```elixir
@impl true
def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
  spec = [
    bin_input(pad)
    |> child({:track_receiver, track_id}, %TrackReceiver{
      track: Map.fetch!(state.tracks, track_id),
      initial_target_variant: :high
    })
    |> child({:serializer, track_id}, Membrane.Stream.Serializer)
    |> child({:sink, track_id}, %Membrane.File.Sink{
      location: Path.join(state.output_dir_path, track_id)
    })
  ]

  {[spec: spec], state}
end
```

We simply link our input pad on which we will receive media data to the track receiver,
serializer and then to the sink.

The endpoint will be also notified when some tracks it subscribed to are removed with
`{:removed_tracks, tracks}` message.

> #### Deeper dive into TrackReciver {: .tip}
>
> After linking the input pad for a given track, our endpoint will start receiving events.
> The very first event is always `TrackVariantResumed`. It informs that a given track
> variant is available and can be requested with the `RequestTrackVariant` event.
> The engine ensures that each endpoint always receives a track variant starting from
> a keyframe, so before receiving the first media packets our endpoint
> will receive the `TrackVariantSwitched` event and finally media packets will
> start flowing.
>
> When some track variant is paused, the endpoint will receive the `TrackVariantPaused` event.
>
> The whole process is shown in the following diagram
>
> ```ascii
> Engine ---- TrackVariantResumed (:medium) ---> Endpoint
> Engine <--- RequestTrackVariant (:medium) ---- Endpoint
> Engine ---- TrackVariantResumed (:low)    ---> Endpoint
> Engine ---- TrackVariantSwitched          ---> Endpoint
> Engine ----        media                  ---> Endpoint
> Engine ---- TrackVariantPaused  (:medium) ---> Endpoint
> Engine <--- RequestTrackVariant (:low)    ---- Endpoint
> ```
>
> Because this logic must be duplicated in each endpoint we encapsulated
> it into `TrackReceiver` that can easily be plugged in before the actual
> Membrane element.
>

Putting it all together

```elixir
defmodule RecordingEndpoint do
  @moduledoc """
  Endpoint for saving tracks to a disk.

  Each track will be saved in a separate file.
  """
  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              output_dir_path: [
                spec: Path.t(),
                description: "Path to directory, where tracks will be saved."
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      output_dir_path: opts.output_dir_path,
      rtc_engine: opts.rtc_engine,
      tracks: %{}
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    spec = [
      bin_input(pad)
      |> child({:track_receiver, track_id}, %TrackReceiver{
        track: Map.fetch!(state.tracks, track_id),
        initial_target_variant: :high
      })
      |> child({:serializer, track_id}, Membrane.Stream.Serializer)
      |> child({:sink, track_id}, %Membrane.File.Sink{
        location: Path.join(state.output_dir_path, track_id)
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, track_id), _ctx, state) do
    children = [
      {:track_receiver, track_id},
      {:serializer, track_id},
      {:sink, track_id}
    ]

    {[remove_children: children], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    Enum.reduce_while(tracks, {[], state}, fn track, {[], state} ->
      case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
        :ok ->
          {:cont, {[], update_in(state, [:tracks], &Map.put(&1, track.id, track))}}

        :ignored ->
          {:cont, {[], state}}

        {:error, reason} ->
          raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
      end
    end)
  end

  @impl true
  def handle_parent_notification({:remove_tracks, _tracks}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification(_msg, _ctx, state) do
    # ignore all other notifications
    {[], state}
  end
end
```
