defmodule Membrane.RTC.Engine.Endpoint.SIP.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_start_type, _start_args) do
    children = [
      {Registry, keys: :unique, name: SipEndpoint.CallRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
