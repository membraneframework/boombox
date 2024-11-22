defmodule Boombox.ElixirStream do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad

  alias __MODULE__.{Sink, Source}
  alias Boombox.Pipeline.Ready

  @options_audio_keys [:audio_format, :audio_rate, :audio_channels]

  @spec create_input(producer :: pid, options :: Boombox.in_stream_opts()) :: Ready.t()
  def create_input(producer, options) do
    options = parse_options(options, :input)

    builders =
      [:audio, :video]
      |> Enum.filter(&(options[&1] != false))
      |> Map.new(fn
        :video ->
          {:video,
           get_child(:elixir_stream_source)
           |> via_out(Pad.ref(:output, :video))
           |> child(%Membrane.FFmpeg.SWScale.Converter{format: :I420})
           |> child(%Membrane.H264.FFmpeg.Encoder{profile: :baseline, preset: :ultrafast})}

        :audio ->
          {:audio,
           get_child(:elixir_stream_source)
           |> via_out(Pad.ref(:output, :audio))}
      end)

    spec_builder =
      child(:elixir_stream_source, %Source{producer: producer})

    %Ready{track_builders: builders, spec_builder: spec_builder}
  end

  @spec link_output(
          consumer :: pid,
          options :: Boombox.out_stream_opts(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(consumer, options, track_builders, spec_builder) do
    options = parse_options(options, :output)

    {track_builders, to_ignore} =
      Map.split_with(track_builders, fn {kind, _builder} -> options[kind] != false end)

    spec =
      [
        spec_builder,
        child(:elixir_stream_sink, %Sink{consumer: consumer}),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:mp4_audio_transcoder, %Boombox.Transcoder{
              output_stream_format: Membrane.RawAudio
            })
            |> maybe_plug_resampler(options)
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:elixir_stream_sink)

          {:video, builder} ->
            builder
            |> child(:elixir_stream_video_transcoder, %Boombox.Transcoder{
              output_stream_format: Membrane.RawVideo
            })
            |> child(:elixir_stream_rgb_converter, %Membrane.FFmpeg.SWScale.Converter{
              format: :RGB
            })
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:elixir_stream_sink)
        end),
        Enum.map(to_ignore, fn {_track, builder} -> builder |> child(Membrane.Debug.Sink) end)
      ]

    %Ready{actions: [spec: spec], eos_info: Map.keys(track_builders)}
  end

  @spec parse_options(Boombox.in_stream_opts(), :input) :: map()
  @spec parse_options(Boombox.out_stream_opts(), :output) :: map()
  defp parse_options(options, direction) do
    audio = Keyword.get(options, :audio)

    audio_keys =
      if direction == :output and audio != false and
           Enum.any?(@options_audio_keys, &Keyword.has_key?(options, &1)),
         do: @options_audio_keys,
         else: []

    options = Keyword.validate!(options, [:video, :audio] ++ audio_keys) |> Map.new()

    if options.audio == false and options.video == false do
      raise "Got audio and video options set to false. At least one track must be enabled."
    end

    options
  end

  defp maybe_plug_resampler(builder, %{
         audio_format: format,
         audio_rate: rate,
         audio_channels: channels
       }) do
    format = %Membrane.RawAudio{sample_format: format, sample_rate: rate, channels: channels}

    builder
    |> child(%Membrane.FFmpeg.SWResample.Converter{output_stream_format: format})
  end

  defp maybe_plug_resampler(builder, _options) do
    builder
  end
end
