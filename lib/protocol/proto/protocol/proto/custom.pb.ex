defmodule MembraneRtcEngine.Protocol.WebRtcCustomMediaEvent.Test do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :payload, 1, type: :string
end

defmodule MembraneRtcEngine.Protocol.WebRtcCustomMediaEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3
end