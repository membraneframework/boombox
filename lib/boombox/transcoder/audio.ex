defmodule Membrane.Boombox.Transcoder.Audio do
  @moduledoc false
  use Membrane.Bin

  require Membrane.Logger

  import Membrane.ChildrenSpec
  alias Membrane.{AAC, Funnel, Opus, RawAudio, RemoteStream}


  defguard is_audio_format(format)
           when is_struct(format) and format.__struct__ in [RawVideo, H264, H265, VP8]

  def plug_transcoding(buidler, input_format, output_format) when is_audio_format(input_format) and is_audio_format(output_format) do
    do_plug_transcoding(builder, input_format, output_format)
  end

  defp do_plug_transcoding(buidler, %format_module{}, format_module) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same as the output stream format.
    """)

    builder
  end

  defp do_plug_transcoding(buidler, %RemoteStream{content_format: Opus}, Opus) do
    builder |> child(:opus_parser, Opus.Parser)
  end

  defp do_plug_transcoding(buidler, input_format, output_format_module) do
    builder
    |> maybe_plug_decoder(input_format)
    |> maybe_plug_resampler(input_format, output_format_module)
    |> maybe_plug_encoder(output_format_module)
  end

  defp maybe_plug_decoder(builder, %Opus{}) do
    builder |> child(:opus_decoder, Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %RemoteStream{content_format: Opus, type: :packetized}) do
    builder |> child(:opus_decoder, Opus.Decoder)
  end

  defp maybe_plug_decoder(builder, %AAC{}) do
    builder |> child(:aac_decoder, AAC.FDK.Decoder)
  end

  defp maybe_plug_decoder(builder, %RawAudio{}) do
    builder
  end

  defp maybe_plug_resampler(builder, %{sample_rate: sample_rate} = input_format, Opus)
       when sample_rate != @opus_sample_rate do
    builder
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{
        sample_format: :s16le,
        sample_rate: @opus_sample_rate,
        channels: input_format.channels
      }
    })
  end

  defp maybe_plug_resampler(builder, _input_format, _output_format_module) do
    builder
  end

  defp maybe_plug_encoder(builder, Opus) do
    builder |> child(:opus_encoder, Opus.Encoder)
  end

  defp maybe_plug_encoder(builder, AAC) do
    builder |> child(:aac_encoder, AAC.FDK.Encoder)
  end

  defp maybe_plug_encoder(builder, RawAudio) do
    builder
  end
end
