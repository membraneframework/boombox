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
      releases: releases(),

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
      extra_applications: [],
      mod:
        if burrito?() do
          {Boombox.Utils.BurritoApp, []}
        else
          []
        end
    ]
  end

  defp burrito?, do: System.get_env("BOOMBOX_BURRITO") != nil

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.1"},
      {:membrane_webrtc_plugin,
       github: "membraneframework/membrane_webrtc_plugin", branch: "ex-webrtc-0.4"},
      {:ex_sdp, "~> 1.0", override: true},
      {:membrane_opus_plugin, "~> 0.20.3"},
      {:membrane_aac_plugin, "~> 0.18.0"},
      {:membrane_aac_fdk_plugin, "~> 0.18.0"},
      {:membrane_h26x_plugin, "~> 0.10.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32.0"},
      {:membrane_mp4_plugin, "~> 0.35.2"},
      {:membrane_realtimer_plugin, "~> 0.9.0"},
      {:membrane_http_adaptive_stream_plugin, "~> 0.18.5"},
      {:membrane_rtmp_plugin, "~> 0.25.0"},
      {:membrane_rtsp_plugin, "~> 0.3.0"},
      {:membrane_rtp_plugin, "~> 0.29.0"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
      {:membrane_hackney_plugin, "~> 0.11.0"},
      {:membrane_ffmpeg_swscale_plugin, "~> 0.16.0"},
      {:image, "~> 0.54.0"},
      {:burrito, "~> 1.0", runtime: burrito?()},
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

  defp releases() do
    {burrito_wrap, burrito_config} =
      if burrito?() do
        {&Burrito.wrap/1, burrito_config()}
      else
        {& &1, []}
      end

    [
      boombox:
        [
          steps: [:assemble, &restore_symlinks/1, burrito_wrap]
        ] ++
          burrito_config
    ]
  end

  defp burrito_config() do
    current_os =
      case :os.type() do
        {:win32, _} -> :windows
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
      end

    arch_string =
      :erlang.system_info(:system_architecture)
      |> to_string()
      |> String.downcase()
      |> String.split("-")
      |> List.first()

    current_cpu =
      case arch_string do
        "x86_64" -> :x86_64
        "arm64" -> :aarch64
        "aarch64" -> :aarch64
        _ -> :unknown
      end

    [
      burrito: [
        targets: [
          current: [os: current_os, cpu: current_cpu]
        ]
      ]
    ]
  end

  # mix release doesn't preserve symlinks, but replaces
  # them with whatever they point to, while
  # bundlex uses symlinks to provide precompiled deps.
  # That makes the release size enormous, so this workaroud
  # recreates the symlinks by replacing the copied data
  # with new symlinks pointing to bundlex's
  # priv/shared/precompiled directory
  defp restore_symlinks(release) do
    base_dir = "#{__DIR__}/_build/dev/rel/boombox/lib"

    shared =
      Path.wildcard("#{base_dir}/bundlex*/priv/shared/precompiled/*")
      |> Enum.map(&Path.relative_to(&1, base_dir))
      |> Map.new(&{Path.basename(&1), &1})

    Path.wildcard("#{base_dir}/*/priv/bundlex/*/*")
    |> Enum.each(fn path ->
      name = Path.basename(path)

      case shared[name] do
        nil ->
          :ok

        shared_dir ->
          File.rm_rf!(path)
          depth = path |> Path.relative_to(base_dir) |> Path.split() |> length()
          ln = String.duplicate("../", depth - 1) <> shared_dir
          dbg(path)
          dbg(ln)
          File.ln_s!(ln, path)
      end
    end)

    release
  end
end
