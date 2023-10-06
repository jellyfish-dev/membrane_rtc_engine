defmodule Membrane.RTC.Engine.Endpoint.Remote.App do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Membrane.RTC.Engine.Remote.PubSub}
    ]

    opts = [strategy: :one_for_one, name: Membrane.RTC.Engine.Remote.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
