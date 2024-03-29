defmodule VideoRoom.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_videoroom_demo,
      version: "0.1.0",
      elixir: "~> 1.13",
      aliases: aliases(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {VideoRoom.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.0"},
      {:phoenix, "~> 1.6"},
      {:phoenix_html, "~> 3.0"},
      {:phoenix_live_view, "~> 0.16.0"},
      {:phoenix_live_reload, "~> 1.2"},
      {:poison, "~> 3.1"},
      {:jason, "~> 1.2"},
      {:phoenix_inline_svg, "~> 1.4"},
      {:telemetry, "~> 1.0.0", override: true},
      {:esbuild, "~> 0.4", runtime: Mix.env() == :dev},

      # rtc engine dependencies
      {:membrane_rtc_engine,
       github: "jellyfish-dev/membrane_rtc_engine",
       sparse: "engine",
       ref: "91499e6958c9243f535d9e7486ae46915f492372",
       override: true},
      {:membrane_rtc_engine_webrtc,
       github: "jellyfish-dev/membrane_rtc_engine",
       sparse: "webrtc",
       ref: "91499e6958c9243f535d9e7486ae46915f492372"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --cd assets npm ci"],
      "assets.deploy": [
        "cmd --cd assets npm run deploy",
        "esbuild default --minify",
        "phx.digest"
      ]
    ]
  end
end
