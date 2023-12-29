defmodule Membrane.RTC.Engine.Endpoint.SIP.PortAllocator do
  @moduledoc false

  use GenServer

  require Logger

  @default_port_range {21_000, 21_100}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_port() :: {:ok, pos_integer()} | {:error, :no_available_port}
  def get_port() do
    GenServer.call(__MODULE__, :get_port)
  end

  @spec free_ports(pid()) :: :ok
  def free_ports(port_owner) do
    GenServer.cast(__MODULE__, {:free_ports, port_owner})
  end

  @impl true
  def init(_opts) do
    {from, to} = Application.get_env(:membrane_rtc_engine_sip, :port_range, @default_port_range)

    state = %{
      available: Enum.to_list(from..to),
      in_use: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_port, {pid, tag}, state) do
    {port, available} = List.pop_at(state.available, 0)

    state = %{state | available: available}

    with false <- is_nil(port),
         {:ok, socket} <- :gen_udp.open(port),
         :ok <- :gen_udp.close(socket) do
      state = %{state | in_use: Map.update(state.in_use, pid, [port], &[port | &1])}

      {:reply, {:ok, port}, state}
    else
      true ->
        {:reply, {:error, :no_available_port}, state}

      {:error, reason} ->
        Logger.warning("Opening port #{port} failed with reason: #{reason}")

        handle_call(:get_port, {pid, tag}, state)
    end
  end

  @impl true
  def handle_cast({:free_ports, pid}, state) do
    {ports, in_use} = Map.pop(state.in_use, pid, [])

    state = %{state | available: ports ++ state.available, in_use: in_use}

    {:noreply, state}
  end
end
