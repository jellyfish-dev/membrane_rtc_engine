defmodule Membrane.RTC.Engine do
  @moduledoc """
  RTC Engine implementation.

  RTC Engine is an abstraction layer responsible for linking together different types of Endpoints.
  From the implementation point of view, RTC Engine is a `Membrane.Pipeline`.

  ## Messages

  The RTC Engine works by sending messages which notify user logic about important events.
  To receive RTC Engine messages you have to register your process so that RTC Engine will
  know where to send them.
  All messages RTC Engine can emit are described in `#{inspect(__MODULE__)}.Message` docs.

  ### Registering for messages

  Registration can be done using `register/2` e.g.

  ```elixir
  Engine.register(rtc_engine, self())
  ```

  This will register your process to receive RTC Engine messages.
  You can register multiple processes to receive messages from an RTC Engine instance.
  In such a case each message will be sent to each registered process.

  ## Endpoints

  Endpoints are `Membrane.Bin`s able to publish their own tracks and subscribe to tracks from other Endpoints.
  One can think about Endpoint as an entity responsible for handling some specific task.
  An Endpoint can be added and removed using `add_endpoint/3` and `remove_endpoint/2` respectively.

  There are two types of Endpoints:
  * Standalone Endpoints - they are in most cases spawned only once per RTC Engine instance and they are not associated with any client.
  * Client Endpoints - they are associated with some client.
  Associating Endpoint with client will send some Media Events to the Endpoint's Client Library
  e.g. one which indicates which tracks belong to which client.

  Currently RTC Engine ships with the implementation of the following Endpoints:
  * `#{inspect(__MODULE__)}.Endpoint.WebRTC` which is responsible for establishing a connection with some WebRTC
  client (mainly browser) and exchanging media with it. WebRTC Endpoint is a Client Endpoint.
  * `#{inspect(__MODULE__)}.Endpoint.HLS` which is responsible for receiving media tracks from all other Endpoints and
  saving them to files by creating HLS playlists. HLS Endpoint is a Standalone Endpoint.
  * `#{inspect(__MODULE__)}.Endpoint.RTSP` which is responsible for connecting to a remote RTSP stream source and
  sending the appropriate media track to other Endpoints. RTSP Endpoint is a Standalone Endpoint.
  * `#{inspect(__MODULE__)}.Endpoint.File` which is responsible for reading track from a file, payloading it into RTP, and
  sending it to other Endpoints. File Endpoint is a Standalone Endpoint.

  Each of these endpoints is available as a separate package. Refer to the appropriate package for usage examples:
  * [`membrane_rtc_engine_webrtc`](https://hexdocs.pm/membrane_rtc_engine_webrtc/readme.html)
  * [`membrane_rtc_engine_hls`](https://hexdocs.pm/membrane_rtc_engine_hls/readme.html)
  * [`membrane_rtc_engine_rtsp`](https://hexdocs.pm/membrane_rtc_engine_rtsp/readme.html)
  * [`membrane_rtc_engine_file`](https://hexdocs.pm/membrane_rtc_engine_file/readme.html)

  User can also implement custom Endpoints, see Custom Endpoints guide.

  ### Readiness state
  Each endpoint is presumed to be initially inactive and has to declare itself ready to fully join the Engine.

  Before it does, it:
  * will not receive notifications about other endpoints and their metadata
  * will not receive information about tracks
  * will not be able to publish any tracks
  * will not be able to update their metadata

  When declaring itself as ready, the endpoint also has an opportunity to set their metadata.
  To mark the endpoint as active, it has to send the `t:ready_action_t/0`.

  **Example**
  ```elixir
  @impl true
  def handle_other({:media_event, %{type: "join", metadata: metadata}}, _context, state) do
    {{:ok, notify: {:ready, metadata}}, state}
  end

  @impl true
  def handle_other(:ready, _context, state) do
    Membrane.Logger.debug("Succesfully activated the endpoint")
    {:ok, state}
  end
  ```
  """

  use Membrane.Pipeline

  import Membrane.RTC.Utils

  require Membrane.Logger

  require Logger

  alias Membrane.RTC.Engine.{
    DisplayManager,
    Endpoint,
    FilterTee,
    Message,
    Subscription,
    Tee,
    Track
  }

  alias Membrane.RTC.Engine.Notifications.TrackNotification

  alias Membrane.RTC.Engine.Exception.{PublishTrackError, TrackReadyError}

  @registry_name Membrane.RTC.Engine.Registry.Dispatcher

  @typedoc """
  RTC Engine configuration options.

  * `id` is used by logger. If not provided it will be generated.
  * `display_manager?` - set to `true` if you want to limit number of tracks sent from `#{inspect(__MODULE__)}.Endpoint.WebRTC` to a browser.
  * `toilet_capacity` - sets capacity of buffer between engine and endpoints. Use it when you expect bursts of data for your tracks. If not provided it will be set to 200.
  """

  @type options_t() :: [
          id: String.t(),
          trace_ctx: map(),
          display_manager?: boolean(),
          toilet_capacity: pos_integer() | nil
        ]

  defmodule State do
    @moduledoc false

    use Bunch.Access

    @enforce_keys [:id, :component_path, :trace_context]
    defstruct @enforce_keys ++
                [
                  endpoints: %{},
                  pending_endpoints: %{},
                  pending_subscriptions: [],
                  subscriptions: %{},
                  display_manager: nil,
                  toilet_capacity: 200
                ]

    @type t() :: %__MODULE__{
            id: String.t(),
            component_path: String.t(),
            trace_context: map(),
            display_manager: pid() | nil,
            endpoints: %{Endpoint.id() => Endpoint.t()},
            pending_endpoints: %{Endpoint.id() => Endpoint.t()},
            subscriptions: %{Endpoint.id() => %{Track.id() => Subscription.t()}},
            pending_subscriptions: [Subscription.t()],
            toilet_capacity: pos_integer()
          }
  end

  @typedoc """
  Endpoint configuration options.

  * `id` - assigned endpoint id. If not provided it will be generated by RTC Engine.
  * `node` - node on which endpoint should be spawned. If not provided, current node is used.
  """
  @type endpoint_options_t() :: [
          id: String.t(),
          node: node()
        ]

  @typedoc """
  Subscription options.
  """
  @type subscription_opts_t() :: Keyword.t()

  @typedoc """
  Membrane action that will cause RTC Engine to publish some message to all other endpoints.
  """
  @type publish_action_t() :: {:notify_parent, {:publish, publish_message_t()}}

  @typedoc """
  Membrane action that will mark the endpoint as ready and set its metadata.
  The Engine will respond with `t:ready_ack_msg_t/0` to acknowledge your transition to ready state.

  This action can only be used once, any further calls by an endpoint will be ignored.
  """
  @type ready_action_t() :: {:notify_parent, :ready | {:ready, metadata :: any()}}

  @typedoc """
  Membrane action that informs engine that endpoint finished processing and should be removed.
  """
  @type finished_action_t() :: {:notify_parent, :finished}

  @typedoc """
  A message that the Engine sends to the endpoint when it ackowledges its `t:ready_action_t/0`
  """
  @type ready_ack_msg_t() :: {:ready, other_endpoints :: [Endpoint.t()]}

  @typedoc """
  Membrane action that will cause RTC Engine to forward supplied message to the business logic.
  """
  @type forward_to_parent_action_t() :: {:notify_parent, {:forward_to_parent, message :: any()}}

  @typedoc """
  Membrane action that will inform RTC Engine about track readiness.
  """
  @type track_ready_action_t() ::
          {:notify_parent, {:track_ready, Track.id(), Track.variant(), Track.encoding()}}

  @typedoc """
  Types of messages that can be published to other Endpoints.
  """
  @type publish_message_t() ::
          {:new_tracks, [Track.t()]}
          | {:removed_tracks, [Track.t()]}
          | {:track_metadata_updated, metadata :: any()}
          | {:endpoint_metadata_updated, metadata :: any()}
          | {:tracks_priority, tracks :: list()}
          | TrackNotification.t()

  @typedoc """
  Type of messages that need to be handled by each endpoint.
  """
  @type published_message_t() ::
          {:new_tracks, [Track.t()]}
          | {:removed_tracks, [Track.t()]}
          | {:new_endpoint, Endpoint.t()}
          | {:endpoint_removed, Endpoint.id()}
          | {:track_metadata_updated, Track.t()}
          | {:endpoint_metadata_updated, Endpoint.t()}
          | {:tracks_priority, tracks :: list()}
          | ready_ack_msg_t()
          | TrackNotification.t()

  @spec start(options :: options_t(), process_options :: GenServer.options()) ::
          GenServer.on_start()
  def start(options, process_options) do
    do_start(:start, options, process_options)
  end

  @spec start_link(options :: options_t(), process_options :: GenServer.options()) ::
          GenServer.on_start()
  def start_link(options, process_options) do
    do_start(:start_link, options, process_options)
  end

  @doc """
  Terminates the engine.

  Accepts three options:
    * `asynchronous?` - if set to `true`, pipline termination won't be blocking and
      will be executed in the process, which pid is returned as function result. If
      set to `false`, engine termination will be blocking and will be executed in
      the process that called this function. Defaults to `false`.
    * `timeout` - tells how much time (ms) to wait for engine to get gracefully
      terminated. Defaults to 5000.
    * `force?` - if set to `true` and engine is still alive after `timeout`,
      engine will be killed using `Process.exit/2` with reason `:kill`, and function
      will return `{:error, :timeout}`. If set to `false` and engine is still alive
      after `timeout`, function will raise an error. Defaults to `false`.

  Returns:
    * `{:ok, pid}` - if option `asynchronous?: true` was passed.
    * `:ok` - if engine was gracefully terminated within `timeout`.
    * `{:error, :timeout}` - if engine was killed after a `timeout`.
  """
  @spec terminate(pid,
          timeout: timeout(),
          force?: boolean(),
          asynchronous?: boolean()
        ) :: :ok | {:ok, pid()} | {:error, :timeout}
  def terminate(engine, opts \\ []) do
    Membrane.Pipeline.terminate(engine, opts)
  end

  defp do_start(func, options, process_options) when func in [:start, :start_link] do
    id = options[:id] || "#{UUID.uuid4()}"
    display_manager? = options[:display_manager?] || false
    options = Keyword.put(options, :id, id)
    options = Keyword.put(options, :display_manager?, display_manager?)
    Membrane.Logger.info("Starting a new RTC Engine instance with id: #{id}")

    with {:ok, _supervisor, pipeline} <-
           apply(Membrane.Pipeline, func, [__MODULE__, options, process_options]) do
      {:ok, pipeline}
    end
  end

  @spec get_registry_name() :: atom()
  def get_registry_name(), do: @registry_name

  @doc """
  Adds endpoint to the RTC Engine

  For more information refer to `t:endpoint_options_t/0`.
  """
  @spec add_endpoint(
          pid :: pid(),
          endpoint :: Membrane.ChildrenSpec.child_definition(),
          opts :: endpoint_options_t()
        ) :: :ok | :error
  def add_endpoint(pid, endpoint, opts \\ []) do
    send(pid, {:add_endpoint, endpoint, opts})
    :ok
  end

  @doc """
  Removes endpoint from the RTC Engine
  """
  @spec remove_endpoint(
          pid :: pid(),
          id :: String.t()
        ) :: :ok
  def remove_endpoint(rtc_engine, id) do
    send(rtc_engine, {:remove_endpoint, id})
    :ok
  end

  @doc """
  Registers process with pid `who` for receiving messages from RTC Engine
  """
  @spec register(rtc_engine :: pid(), who :: pid()) :: :ok
  def register(rtc_engine, who \\ self()) do
    send(rtc_engine, {:register, who})
    :ok
  end

  @doc """
  Unregisters process with pid `who` from receiving messages from RTC Engine
  """
  @spec unregister(rtc_engine :: pid(), who :: pid()) :: :ok
  def unregister(rtc_engine, who \\ self()) do
    send(rtc_engine, {:unregister, who})
    :ok
  end

  @doc """
  Sends message to RTC Engine endpoint.
  If endpoint doesn't exist message is ignored
  """
  @spec message_endpoint(rtc_engine :: pid(), endpoint_id :: String.t(), message :: any()) ::
          :ok
  def message_endpoint(rtc_engine, endpoint_id, message) do
    send(rtc_engine, {:message_endpoint, {:endpoint, endpoint_id}, message})
    :ok
  end

  @doc """
  Returns list of the RTC Engine's endpoints.
  """
  @spec get_endpoints(rtc_engine :: pid()) :: [%{id: String.t(), type: atom()}]
  def get_endpoints(rtc_engine) do
    Pipeline.call(rtc_engine, :get_endpoints)
  end

  @doc """
  Returns list of the RTC Engine's tracks.
  """
  @spec get_tracks(rtc_engine :: pid()) :: [Track.t()]
  def get_tracks(rtc_engine) do
    Pipeline.call(rtc_engine, :get_tracks)
  end

  @doc """
  Returns number of forwarded tracks in RTC Engine.

  It is number of active and pending subscriptions.
  """
  @spec get_num_forwarded_tracks(rtc_engine :: pid()) :: integer()
  def get_num_forwarded_tracks(rtc_engine) do
    Pipeline.call(rtc_engine, :get_num_forwarded_tracks)
  end

  @doc """
  Subscribes an endpoint for a track.

  The endpoint will be notified about track readiness in `c:Membrane.Bin.handle_pad_added/3` callback.
  `endpoint_id` is the id of the endpoint, which wants to subscribe to the track.
  """
  @spec subscribe(
          rtc_engine :: pid(),
          endpoint_id :: String.t(),
          track_id :: Track.id(),
          opts :: subscription_opts_t
        ) :: :ok | {:error, :timeout | :invalid_track_id}
  def subscribe(rtc_engine, endpoint_id, track_id, opts \\ []) do
    ref = make_ref()
    send(rtc_engine, {:subscribe, {self(), ref}, endpoint_id, track_id, opts})

    receive do
      {^ref, :ok} -> :ok
      {^ref, {:error, reason}} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @impl true
  def handle_init(_ctx, options) do
    Logger.metadata(rtc_engine: options[:id])

    display_manager =
      if options[:display_manager?] do
        {:ok, pid} = DisplayManager.start_link(ets_name: options[:id], engine: self())
        pid
      else
        nil
      end

    toilet_capacity = options[:toilet_capacity] || 200
    if toilet_capacity < 0, do: raise("toilet_capacity has to be a positive integer")

    {[],
     %State{
       id: options[:id],
       component_path: Membrane.ComponentPath.get_formatted(),
       trace_context: options[:trace_ctx],
       display_manager: display_manager,
       toilet_capacity: toilet_capacity
     }}
  end

  @impl true
  def handle_terminate_request(ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.endpoints, state, fn {endpoint_id, _endpoint}, state ->
        {_status, actions, state} = handle_remove_endpoint(endpoint_id, ctx, state)
        {actions, state}
      end)

    {actions ++ [terminate: :normal], state}
  end

  @impl true
  def handle_info({:add_endpoint, endpoint, opts}, _ctx, state) do
    endpoint_id = opts[:id] || UUID.uuid4()
    opts = Keyword.put(opts, :id, endpoint_id)

    if Map.has_key?(state.endpoints, endpoint_id) do
      Membrane.Logger.warning(
        "Cannot add Endpoint with id #{inspect(endpoint_id)} as it already exists"
      )

      {[], state}
    else
      handle_add_endpoint(endpoint, opts, state)
    end
  end

  @impl true
  def handle_info({:remove_endpoint, id}, ctx, state) do
    case handle_remove_endpoint(id, ctx, state) do
      {:absent, [], state} ->
        Membrane.Logger.info("Endpoint #{inspect(id)} already removed")
        {[], state}

      {{:present, endpoint}, actions, state} ->
        dispatch(%Message.EndpointRemoved{endpoint_id: id, endpoint_type: endpoint.type})
        {actions, state}
    end
  end

  @impl true
  def handle_info({:register, pid}, _ctx, state) do
    Registry.register(get_registry_name(), self(), pid)
    {[], state}
  end

  @impl true
  def handle_info({:unregister, pid}, _ctx, state) do
    Registry.unregister_match(get_registry_name(), self(), pid)
    {[], state}
  end

  @impl true
  def handle_info(
        {:subscribe, {endpoint_pid, ref}, endpoint_id, track_id, opts},
        ctx,
        state
      ) do
    subscription = %Subscription{
      endpoint_id: endpoint_id,
      track_id: track_id,
      opts: opts
    }

    case validate_subscription(subscription, state) do
      :ok ->
        {spec, state} = fulfill_or_postpone_subscription(subscription, ctx, state)
        send(endpoint_pid, {ref, :ok})
        {[spec: {spec, log_metadata: [rtc: state.id]}], state}

      {:error, _reason} = error ->
        send(endpoint_pid, {ref, error})
        {[], state}
    end
  end

  @impl true
  def handle_info({:track_priorities, endpoint_to_tracks}, ctx, state) do
    endpoint_msg_actions =
      for {endpoint, tracks} <- endpoint_to_tracks do
        {:notify_child, {endpoint, {:tracks_priority, tracks}}}
      end

    tee_actions =
      ctx
      |> filter_children(pattern: {:tee, _tee_name})
      |> Enum.flat_map(&[notify_child: {&1, :track_priorities_updated}])

    {endpoint_msg_actions ++ tee_actions, state}
  end

  @impl true
  def handle_info({:message_endpoint, endpoint, message}, ctx, state) do
    actions =
      if find_child(ctx, pattern: ^endpoint) != nil,
        do: [notify_child: {endpoint, message}],
        else: []

    {actions, state}
  end

  @impl true
  def handle_call(:get_endpoints, ctx, state) do
    endpoints =
      ctx.children
      |> Map.values()
      |> Enum.filter(fn child -> match?({:endpoint, _id}, child.name) end)
      |> Enum.map(fn endpoint ->
        {:endpoint, id} = endpoint.name
        %{id: id, type: endpoint.module}
      end)

    {[reply: endpoints], state}
  end

  @impl true
  def handle_call(:get_num_forwarded_tracks, _ctx, state) do
    forwarded_tracks = Map.values(state.subscriptions) |> Enum.flat_map(& &1) |> Enum.count()
    pending_forwarded_tracks = Enum.count(state.pending_subscriptions)
    {[reply: forwarded_tracks + pending_forwarded_tracks], state}
  end

  @impl true
  def handle_call(:get_tracks, _ctx, state) do
    tracks =
      state.endpoints
      |> Map.values()
      |> Enum.flat_map(&Endpoint.get_tracks/1)

    {[reply: tracks], state}
  end

  @impl true
  def handle_child_notification(
        notification,
        {:endpoint, endpoint_id},
        ctx,
        %{endpoints: endpoints, pending_endpoints: pending_endpoints} = state
      ) do
    handle_notification? =
      Map.has_key?(endpoints, endpoint_id) or
        (Map.has_key?(pending_endpoints, endpoint_id) and
           endpoint_ready_notification?(notification))

    if handle_notification? do
      handle_endpoint_notification(notification, endpoint_id, ctx, state)
    else
      Membrane.Logger.warning(
        "Ignoring notification: #{inspect(notification)}, endpoint: #{endpoint_id} is not ready"
      )

      {[], state}
    end
  end

  @impl true
  def handle_crash_group_down(endpoint_id, ctx, state) do
    {{:present, endpoint}, actions, state} = handle_remove_endpoint(endpoint_id, ctx, state)
    dispatch(%Message.EndpointCrashed{endpoint_id: endpoint_id, endpoint_type: endpoint.type})
    {actions, state}
  end

  @impl true
  def handle_child_pad_removed(_child, _pad, _ctx, state) do
    {[], state}
  end

  #
  # Endpoint Notifications
  #
  # - handle_endpoint_notification/4: Handles incoming notifications from an Endpoint, usually
  #   the WebRTC endpoint. Handles track_ready, publication of new tracks, and publication of
  #   removed tracks. Also forwards custom media events.
  #

  defp handle_endpoint_notification(:finished, endpoint_id, ctx, state) do
    {{:present, endpoint}, actions, new_state} = handle_remove_endpoint(endpoint_id, ctx, state)
    dispatch(%Message.EndpointRemoved{endpoint_id: endpoint_id, endpoint_type: endpoint.type})

    Membrane.Logger.info("Endpoint #{endpoint_id} removed after processing finished")

    {actions, new_state}
  end

  defp handle_endpoint_notification(:ready, endpoint_id, ctx, state) do
    handle_endpoint_notification({:ready, nil}, endpoint_id, ctx, state)
  end

  defp handle_endpoint_notification({:ready, metadata}, endpoint_id, _ctx, state) do
    if Map.has_key?(state.pending_endpoints, endpoint_id) do
      {new_endpoint, state} = pop_in(state, [:pending_endpoints, endpoint_id])
      new_endpoint = %{new_endpoint | metadata: metadata}

      other_endpoints = Map.values(state.endpoints)

      new_endpoint_notifications =
        state.endpoints
        |> Map.keys()
        |> Enum.map(&{:notify_child, {{:endpoint, &1}, {:new_endpoint, new_endpoint}}})

      active_tracks = get_active_tracks(state.endpoints)

      new_tracks_notification =
        if active_tracks == [] do
          []
        else
          [notify_child: {{:endpoint, endpoint_id}, {:new_tracks, active_tracks}}]
        end

      actions =
        [
          notify_child: {{:endpoint, endpoint_id}, {:ready, other_endpoints}}
        ] ++ new_tracks_notification ++ new_endpoint_notifications

      state =
        state
        |> put_in([:endpoints, endpoint_id], new_endpoint)
        |> put_in([:subscriptions, endpoint_id], %{})

      {actions, state}
    else
      Membrane.Logger.warning(
        "Endpoint #{endpoint_id} sent a `:ready` message even though it has been already accepted. Ignoring."
      )

      {[], state}
    end
  end

  defp handle_endpoint_notification({:forward_to_parent, message}, endpoint_id, _ctx, state) do
    endpoint =
      Map.get(state.endpoints, endpoint_id) || Map.fetch!(state.pending_endpoints, endpoint_id)

    dispatch(%Message.EndpointMessage{
      endpoint_id: endpoint_id,
      endpoint_type: endpoint.type,
      message: message
    })

    {[], state}
  end

  defp handle_endpoint_notification(
         {:update_endpoint_metadata, metadata},
         endpoint_id,
         _ctx,
         state
       ) do
    endpoint = Map.get(state.endpoints, endpoint_id)

    if endpoint.metadata != metadata do
      updated_endpoint = %{endpoint | metadata: metadata}
      state = put_in(state, [:endpoints, endpoint_id], updated_endpoint)

      actions =
        state.endpoints
        |> Map.keys()
        |> Enum.map(
          &{:notify_child, {{:endpoint, &1}, {:endpoint_metadata_updated, updated_endpoint}}}
        )

      {actions, state}
    else
      {[], state}
    end
  end

  defp handle_endpoint_notification(
         {:update_track_metadata, track_id, track_metadata},
         endpoint_id,
         _ctx,
         state
       ) do
    if Map.has_key?(state.endpoints, endpoint_id) do
      endpoint = Map.get(state.endpoints, endpoint_id)
      track = Endpoint.get_track_by_id(endpoint, track_id)

      if track != nil and track.metadata != track_metadata do
        endpoint = Endpoint.update_track_metadata(endpoint, track_id, track_metadata)
        state = put_in(state, [:endpoints, endpoint_id], endpoint)

        actions =
          state.subscriptions
          |> Map.values()
          |> Enum.flat_map(&Map.values/1)
          |> then(&(&1 ++ state.pending_subscriptions))
          |> Enum.filter(&(&1.track_id == track_id))
          |> Enum.map(& &1.endpoint_id)
          |> Enum.map(
            &{:notify_child,
             {{:endpoint, &1},
              {:track_metadata_updated, Endpoint.get_track_by_id(endpoint, track_id)}}}
          )

        {actions, state}
      else
        {[], state}
      end
    else
      {[], state}
    end
  end

  defp handle_endpoint_notification(
         {:publish, %TrackNotification{track_id: track_id} = notification},
         endpoint_id,
         _ctx,
         state
       ) do
    subscribed_endpoints =
      state.subscriptions
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.filter(&(&1.track_id == track_id))
      |> Enum.map(& &1.endpoint_id)

    message_actions =
      Enum.map(subscribed_endpoints, &{:notify_child, {{:endpoint, &1}, notification}})

    if Map.has_key?(state.endpoints[endpoint_id].inbound_tracks, track_id) do
      {message_actions, state}
    else
      Membrane.Logger.error("""
      Non-owner attempted to send a notification about the track. It is being ignored.
      Offending endpoint: #{inspect(endpoint_id)}
      TrackId: #{track_id}
      notification: #{inspect(notification)}
      """)
    end
  end

  defp handle_endpoint_notification(
         {:track_ready, track_id, variant, encoding},
         endpoint_id,
         _ctx,
         state
       ) do
    Membrane.Logger.info(
      "New incoming #{encoding} track #{track_id} (variant: #{variant}) from endpoint #{inspect(endpoint_id)}"
    )

    track = get_in(state, [:endpoints, endpoint_id]) |> Endpoint.get_track_by_id(track_id)

    if variant not in track.variants do
      raise TrackReadyError, track: track, variant: variant
    end

    track_link = build_track_link(variant, track, endpoint_id, state)

    # check if there are subscriptions for this track and fulfill them
    {subscriptions, pending_subscriptions} =
      Enum.split_with(state.pending_subscriptions, &(&1.track_id == track_id))

    {subscription_links, state} = fulfill_subscriptions(subscriptions, state)

    links = [track_link] ++ subscription_links
    state = %{state | pending_subscriptions: pending_subscriptions}

    state =
      update_in(
        state,
        [:endpoints, endpoint_id],
        &Endpoint.update_track_encoding(&1, track_id, encoding)
      )

    spec =
      {links,
       group: endpoint_id, crash_group_mode: :temporary, log_metadata: [rtc_engine: state.id]}

    {[spec: spec], state}
  end

  defp handle_endpoint_notification(
         {:publish, {:new_tracks, tracks}},
         endpoint_id,
         _ctx,
         state
       ) do
    Enum.each(tracks, &validate_track(&1))

    id_to_track = Map.new(tracks, &{&1.id, &1})

    state =
      update_in(
        state,
        [:endpoints, endpoint_id, :inbound_tracks],
        &Map.merge(&1, id_to_track)
      )

    Enum.each(
      tracks,
      &dispatch(%Message.TrackAdded{
        endpoint_id: endpoint_id,
        endpoint_type: state.endpoints[endpoint_id].type,
        track_id: &1.id,
        track_type: &1.type,
        track_encoding: &1.encoding
      })
    )

    tracks_msgs = build_track_added_actions(tracks, endpoint_id, state)
    {tracks_msgs, state}
  end

  defp handle_endpoint_notification(
         {:publish, {:removed_tracks, tracks}},
         endpoint_id,
         ctx,
         state
       ) do
    id_to_track = Map.new(tracks, &{&1.id, &1})

    state =
      update_in(
        state,
        [:endpoints, endpoint_id, :inbound_tracks],
        &Map.merge(&1, id_to_track)
      )

    tracks_msgs = build_track_removed_actions(tracks, endpoint_id, state)
    track_ids = Enum.map(tracks, & &1.id)
    track_tees = tracks |> Enum.map(&get_track_tee(&1.id, ctx)) |> Enum.reject(&is_nil(&1))

    subscriptions =
      Map.new(state.subscriptions, fn {endpoint_id, subscriptions} ->
        subscriptions =
          subscriptions
          |> Enum.reject(fn {track_id, _data} -> Enum.member?(track_ids, track_id) end)
          |> Map.new()

        {endpoint_id, subscriptions}
      end)

    Enum.each(
      tracks,
      &dispatch(%Message.TrackRemoved{
        endpoint_id: endpoint_id,
        endpoint_type: state.endpoints[endpoint_id].type,
        track_id: &1.id,
        track_type: &1.type,
        track_encoding: &1.encoding
      })
    )

    {tracks_msgs ++ [remove_children: track_tees], %{state | subscriptions: subscriptions}}
  end

  defp validate_track(track) do
    variants = MapSet.new(track.variants)
    supported_variants = Track.supported_variants() |> MapSet.new()

    cond do
      variants == MapSet.new([]) ->
        raise PublishTrackError, track: track

      track.type == :audio and not MapSet.equal?(variants, MapSet.new([:high])) ->
        raise PublishTrackError, track: track

      MapSet.subset?(variants, supported_variants) == false ->
        raise PublishTrackError, track: track

      true ->
        :ok
    end
  end

  #
  # Endpoint Management
  #
  # - handle_add_endpoint/3: Adds a new Endpoint based on the entry provided. Part of the
  #   implementation for the public API.
  #
  # - handle_remove_endpoint/3: Removes the given Endpoint. Part of the implementation for the
  #   public API.
  #
  # - get_active_tracks/1: Helper function for add_endpoint/3. Returns a list of Tracks that can
  #   be provided to the newly added Endpoint straight away.
  #
  # - find_children_for_endpoint/2: Convenience function to identify all Elements owned by an
  #   Endpoint, via its Tracks.
  #
  # - get_track_tee/2: Convenience function to get tee for given track
  #

  defp handle_add_endpoint(endpoint_entry, opts, state) do
    if Keyword.has_key?(opts, :endpoint_id) or Keyword.has_key?(opts, :peer_id) do
      raise("`:endpoint_id` and `:peer_id` options were removed. Use `:id` option instead.")
    end

    endpoint_id = Keyword.fetch!(opts, :id)
    endpoint_name = {:endpoint, endpoint_id}
    %endpoint_module{} = endpoint_entry

    spec = {
      child(endpoint_name, endpoint_entry),
      node: opts[:node],
      group: endpoint_id,
      crash_group_mode: :temporary,
      log_metadata: [rtc_engine: state.id]
    }

    display_manager_message =
      if state.display_manager != nil,
        do: [notify_child: {endpoint_name, {:display_manager, state.display_manager}}],
        else: []

    actions = [spec: spec] ++ display_manager_message

    endpoint = Endpoint.new(endpoint_id, endpoint_module, [])

    state =
      state
      |> put_in([:subscriptions, endpoint_id], %{})
      |> put_in([:pending_endpoints, endpoint_id], endpoint)

    dispatch(%Message.EndpointAdded{endpoint_id: endpoint_id, endpoint_type: endpoint_module})
    {actions, state}
  end

  defp handle_remove_endpoint(endpoint_id, ctx, state) do
    cond do
      Map.has_key?(state.endpoints, endpoint_id) ->
        pending_subscriptions_fun = fn subscriptions ->
          Enum.filter(subscriptions, &(&1.endpoint_id != endpoint_id))
        end

        {endpoint, state} = pop_in(state, [:endpoints, endpoint_id])
        {_, state} = pop_in(state, [:subscriptions, endpoint_id])
        state = update_in(state, [:pending_subscriptions], pending_subscriptions_fun)

        tracks = Enum.map(Endpoint.get_tracks(endpoint), &%Track{&1 | active?: true})
        tracks_msgs = build_track_removed_actions(tracks, endpoint_id, state)
        endpoint_bin = ctx.children[{:endpoint, endpoint_id}]

        endpoint_removed_msgs =
          state.endpoints
          |> Map.keys()
          |> Enum.map(&{:notify_child, {{:endpoint, &1}, {:endpoint_removed, endpoint_id}}})

        if endpoint_bin == nil or endpoint_bin.terminating? do
          {{:present, endpoint}, tracks_msgs ++ endpoint_removed_msgs, state}
        else
          actions = [remove_children: find_children_for_endpoint(endpoint, ctx)]
          {{:present, endpoint}, tracks_msgs ++ endpoint_removed_msgs ++ actions, state}
        end

      Map.has_key?(state.pending_endpoints, endpoint_id) ->
        {pending_endpoint, state} = pop_in(state, [:pending_endpoints, endpoint_id])
        endpoint_bin = ctx.children[{:endpoint, endpoint_id}]

        if endpoint_bin == nil or endpoint_bin.terminating? do
          {{:present, pending_endpoint}, [], state}
        else
          {{:present, pending_endpoint}, [remove_children: {:endpoint, endpoint_id}], state}
        end

      true ->
        {:absent, [], state}
    end
  end

  defp get_active_tracks(endpoints) do
    endpoints
    |> Map.values()
    |> Enum.flat_map(&Endpoint.get_tracks/1)
    |> Enum.filter(& &1.active?)
  end

  defp find_children_for_endpoint(endpoint, ctx) do
    children =
      endpoint
      |> Endpoint.get_tracks()
      |> Enum.map(&get_track_tee(&1.id, ctx))
      |> Enum.reject(&is_nil(&1))

    [endpoint: endpoint.id] ++ children
  end

  defp get_track_tee(track_id, ctx) do
    if Map.has_key?(ctx.children, {:tee, track_id}) do
      {:tee, track_id}
    end
  end

  #
  # Track Actions
  #
  # - build_track_added_actions/3: Called when new tracks were published by the WebRTC endpoint
  #   and the Engine has been notified. Notifies all other Endpoints of the new tracks.
  #
  # - build_track_removed_actions/3: Called when the underlying endpoint was removed (either
  #   normally, or due to crash).
  #

  defp build_track_added_actions(tracks, endpoint_id, state) do
    state.endpoints
    |> Map.delete(endpoint_id)
    |> Map.keys()
    |> Enum.flat_map(fn endpoint_id ->
      [notify_child: {{:endpoint, endpoint_id}, {:new_tracks, tracks}}]
    end)
  end

  defp build_track_removed_actions(tracks, from_endpoint_id, state) do
    state.endpoints
    |> Stream.reject(&(elem(&1, 0) == from_endpoint_id))
    |> Stream.reject(&is_nil(elem(&1, 1)))
    |> Enum.flat_map(fn {endpoint_id, _endpoint} ->
      subscriptions = state.subscriptions[endpoint_id]
      tracks = Enum.filter(tracks, &Map.has_key?(subscriptions, &1.id))
      [notify_child: {{:endpoint, endpoint_id}, {:remove_tracks, tracks}}]
    end)
  end

  #
  # Track Links
  #
  # - build_track_link/4 - called when the track is ready, via notification from the WebRTC
  #   endpoint. Creates the link from the endpoint which published the track, and starts the
  #   underlying tee which is required to bring the content of the track to all subscribers.
  #
  # - build_track_tee/4 - Called by build_track_link/4; builds the correct tee depending on
  #   display manager is turned on or off
  #

  defp build_track_link(variant, track, endpoint_id, state) do
    get_child({:endpoint, endpoint_id})
    |> via_out(Pad.ref(:output, {track.id, variant}))
    |> via_in(Pad.ref(:input, {track.id, variant}),
      toilet_capacity: state.toilet_capacity
    )
    |> child({:tee, track.id}, build_track_tee(track.id, variant, track, state),
      get_if_exists: true
    )
  end

  defp build_track_tee(track_id, _variant, track, %{display_manager: dm} = state)
       when dm != nil do
    %FilterTee{
      ets_name: state.id,
      track_id: track_id,
      type: track.type,
      codec: track.encoding
    }
  end

  defp build_track_tee(_track_id, _variant, track, _state) do
    %Tee{track: track}
  end

  #
  # Track Subscriptions
  #
  # - validate_subscription/2: Validates proposed subscription, called when a new subscription
  #   is to be added, via handle_info.
  #
  # - fulfill_or_postpone_subscription/3: Called immediately upon validation of subscription,
  #   optimistically links track's tee to the subscriber if the track is ready, otherwise adds the
  #   subscription to the list of pending subscriptions
  #
  # - fulfill_subscriptions/2: Called when a new track is ready and there are pending
  #   subscriptions to the track.
  #
  # - build_subscription_links/1, build_subscription_link/1: Called by fulfill_subscriptions/2,
  #   these functions build the actual links between the tee and the endpoint subscribing for the given track.
  #
  # - get_track/2: Convenience function. Searches for a Track with the given Track ID which is
  #   owned by one of the Endpoints in the list.
  #

  defp validate_subscription(subscription, state) do
    # checks whether subscription is correct
    track = get_track(subscription.track_id, state.endpoints)

    if track, do: :ok, else: {:error, :invalid_track_id}
  end

  defp fulfill_or_postpone_subscription(subscription, ctx, state) do
    # If the tee for this track is already spawned, fulfill subscription.
    # Otherwise, save subscription as pending, we will fulfill it when the tee is linked.

    if Map.has_key?(ctx.children, {:tee, subscription.track_id}) do
      fulfill_subscriptions([subscription], state)
    else
      state = update_in(state, [:pending_subscriptions], &[subscription | &1])
      {[], state}
    end
  end

  defp fulfill_subscriptions(subscriptions, state) do
    links = build_subscription_links(subscriptions, state)

    Enum.reduce(subscriptions, {links, state}, fn subscription, {links, state} ->
      endpoint_id = subscription.endpoint_id
      track_id = subscription.track_id
      subscription = %{subscription | status: :active}
      state = put_in(state, [:subscriptions, endpoint_id, track_id], subscription)
      {links, state}
    end)
  end

  defp build_subscription_links(subscriptions, state) do
    Enum.map(subscriptions, &build_subscription_link(&1, state))
  end

  defp build_subscription_link(subscription, state) do
    get_child({:tee, subscription.track_id})
    |> via_out(Pad.ref(:output, {:endpoint, subscription.endpoint_id}))
    |> via_in(Pad.ref(:input, subscription.track_id),
      toilet_capacity: state.toilet_capacity
    )
    |> get_child({:endpoint, subscription.endpoint_id})
  end

  defp get_track(track_id, endpoints) do
    endpoints
    |> Map.values()
    |> Enum.flat_map(&Endpoint.get_tracks/1)
    |> Map.new(&{&1.id, &1})
    |> Map.get(track_id)
  end

  #
  # Message Dispatch
  #
  # - dispatch/1: Internal function, dispatches the message to all registered processes within the
  #   registry
  #
  # - dispatch/2: Dispatches the Media Event to all registered processes within the registry, with
  #   the correct `to` field populated
  #
  # - brodcast/1: Convenience function, dispatches the data within a Media Event and sets the `to`
  #   field to `:broadcast`.
  #

  defp dispatch(message) do
    Registry.dispatch(get_registry_name(), self(), fn entries ->
      for {_, pid} <- entries, do: send(pid, message)
    end)
  end

  defp endpoint_ready_notification?(:ready), do: true
  defp endpoint_ready_notification?({:ready, _metadata}), do: true
  defp endpoint_ready_notification?(_notification), do: false
end
