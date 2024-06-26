defmodule WebRTCToHLSWeb.HLSController do
  use WebRTCToHLSWeb, :controller

  alias Plug

  def index(conn, %{"prefix" => prefix, "filename" => filename}) do
    path = Path.join(prefix, filename)

    if File.exists?(path) do
      conn |> Plug.Conn.send_file(200, path)
    else
      conn |> Plug.Conn.send_resp(404, "File not found")
    end
  end
end
