defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, Wait}

  @spec create_input(String.t()) :: Wait.t()
  def create_input(location) do
    spec =
      child(%Membrane.File.Source{location: location, seekable?: true})
      |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks(Membrane.MP4.Demuxer.ISOM.new_tracks_t()) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      Map.new(tracks, fn
        {id, %Membrane.AAC{}} ->
          spec =
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, id))
            |> child(:mp4_in_aac_parser, Membrane.AAC.Parser)

          {:audio, spec}

        {id, %Membrane.H264{}} ->
          spec = get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, id))
          {:video, spec}
      end)

    track_formats =
      Map.new(tracks, fn
        {_id, %Membrane.AAC{} = format} -> {:audio, format}
        {_id, %Membrane.H264{} = format} -> {:video, format}
      end)

    %Ready{track_builders: track_builders, track_formats: track_formats}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Boombox.Pipeline.track_formats(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, track_formats, spec_builder) do
    spec =
      [
        spec_builder,
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:mp4_file_sink, %Membrane.File.Sink{location: location}),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:audio_transcoder, %Boombox.Transcoders.Audio{
              input_stream_format: track_formats.audio,
              output_stream_format_module: Membrane.AAC
            })
            |> child(:mp4_out_aac_parser, %Membrane.AAC.Parser{
              out_encapsulation: :none,
              output_config: :esds
            })
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:mp4_muxer)

          {:video, builder} ->
            builder
            |> child(:mp4_out_h264_parser, %Membrane.H264.Parser{output_stream_structure: :avc3})
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:mp4_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
