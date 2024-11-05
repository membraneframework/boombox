defmodule Boombox.Transcoder.Video do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Membrane.{H264, H265, RawVideo, VP8}

  require Membrane.Logger

  @type video_stream_format :: VP8.t() | H264.t() | H265.t() | RawVideo.t()

  defguard is_video_format(format)
           when is_struct(format) and format.__struct__ in [VP8, H264, H265, RawVideo]

  @spec plug_video_transcoding(
          ChildrenSpec.Builder.t(),
          video_stream_format(),
          video_stream_format()
        ) :: ChildrenSpec.Builder.t()
  def plug_video_transcoding(builder, input_format, output_format)
      when is_video_format(input_format) and is_video_format(output_format) do
    do_plug_transcoding(builder, input_format, output_format)
  end

  defp do_plug_transcoding(builder, %h26x{}, %h26x{} = output_format) when h26x in [H264, H265] do
    parser =
      h26x
      |> Module.concat(Parser)
      |> struct!(
        output_stream_structure: stream_structure_type(output_format),
        output_alignment: output_format.alignment
      )

    builder |> child(:h264_parser, parser)
  end

  defp do_plug_transcoding(builder, %format_module{}, %format_module{}) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same type as the output stream format.
    """)

    builder
  end

  defp do_plug_transcoding(builder, input_format, output_format) do
    builder
    |> maybe_plug_parser_and_decoder(input_format)
    |> maybe_plug_encoder_and_parser(output_format)
  end

  defp maybe_plug_parser_and_decoder(builder, %H264{}) do
    builder
    |> child(:h264_input_parser, %H264.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(:h264_decoder, %H264.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %H265{}) do
    builder
    |> child(:h265_input_parser, %H265.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
    |> child(:h265_decoder, %H265.FFmpeg.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %VP8{}) do
    # todo: maybe specify framerate in decoder options
    builder |> child(:vp8_decoder, %VP8.Decoder{})
  end

  defp maybe_plug_parser_and_decoder(builder, %RawVideo{}) do
    builder
  end

  defp maybe_plug_encoder_and_parser(builder, %H264{} = h264) do
    # todo: specify different preset in eg. mp4
    builder
    |> child(:h264_encoder, %H264.FFmpeg.Encoder{preset: :ultrafast})
    |> child(:h264_output_parser, %H264.Parser{
      output_stream_structure: stream_structure_type(h264),
      output_alignment: h264.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %H265{} = h265) do
    # todo: specify different preset in eg. mp4
    builder
    |> child(:h264_encoder, %H265.FFmpeg.Encoder{preset: :ultrafast})
    |> child(:h264_output_parser, %H265.Parser{
      output_stream_structure: stream_structure_type(h265),
      output_alignment: h265.alignment
    })
  end

  defp maybe_plug_encoder_and_parser(builder, %VP8{}) do
    # todo: check if no option is required
    builder |> child(:vp8_encoder, %VP8.Encoder{})
  end

  defp maybe_plug_encoder_and_parser(builder, %RawVideo{}) do
    builder
  end

  defp stream_structure_type(%h26x{stream_structure: stream_structure})
       when h26x in [H264, H265] do
    case stream_structure do
      type when type in [:annexb, :avc1, :avc3, :hvc1, :hev1] -> type
      {type, _dcr} when type in [:avc1, :avc3, :hvc1, :hev1] -> type
    end
  end
end
