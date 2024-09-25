defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, Wait}
  alias Boombox.Transcoding.{AudioTranscoder, VideoTranscoder}
  alias Membrane.H264
  alias Membrane.RawVideo
  alias Membrane.VP8

  @spec create_input(String.t(), transport: :file | :http) :: Wait.t()
  def create_input(location, opts) do
    spec =
      case opts[:transport] do
        :file ->
          child(:mp4_in_file_source, %Membrane.File.Source{location: location, seekable?: true})
          |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

        :http ->
          child(:mp4_in_http_source, %Membrane.Hackney.Source{
            location: location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM)
      end

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
          spec =
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, id))

          {:video, spec}
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
          {:audio, builder} ->
            builder
            # |> child(:mp4_out_aac_encoder, Membrane.AAC.FDK.Encoder)
            |> child(:mp4_audio_transcoder, %AudioTranscoder{
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
            # |> child(:mp4_out_h264_parser, %Membrane.H264.Parser{output_stream_structure: :avc3})
            |> child(:mp4_video_transcoder, %VideoTranscoder{
              output_stream_format: fn
                %H264{stream_structure: :annexb} = h264 ->
                  %{h264 | stream_structure: :avc3, alignment: :au}

                %H264{} = h264 ->
                  %{h264 | alignment: :au}

                %RawVideo{} ->
                  %H264{stream_structure: :avc3, alignment: :au}

                %VP8{} ->
                  %H264{stream_structure: :avc3, alignment: :au}
              end
            })
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:mp4_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
