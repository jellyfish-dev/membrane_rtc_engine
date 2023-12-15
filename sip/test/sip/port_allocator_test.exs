defmodule Membrane.RTC.PortAllocatorTest do
  use ExUnit.Case, async: false

  alias Membrane.RTC.Engine.Endpoint.SIP.PortAllocator

  test "handles port allocation, reuses freed ports" do
    restart_port_allocator()

    task =
      Task.async(fn ->
        {:ok, port} = PortAllocator.get_port()
        {self(), port}
      end)

    {someone_else, their_port} = Task.await(task)
    {:ok, my_port1} = PortAllocator.get_port()
    assert my_port1 != their_port

    :ok = PortAllocator.free_ports(someone_else)
    {:ok, my_port2} = PortAllocator.get_port()
    assert my_port1 != my_port2
    assert my_port2 == their_port
  end

  test "handles port range config, returns error if no available ports" do
    :ok = Application.put_env(:membrane_rtc_engine_sip, :port_range, {2137, 2138})
    restart_port_allocator()

    {:ok, 2137} = PortAllocator.get_port()
    {:ok, 2138} = PortAllocator.get_port()
    {:error, :no_available_port} = PortAllocator.get_port()

    :ok = Application.delete_env(:membrane_rtc_engine_sip, :port_range)
  end

  defp restart_port_allocator() do
    # PortAllocator gets started during application startup, so we have to kill it
    if GenServer.whereis(PortAllocator),
      do: GenServer.stop(PortAllocator, :kill)

    PortAllocator.start_link(nil)
  end
end
