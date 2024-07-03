defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, Wait}

  @spec create_input(Boombox.Pipeline.storage_type(), String.t()) :: Wait.t()
  def create_input(storage_type, location) do
    spec =
      case storage_type do
        :file ->
          child(%Membrane.File.Source{location: location, seekable?: true})
          |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

        :http ->
          child(%Membrane.Hackney.Source{
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
            |> child(Membrane.AAC.Parser)
            |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)

          {:audio, spec}

        {id, %Membrane.H264{}} ->
          spec = get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, id))
          {:video, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          Boombox.Pipeline.storage_type(),
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(storage_type, location, track_builders, spec_builder) do
    sink =
      case storage_type do
        :file ->
          &child(&1, :mp4_file_sink, %Membrane.File.Sink{location: location})

        :http ->
          &child(&1, :mp4_http_sink, %Membrane.Hackney.Sink{location: location})
      end

    spec =
      [
        spec_builder,
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> sink.(),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(Membrane.AAC.FDK.Encoder)
            |> child(%Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:mp4_muxer)

          {:video, builder} ->
            builder
            |> child(%Membrane.H264.Parser{output_stream_structure: :avc3})
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:mp4_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
