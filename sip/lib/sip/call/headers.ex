defmodule Membrane.RTC.Engine.Endpoint.SIP.Call.Headers do
  @moduledoc false

  @caller_identifier "Engine"
  @user_agent "RTC Engine/SIP/0.1"
  @max_forwards 70

  @spec create_headers_base(Sippet.URI.t()) :: map()
  def create_headers_base(from_address) do
    %{
      from: {
        @caller_identifier,
        from_address,
        %{"tag" => Sippet.Message.create_tag()}
      },
      via: {{2, 0}, :udp, {from_address.host, from_address.port}},
      contact: [
        {
          @caller_identifier,
          from_address,
          %{}
        }
      ],
      user_agent: @user_agent,
      max_forwards: @max_forwards
    }
  end
end
