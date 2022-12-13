defmodule MembraneRtcEngine.Protocol.MediaEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  oneof :event, 0

  field :join, 1, type: MembraneRtcEngine.Protocol.Join, oneof: 0
  field :leave, 2, type: MembraneRtcEngine.Protocol.Leave, oneof: 0
  field :peerChanged, 3, type: MembraneRtcEngine.Protocol.PeerChanged, oneof: 0
  field :tracksChanged, 4, type: MembraneRtcEngine.Protocol.TracksChanged, oneof: 0
  field :tracksPriority, 5, type: MembraneRtcEngine.Protocol.TrackPriorityMediaEvent, oneof: 0
  field :error, 6, type: :string, oneof: 0
  field :custom, 2137, type: Google.Protobuf.Any, oneof: 0
end

defmodule MembraneRtcEngine.Protocol.Join do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :metadata, 1, type: :bytes
end

defmodule MembraneRtcEngine.Protocol.Leave do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3
end

defmodule MembraneRtcEngine.Protocol.PeerChanged.Payload.Empty do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3
end

defmodule MembraneRtcEngine.Protocol.PeerChanged.Payload.WithReason do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :reason, 1, type: :string
end

defmodule MembraneRtcEngine.Protocol.PeerChanged.Payload.WithMetadata do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :metadata, 1, type: :bytes
end

defmodule MembraneRtcEngine.Protocol.PeerChanged.Payload do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3
end

defmodule MembraneRtcEngine.Protocol.PeerChanged do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  oneof :action, 0

  field :peerId, 1, type: :string
  field :left, 2, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.Empty, oneof: 0
  field :removed, 3, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.WithReason, oneof: 0
  field :denied, 4, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.WithReason, oneof: 0
  field :accepted, 5, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.Empty, oneof: 0
  field :joined, 6, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.WithMetadata, oneof: 0
  field :updated, 7, type: MembraneRtcEngine.Protocol.PeerChanged.Payload.WithMetadata, oneof: 0
end

defmodule MembraneRtcEngine.Protocol.TracksChanged.Payload.Track do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :trackId, 1, type: :string
  field :metadata, 2, type: :bytes
end

defmodule MembraneRtcEngine.Protocol.TracksChanged.Payload do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3
end

defmodule MembraneRtcEngine.Protocol.TracksChanged do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  oneof :action, 0

  field :peerId, 1, type: :string
  field :update, 2, type: MembraneRtcEngine.Protocol.TracksChanged.Payload.Track, oneof: 0
  field :add, 3, type: MembraneRtcEngine.Protocol.TracksChanged.Payload.Track, oneof: 0
  field :remove, 4, type: MembraneRtcEngine.Protocol.TracksChanged.Payload.Track, oneof: 0
end

defmodule MembraneRtcEngine.Protocol.TrackPriorityMediaEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :trackId, 1, repeated: true, type: :string
end