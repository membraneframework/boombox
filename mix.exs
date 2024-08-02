defmodule Boombox.Mixfile do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/membraneframework/boombox"

  def project do
    [
      app: :boombox,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "Boombox",
      package: package(),

      # docs
      name: "Boombox",
      source_url: @github_url,
      docs: docs()
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
      {:membrane_core, "~> 1.0"},
      {:membrane_webrtc_plugin, "~> 0.20.0"},
      {:membrane_opus_plugin, ">= 0.0.0"},
      {:membrane_aac_plugin, ">= 0.0.0"},
      {:membrane_aac_fdk_plugin, ">= 0.0.0"},
      {:membrane_h26x_plugin, ">= 0.0.0"},
      {:membrane_h264_ffmpeg_plugin, ">= 0.0.0"},
      {:membrane_mp4_plugin, github: "membraneframework/membrane_mp4_plugin", branch: "wip-avc3"},
      {:membrane_realtimer_plugin, ">= 0.0.0"},
      # {:membrane_rtmp_plugin, ">= 0.0.0"},
      {:membrane_rtmp_plugin, github: "membraneframework/membrane_rtmp_plugin"},
      {:membrane_ffmpeg_swresample_plugin, ">= 0.0.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
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
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Boombox]
    ]
  end
end
