defmodule Membrane.RTC.Engine.Endpoint.SIP.MixProject do
  use Mix.Project

  @version "0.0.1-dev"
  @engine_github_url "https://github.com/jellyfish-dev/membrane_rtc_engine"
  @github_url "#{@engine_github_url}/tree/master/sip"
  @source_ref "sip-v#{@version}"

  def project do
    [
      app: :membrane_rtc_engine_sip,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # hex
      description: "SIP Endpoint for Membrane RTC Engine",
      package: package(),

      # docs
      name: "Membrane RTC Engine SIP Endpoint",
      source_url: @github_url,
      homepage_url: "https://membrane.stream",
      docs: docs(),

      # test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      mod: {Membrane.RTC.Engine.Endpoint.SIP.Application, []},
      extra_applications: [:sippet]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Engine deps
      {:membrane_rtc_engine, path: "../engine"},
      {:membrane_rtc_engine_webrtc, path: "../webrtc"},
      # TODO move to integration_test
      {:membrane_rtc_engine_file, path: "../file", only: :test},
      {:membrane_rtc_engine_hls, path: "../hls", only: :test},
      {:membrane_tee_plugin, "~> 0.12.0"},
      {:membrane_file_plugin, "~> 0.16.0"},

      # Regular deps
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_plugin, "~> 0.24.0"},
      {:membrane_rtp_format, "~> 0.8.0"},
      # {:membrane_udp_plugin, "~> 0.10.0"},
      {:membrane_udp_plugin,
       github: "membraneframework/membrane_udp_plugin", override: true},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_raw_audio_parser_plugin, "~> 0.4.0"},
      {:membrane_g711_format, "~> 0.1.0"},
      {:membrane_g711_ffmpeg_plugin, github: "jellyfish-dev/membrane_g711_ffmpeg_plugin"},
      {:membrane_rtp_g711_plugin, github: "jellyfish-dev/membrane_rtp_g711_plugin"},
      {:membrane_opus_plugin, "~> 0.19.0"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.19.0"},
      {:membrane_audio_mix_plugin, "~> 0.16.0"},
      {:membrane_aac_fdk_plugin, "~> 0.18.0"},
      # {:sippet, "1.0.8"},
      {:sippet, github: "balena/elixir-sippet"},
      {:ex_sdp, "~> 0.11"},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},

      # Test deps
      {:excoveralls, "~> 0.16.0", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": [
        "cmd docker compose -f docker-compose-test.yaml --env-file .env up test --exit-code-from test"
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      formatters: ["html"],
      source_ref: @source_ref,
      source_url_pattern: "#{@engine_github_url}/blob/#{@source_ref}/sip/%{path}#L%{line}",
      nest_modules_by_prefix: [Membrane.RTC.Engine.Endpoint]
    ]
  end
end
