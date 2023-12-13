defmodule Membrane.RTC.Engine.Endpoint.SIP.Application do
  @moduledoc false
  use Application

  alias Membrane.RTC.Engine.Endpoint.SIP

  @impl true
  def start(_start_type, _start_args) do
    children = [
      {Registry, keys: :unique, name: SIP.CallRegistry},
      SIP.PortAllocator
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
