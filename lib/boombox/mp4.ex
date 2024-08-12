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
      Enum.map(tracks, fn
        {id, %Membrane.AAC{} = format} ->
          spec =
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, id))
            |> child(:mp4_in_aac_parser, Membrane.AAC.Parser)

          {:audio, format, spec}

        {id, %Membrane.H264{} = format} ->
          spec = get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, id))
          {:video, format, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, spec_builder) do
    spec =
      [
        spec_builder,
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:mp4_file_sink, %Membrane.File.Sink{location: location}),
        Enum.map(track_builders, fn
          {:audio, format, builder} ->
            builder
            # |> child(:mp4_out_aac_encoder, Membrane.AAC.FDK.Encoder)
            |> child(:audio_transcoder, %Boombox.Transcoders.Audio{
              input_stream_format: format,
              output_stream_format: Membrane.AAC
            })
            |> child(:mp4_out_aac_parser, %Membrane.AAC.Parser{
              out_encapsulation: :none,
              output_config: :esds
            })
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:mp4_muxer)

          {:video, _format, builder} ->
            builder
            |> child(:mp4_out_h264_parser, %Membrane.H264.Parser{output_stream_structure: :avc3})
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:mp4_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
