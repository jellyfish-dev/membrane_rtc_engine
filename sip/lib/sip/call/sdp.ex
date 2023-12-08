defmodule Membrane.RTC.Engine.Endpoint.SIP.Call.SDP do
  @moduledoc false

  alias Membrane.RTP.PayloadFormat

  @accepted_payload_types [8]
  @session_name "Telefish"
  @username "Jellyfish"

  @spec proposal(String.t(), 1..65_535) :: {String.t(), non_neg_integer()}
  def proposal(external_ip, rtp_port) do
    sdp = create_proposal(external_ip, rtp_port) |> to_string()

    {sdp, byte_size(sdp)}
  end

  @spec parse(String.t()) ::
          {:ok, map()}
          | {:error,
             :not_supported_addr_type
             | :no_audio_media
             | :unknown_fmt
             | :no_common_fmt
             | {:other, term()}}
  def parse(body) do
    with {:ok, sdp} <- ExSDP.parse(body),
         audio_media when is_map(audio_media) <-
           Enum.find(sdp.media, :no_audio_media, &(&1.type == :audio)),
         fmt when not is_binary(fmt) <- audio_media.fmt,
         common_pts when common_pts != [] <-
           @accepted_payload_types -- @accepted_payload_types -- fmt,
         chosen_pt <- List.first(common_pts) do
      {:ok,
       %{
         rtp_payload_fmt: {chosen_pt, PayloadFormat.get_payload_type_mapping(chosen_pt)},
         connection_data: audio_media.connection_data || sdp.connection_data,
         port: audio_media.port
       }}
    else
      {:error, reason} ->
        {:error, {:other, reason}}

      {:not_supported_addr_type, _addr} ->
        {:error, :not_supported_addr_type}

      :no_audio_media ->
        {:error, :no_audio_media}

      fmt when is_binary(fmt) ->
        {:error, :unknown_fmt}

      [] ->
        {:error, :no_common_fmt}
    end
  end

  defp create_proposal(external_ip, rtp_port) do
    connection_data = %ExSDP.ConnectionData{address: {:IP4, external_ip}, network_type: "IN"}
    media = ExSDP.Media.new(:audio, rtp_port, "RTP/AVP", @accepted_payload_types)

    ExSDP.new(address: {:IP4, external_ip}, session_name: @session_name, username: @username)
    |> Map.replace(:connection_data, connection_data)
    |> ExSDP.add_media(media)
    |> ExSDP.add_attribute("sendrecv")
    |> ExSDP.add_attribute("rtcp-mux")
  end
end
