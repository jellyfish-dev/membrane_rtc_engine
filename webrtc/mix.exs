defmodule Membrane.RTC.Engine.Endpoint.WebRTC.MixProject do
  use Mix.Project

  @version "0.5.0-dev"
  @engine_github_url "https://github.com/jellyfish-dev/membrane_rtc_engine"
  @github_url "#{@engine_github_url}/tree/master/webrtc"
  @source_ref "webrtc-v#{@version}"

  def project do
    [
      app: :membrane_rtc_engine_webrtc,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # hex
      description: "WebRTC Endpoint for Membrane RTC Engine",
      package: package(),

      # docs
      name: "Membrane RTC Engine WebRTC Endpoint",
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
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Engine deps
      {:membrane_rtc_engine, path: "../engine"},

      # Regular deps
      {:membrane_core, "~> 1.0"},
      {:membrane_webrtc_plugin, "~> 0.17.0"},
      {:membrane_rtp_plugin, "~> 0.24.1"},
      {:membrane_ice_plugin, "~> 0.17.0"},
      {:membrane_rtp_format, "~> 0.8.0"},
      {:membrane_rtp_vp8_plugin, "~> 0.9.0"},
      {:membrane_rtp_h264_plugin, "~> 0.19.0"},
      {:membrane_telemetry_metrics, "~> 0.1.0"},
      {:ex_sdp, "~> 0.13.1"},
      {:qex, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},

      # Test deps
      {:membrane_file_plugin, "~> 0.16.0"},
      {:excoveralls, "~> 0.16.0", only: :test, runtime: false}
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
      extras: extras(),
      formatters: ["html"],
      groups_for_extras: groups_for_extras(),
      assets: "internal_docs/assets",
      source_ref: @source_ref,
      source_url_pattern: "#{@engine_github_url}/blob/#{@source_ref}/webrtc/%{path}#L%{line}",
      nest_modules_by_prefix: [Membrane.RTC.Engine.Endpoint],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp extras() do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE",
      # guides
      "guides/simulcast.md",
      "guides/metrics.md",

      # internal docs
      "internal_docs/webrtc_media_events.md",
      "internal_docs/protocol.md",
      "internal_docs/webrtc_endpoint.md",
      "internal_docs/simulcast.md": [filename: "internal_simulcast"]
    ]
  end

  defp groups_for_extras() do
    [
      # negative lookahead to match everything
      # except upgrading directory
      {"Guides", ~r/guides\/(?!upgrading\/).*/},
      {"Upgrading", ~r/guides\/upgrading\//},
      {"Developer docs", ~r/internal_docs\//}
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@9.1.1/dist/mermaid.min.js"></script>
    <style>
      .diagramWrapper svg {
        background-color: white;
      }
    </style>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({ startOnLoad: false });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          graphEl.classList.add("diagramWrapper");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition, function (svgSource, bindListeners) {
            graphEl.innerHTML = svgSource;
            bindListeners && bindListeners(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end
end
