defmodule Membrane.RTC.Engine.Endpoint.SIP.Application do
  @moduledoc false
  use Application

  alias Membrane.RTC.Engine.Endpoint.SIP
  alias Membrane.RTC.Engine.Endpoint.SIP.SippetCore

  @impl true
  def start(_start_type, _start_args) do
    SippetCore.setup()

    children = [
      {Registry, keys: :unique, name: SIP.CallRegistry},
      SIP.PortAllocator
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
