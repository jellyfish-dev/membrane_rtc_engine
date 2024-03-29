defmodule Membrane.RTC.Engine.Subscriptions.State do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Track
  alias Membrane.RTC.Engine.Subscriptions.{Automatic, Manual}

  @behaviour __MODULE__

  @type tracks_t :: %{Track.id() => Track.t()}

  @type subscribe_result :: {[Track.t()], t()}

  @typedoc """
  * `endpoint_id` - id of endpoint
  * `rtc_engine` - pid of engine pipeline
  * `subscribe_mode` - mode of subscription. In `:auto` mode endpoint will
  try to subscribe on any available track. In `:manual` mode endpoint will
  subscribe only on tracks from endpoints that were previously added to state.
  * `tracks` - map of tracks on which that endpoint subscribed
  * `endpoints` - set of endpoints, endpoint will try to subscribe on tracks of these endpoints.
  Used only in `:manual` mode.
  """
  @type t() :: %__MODULE__{
          endpoint_id: Endpoint.id(),
          rtc_engine: pid(),
          subscribe_mode: :auto | :manual,
          tracks: tracks_t(),
          endpoints: MapSet.t()
        }

  @enforce_keys [:subscribe_mode, :rtc_engine, :endpoint_id]
  defstruct @enforce_keys ++ [tracks: %{}, endpoints: MapSet.new()]

  @doc """
  Callback invoked when a new tracks are added by engine.
  It should return an updated struct and it will try to subscribe on valid tracks.
  """
  @callback handle_new_tracks(tracks :: [Track.t()], subscriptions_state :: t()) :: t()

  @doc """
  Callback invoked when endpoint decided that it want to subscribe on specific endpoints.
  It should return an updated struct and it will try to subscribe on any tracks from these endpoints.
  This function is useless in `:auto` subscribe_mode.
  """
  @callback add_endpoints(endpoints :: [Endpoint.id()], subscriptions_state :: t()) :: t()

  @spec subscribe_for_tracks([Track.t()], Endpoint.id(), pid()) :: {[Track.t()], t()}
  def subscribe_for_tracks(tracks, endpoint_id, rtc_engine) do
    {valid_tracks, invalid_tracks} =
      Enum.split_with(tracks, fn track ->
        case Engine.subscribe(rtc_engine, endpoint_id, track.id) do
          :ok ->
            true

          {:error, :invalid_track_id} ->
            Membrane.Logger.debug(
              "Couldn't subscribe to the track: #{inspect(track.id)}. No such track."
            )

            false

          {:error, reason} ->
            raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
        end
      end)

    unless Enum.empty?(invalid_tracks) do
      msg = invalid_tracks |> Enum.map(& &1.id) |> Enum.join("")
      Membrane.Logger.debug("Invalid tracks are: #{msg}")
    end

    valid_tracks
  end

  @spec update_tracks(t(), [Track.t()]) :: t()
  def update_tracks(state, tracks) do
    tracks = Map.new(tracks, &{&1.id, &1})
    Map.update!(state, :tracks, &Map.merge(&1, tracks))
  end

  @spec update_endpoints(t(), [Endpoint.id()]) :: t()
  def update_endpoints(state, endpoints) do
    endpoints = MapSet.new(endpoints)
    Map.update!(state, :endpoints, &MapSet.union(&1, endpoints))
  end

  @spec pop_track!(t(), Track.id()) :: {Track.id(), t()}
  def pop_track!(state, track_id) do
    {removed_track, tracks} = Map.pop!(state.tracks, track_id)

    {removed_track, %{state | tracks: tracks}}
  end

  @impl true
  def handle_new_tracks(tracks, %{subscribe_mode: :auto} = subscriptions_state) do
    Automatic.handle_new_tracks(tracks, subscriptions_state)
  end

  @impl true
  def handle_new_tracks(tracks, %{subscribe_mode: :manual} = subscriptions_state) do
    Manual.handle_new_tracks(tracks, subscriptions_state)
  end

  @impl true
  def add_endpoints(endpoints, %{subscribe_mode: :auto} = subscriptions_state) do
    Automatic.add_endpoints(endpoints, subscriptions_state)
  end

  @impl true
  def add_endpoints(endpoints, %{subscribe_mode: :manual} = subscriptions_state) do
    Manual.add_endpoints(endpoints, subscriptions_state)
  end
end
