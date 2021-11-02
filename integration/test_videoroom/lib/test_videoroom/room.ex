defmodule TestVideoroom.Room do
  @moduledoc false

  use GenServer

  require Logger

  def start(opts) do
    GenServer.start(__MODULE__, [], opts)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def add_peer_channel(room, peer_channel_pid, peer_id) do
    GenServer.call(room, {:add_peer_channel, peer_channel_pid, peer_id})
  end

  def register_new_peer_listener(room, listener) do
    GenServer.call(room, {:register_new_peer_listener, listener})
  end

  @impl true
  def init(opts) do
    Logger.info("Spawning room process: #{inspect(self())}")

    sfu_options = [
      id: opts[:room_id],
      network_options: [
        stun_servers: [
          %{server_addr: "stun.l.google.com", server_port: 19_302}
        ],
        turn_servers: [],
        dtls_pkey: Application.get_env(:membrane_videoroom_demo, :dtls_pkey),
        dtls_cert: Application.get_env(:membrane_videoroom_demo, :dtls_cert)
      ],
      payload_and_depayload_tracks?: false
    ]

    {:ok, pid} = Membrane.RTC.Engine.start(sfu_options, [])
    Process.monitor(pid)
    send(pid, {:register, self()})
    {:ok, %{sfu_engine: pid, peer_channels: %{}, listeners: []}}
  end

  @impl true
  def handle_call({:register_new_peer_listener, listener}, _from, state) do
    {:reply, :ok, %{state | listeners: [listener | state.listeners]}}
  end

  @impl true
  def handle_call({:add_peer_channel, peer_channel_pid, peer_id}, _from, state) do
    state = put_in(state, [:peer_channels, peer_id], peer_channel_pid)
    Process.monitor(peer_channel_pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({_sfu_engine, {:sfu_media_event, :broadcast, event}}, state) do
    for {_peer_id, pid} <- state.peer_channels, do: send(pid, {:media_event, event})
    {:noreply, state}
  end

  @impl true
  def handle_info({_sfu_engine, {:sfu_media_event, to, event}}, state) do
    if state.peer_channels[to] != nil do
      send(state.peer_channels[to], {:media_event, event})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({sfu_engine, {:new_peer, peer_id, _metadata}}, state) do
    send(sfu_engine, {:accept_new_peer, peer_id})

    for listener <- state.listeners do
      send(listener, {:room, :new_peer})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({_sfu_engine, {:peer_left, _peer_id}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _from, _event} = msg, state) do
    send(state.sfu_engine, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, sfu_pid, _reason}, %{sfu_engine: sfu_pid} = state) do
    {:stop, "sfu engine down", state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {peer_id, _peer_channel_id} =
      state.peer_channels
      |> Enum.find(fn {_peer_id, peer_channel_pid} -> peer_channel_pid == pid end)

    send(state.sfu_engine, {:remove_peer, peer_id})
    {_elem, state} = pop_in(state, [:peer_channels, peer_id])
    {:noreply, state}
  end
end
