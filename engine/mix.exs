defmodule Membrane.RTC.Engine.MixProject do
  use Mix.Project

  @version "0.19.0-dev"
  @github_url "https://github.com/jellyfish-dev/membrane_rtc_engine"
  @source_ref "engine-v#{@version}"

  def project do
    [
      app: :membrane_rtc_engine,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # hex
      description: "Membrane RTC Engine and its client library",
      package: package(),

      # docs
      name: "Membrane RTC Engine",
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
        "coveralls.json": :test,

        # test aliases
        "test.all": :test,
        "test.engine": :test
      ]
    ]
  end

  def application do
    [
      mod: {Membrane.RTC.Engine.App, []},
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_plugin, "~> 0.24.1"},
      {:membrane_rtp_format, "~> 0.8.0"},
      {:ex_sdp, "~> 0.13.1"},
      {:elixir_uuid, "~> 1.2"},
      {:statistics, "~> 0.6.0"},
      # for colouring diffs in upgrade guides
      {:makeup_diff, "~> 0.1", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},

      # Test deps
      {:excoveralls, "~> 0.16.0", only: :test, runtime: false},
      {:membrane_fake_plugin, "~> 0.11.0", only: :test}
    ]
  end

  defp aliases() do
    [
      "test.all": [
        "test.engine",
        "test.webrtc",
        "test.hls",
        "test.rtsp",
        "test.file",
        "test.integration"
      ],
      "test.engine": ["test"],
      "test.webrtc": fn _args -> test_package("webrtc") end,
      "test.webrtc.integration": &run_webrtc_integration_tests/1,
      "test.hls": fn _args -> test_package("hls") end,
      "test.rtsp": fn _args -> test_package("rtsp") end,
      "test.file": fn _args -> test_package("file") end,
      "test.integration": fn _args -> test_package("integration_test") end
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
      source_url_pattern: "#{@github_url}/blob/#{@source_ref}/engine/%{path}#L%{line}",
      nest_modules_by_prefix: [
        Membrane.RTC.Engine,
        Membrane.RTC.Engine.Event,
        Membrane.RTC.Engine.Exception,
        Membrane.RTC.Engine.Message
      ],
      before_closing_body_tag: &before_closing_body_tag/1,
      groups_for_modules: [
        Engine: [
          Membrane.RTC.Engine,
          Membrane.RTC.Engine.Endpoint,
          Membrane.RTC.Engine.Message,
          Membrane.RTC.Engine.Notifications.TrackNotification,
          Membrane.RTC.Engine.Track,
          Membrane.RTC.Engine.Track.BitrateEstimation
        ],
        Events: [
          ~r/^Membrane\.RTC\.Engine\.Event($|\.)/
        ],
        Messages: [
          ~r/^Membrane\.RTC\.Engine\.Message($|\.)/
        ],
        Exceptions: [
          ~r/^Membrane\.RTC\.Engine\.Exception($|\.)/
        ]
      ]
    ]
  end

  defp extras() do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE",
      # guides
      "guides/upgrading/v0.14.md",
      "guides/upgrading/v0.16.md",
      "guides/track_lifecycle.md",
      "guides/custom_endpoints.md",
      "guides/logs.md",
      "guides/traces.md",
      "guides/vad.md",

      # internal docs
      "internal_docs/engine_architecture.md": [filename: "internal_engine_architecture"]
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

  defp run_webrtc_integration_tests(_cli_args) do
    path = "../webrtc/integration_test/test_videoroom"

    assert_execute("mix", ["deps.get"],
      cd: path,
      log_str: "Getting mix dependencies in test_videoroom"
    )

    assert_execute("mix", ["compile", "--force", "--warnings-as-errors"],
      cd: path,
      log_str: "Compiling test_videoroom app"
    )

    assets_path = Path.join(path, "assets")

    if packages_installed?(assets_path) do
      Mix.shell().info(
        "Skipping installation of npm dependencies in test_videoroom: already installed"
      )
    else
      assert_execute("npm", ["ci"],
        cd: assets_path,
        log_str: "Installing npm dependencies in test_videoroom"
      )
    end

    assert_execute("mix", ["test"],
      cd: path,
      log_str: "Running integration tests"
    )
  end

  defp packages_installed?(dir) do
    System.cmd("npm", ["ls", "--prefix", dir, "--prefer-offline"], stderr_to_stdout: true)
    |> case do
      {output, 0} ->
        missing =
          output
          |> String.split("\n")
          |> Enum.filter(&Regex.match?(~r/UNMET DEPENDENCY|empty/, &1))

        if length(missing) > 0,
          do: false,
          else: true

      {_output, _} ->
        false
    end
  end

  defp test_package(name) do
    path = Path.join("../", name)

    assert_execute("mix", ["deps.get"],
      cd: path,
      log_str: "Getting mix dependencies in #{path}"
    )

    assert_execute("mix", ["test"],
      cd: path,
      log_str: "Running test suite in #{path}"
    )
  end

  defp assert_execute(cmd, args, cd: cd, log_str: log_str) do
    Mix.shell().info(log_str)
    {_io_stream, exit_status} = System.cmd(cmd, args, cd: cd, into: IO.stream())
    if exit_status != 0, do: raise("FATAL: #{log_str} failed")
  end
end
