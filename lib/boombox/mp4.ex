defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad

  def create_input(location) do
    spec =
      child(%Membrane.File.Source{location: location, seekable?: true})
      |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

    {:wait, spec}
  end

  def handle_input_tracks(tracks) do
    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    spec =
      get_child(:mp4_demuxer)
      |> via_out(Pad.ref(:output, audio_id))
      |> child(Membrane.AAC.Parser)
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)

    builders = %{
      audio: get_child(:aac_decoder),
      video: get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, video_id))
    }

    {:ready, spec, builders}
  end

  def create_output(location, builders) do
    spec =
      [
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:mp4_file_sink, %Membrane.File.Sink{location: location}),
        builders.audio
        |> child(Membrane.AAC.FDK.Encoder)
        |> child(%Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
        |> get_child(:mp4_muxer),
        builders.video
        |> child(%Membrane.H264.Parser{output_stream_structure: :avc3})
        |> get_child(:mp4_muxer)
      ]

    {:ready, spec}
  end
end
