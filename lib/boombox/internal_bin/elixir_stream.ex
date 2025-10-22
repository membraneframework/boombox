defmodule Boombox.InternalBin.ElixirStream do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad

  alias __MODULE__.{Sink, Source}
  alias Boombox.InternalBin.Ready
  alias Membrane.FFmpeg.SWScale

  @options_audio_keys [:audio_format, :audio_rate, :audio_channels]

  # the size of the toilet capacity is supposed to handle more or less
  # the burst of packets from one segment of Live HLS stream
  @realtimer_toilet_capacity 10_000

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
           |> child(%SWScale.Converter{format: :I420})
           |> child(%Membrane.H264.FFmpeg.Encoder{profile: :baseline, preset: :ultrafast})}

        :audio ->
          {:audio,
           get_child(:elixir_stream_source)
           |> via_out(Pad.ref(:output, :audio))}
      end)

    spec_builder = child(:elixir_stream_source, %Source{producer: producer})

    %Ready{track_builders: builders, spec_builder: spec_builder}
  end

  @spec link_output(
          consumer :: pid,
          options :: Boombox.out_stream_opts(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean()
        ) :: Ready.t()
  def link_output(consumer, options, track_builders, spec_builder, is_input_realtime) do
    options = parse_options(options, :output)
    pace_control = Map.get(options, :pace_control, true)

    {track_builders, to_ignore} =
      Map.split_with(track_builders, fn {kind, _builder} -> options[kind] != false end)

    spec =
      [
        spec_builder,
        child(:elixir_stream_sink, %Sink{consumer: consumer}),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:elixir_stream_audio_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.RawAudio
            })
            |> maybe_plug_resampler(options)
            |> maybe_plug_realtimer(:audio, pace_control, is_input_realtime)
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:elixir_stream_sink)

          {:video, builder} ->
            builder
            |> child(:elixir_stream_video_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.RawVideo
            })
            |> child(:elixir_stream_rgb_converter, %SWScale.Converter{
              format: :RGB,
              output_width: options[:video_width],
              output_height: options[:video_height]
            })
            |> maybe_plug_realtimer(:video, pace_control, is_input_realtime)
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:elixir_stream_sink)
        end),
        Enum.map(to_ignore, fn {_track, builder} -> builder |> child(Membrane.Debug.Sink) end)
      ]

    %Ready{actions: [spec: spec], eos_info: Map.keys(track_builders)}
  end

  defp maybe_plug_realtimer(builder, kind, pace_control, is_input_realtime)

  defp maybe_plug_realtimer(builder, kind, true, false) do
    builder
    |> via_in(:input, toilet_capacity: @realtimer_toilet_capacity)
    |> child({:elixir_stream, kind, :realtimer}, Membrane.Realtimer)
  end

  defp maybe_plug_realtimer(builder, _kind, _pace_control, _is_input_realtime), do: builder

  @spec parse_options(Boombox.in_stream_opts(), :input) :: map()
  @spec parse_options(Boombox.out_stream_opts(), :output) :: map()
  defp parse_options(options, direction) do
    audio = Keyword.get(options, :audio)

    audio_keys =
      if direction == :output and audio != false and
           Enum.any?(@options_audio_keys, &Keyword.has_key?(options, &1)),
         do: @options_audio_keys,
         else: []

    options =
      options
      |> Keyword.validate!(
        [:video, :audio, :video_width, :video_height, :pace_control, :is_live] ++ audio_keys
      )
      |> Map.new()

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
