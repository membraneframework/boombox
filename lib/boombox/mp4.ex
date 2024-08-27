defmodule Boombox.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, Wait}

  @spec create_input(String.t(), transport: :file | :http) :: Wait.t()
  def create_input(location, opts) do
    spec =
      case resolve_transport(location, opts) do
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
            |> child(:mp4_in_aac_decoder, Membrane.AAC.FDK.Decoder)

          {:audio, spec}

        {id, %Membrane.H264{}} ->
          spec = get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, id))
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
            |> child(:mp4_out_aac_encoder, Membrane.AAC.FDK.Encoder)
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

  defp resolve_transport(location, opts) do
    case Keyword.validate!(opts, transport: nil)[:transport] do
      nil ->
        uri = URI.new!(location)

        case uri.scheme do
          nil -> :file
          "http" -> :http
          "https" -> :http
          _other -> raise ArgumentError, "Unsupported MP4 URI: #{location}"
        end

      transport when transport in [:file, :http] ->
        transport

      transport ->
        raise ArgumentError, "Invalid transport: #{inspect(transport)}"
    end
  end
end
