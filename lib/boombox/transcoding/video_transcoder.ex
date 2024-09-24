defmodule Boombox.Transcoding.VideoTranscoder do
  @moduledoc false
  alias Membrane.VP8
  alias Membrane.H264
  alias Membrane.RawVideo
  use Membrane.Bin

  def_input_pad :input, accepted_format: any_of(RawVideo, H264, VP8)
  def_output_pad :output, accepted_format: any_of(RawVideo, H264, VP8)

  defp link_input_with_output(%H264{} = input_format, %H264{} = output_format)
       when input_format.stream_structure != output_format.stream_structure or
              input_format.alignment != output_format.alignment do
    get_child(:forwarding_filter)
    |> child(:h264_parser, %H264.Parser{
      output_stream_structure: output_format.stream_structure,
      output_alignment: output_format.alignment
    })
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%format_module{}, %format_module{}) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same type as the output stream format.
    """)

    get_child(:forwarding_filter)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(input_format, output_format) do
    get_child(:forwarding_filter)
    |> maybe_plug_input_parser(input_format)
    |> maybe_plug_decoder(input_format)
    |> maybe_plug_encoder(output_format)
    |> maybe_plug_output_parser(output_format)
    |> get_child(:output_funnel)
  end

  defp maybe_plug_input_parser(builder, %H264{} = h264)
       when h264.stream_structure != :annexb or h264.alignment != :au do
    builder
    |> child(:h264_input_parser, %H264.Parser{
      output_stream_structure: :annexb,
      output_alignment: :au
    })
  end

  defp maybe_plug_input_parser(builder, _input_format) do
    builder
  end

  defp maybe_plug_decoder(builder, %H264{}) do
    builder |> child(:h264_decoder, %H264.FFmpeg.Decoder{})
  end

  defp maybe_plug_decoder(buidler, %VP8{}) do
    # todo: maybe specify framerate in decoder options
    buidler |> child(:vp8_decoder, %VP8.Decoder{})
  end

  defp maybe_plug_decoder(builder, %RawVideo{}) do
    builder
  end

  defp maybe_plug_encoder(builder, %H264{}) do
    # todo: specify different preset in eg. mp4
    builder |> child(:h264_encoder, %H264.FFmpeg.Encoder{preset: :ultrafast})
  end

  defp maybe_plug_encoder(builder, %VP8{}) do
    # todo: check if no option is required
    builder |> child(:vp8_encoder, %VP8.Encoder{})
  end

  defp maybe_plug_encoder(builder, %RawVideo{}) do
    builder
  end

  defp maybe_plug_output_parser(builder, %H264{} = h264)
       when h264.stream_structure != :annexb or h264.alignment != :au do
    builder
    |> child(:h264_input_parser, %H264.Parser{
      output_stream_structure: h264.stream_structure,
      output_alignment: h264.alignment
    })
  end

  defp maybe_plug_output_parser(builder, _output_format) do
    builder
  end
end
