defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, State, Wait}
  alias Membrane.H264
  alias Membrane.H265

  defguardp is_h26x(format) when is_struct(format) and format.__struct__ in [H264, H265]

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

        {id, video_format} when is_h26x(video_format) ->
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
          Membrane.ChildrenSpec.t(),
          State.t()
        ) :: Ready.t()
  def link_output(location, track_builders, spec_builder, state) do
    spec =
      [
        spec_builder,
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:mp4_file_sink, %Membrane.File.Sink{location: location}),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:mp4_audio_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.AAC,
              force_transcoding?: state.force_transcoding in [true, :audio]
            })
            |> child(:mp4_out_aac_parser, %Membrane.AAC.Parser{
              out_encapsulation: :none,
              output_config: :esds
            })
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:mp4_muxer)

          {:video, builder} ->
            builder
            |> child(:mp4_video_transcoder, %Membrane.Transcoder{
              output_stream_format: fn
                %H264{stream_structure: :annexb} = h264 ->
                  %H264{h264 | stream_structure: :avc3, alignment: :au}

                %H265{stream_structure: :annexb} = h265 ->
                  %H265{h265 | stream_structure: :hev1, alignment: :au}

                h26x when is_h26x(h26x) ->
                  %{h26x | alignment: :au}

                _not_h26x ->
                  %H264{stream_structure: :avc3, alignment: :au}
              end,
              force_transcoding?: state.force_transcoding in [true, :video]
            })
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:mp4_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
