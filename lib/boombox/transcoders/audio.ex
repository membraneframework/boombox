defmodule Boombox.Transcoders.Audio do
  @moduledoc false

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.Funnel
  alias Membrane.Transcoders.DataReceiver

  def_input_pad :input,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus)

  def_output_pad :output,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus)

  @type stream_format :: Membrane.AAC.t() | Membrane.Opus.t()

  @opus_sample_rate 48_000

  def_options input_stream_format: [
                spec: stream_format(),
                description: "Format of the input stream"
              ],
              output_stream_format: [
                spec: stream_format(),
                description: """
                Specyfies format of the output stream.

                Input stream will be transformed, so it will match the output stream format.

                If transformation won't be possible or supported, an error will be raised.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = generate_transcoding_spec(opts.input_stream_format, opts.output_stream_format)
    {[spec: spec], Map.from_struct(opts)}
  end

  defp generate_transcoding_spec(_format, _format) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same as the output stream format.
    """)

    bin_input()
    |> child(:forwarding_filter, Membrane.Debug.Filter)
    |> bin_output()
  end

  defp generate_transcoding_spec(
         %Membrane.AAC{channels: channels} = input_format,
         %Membrane.Opus{channels: channels} = output_format
       ) do
    decoding_spec =
      bin_input()
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)

    resampling_spec =
      if input_format.sample_rate == @opus_sample_rate do
        decoding_spec
      else
        decoding_spec
        |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
          output_stream_format: %Membrane.RawAudio{
            sample_format: :s16le,
            sample_rate: @opus_sample_rate,
            channels: channels
          }
        })
      end

    resampling_spec
    |> child(:opus_encoder, Membrane.Opus.Encoder)
  end

  defp generate_transcoding_spec(
         %Membrane.Opus{channels: channels} = input_format,
         %Membrane.AAC{channels: channels} = output_format
       ) do
    bin_input()
    |> child(:opus_decoder, Membrane.Opus.Decoder)
    |> child(:aac_encoder, Membrane.AAC.FDK.Encoder)
  end

  defp generate_transcoding_spec(input_format, output_format) do
    raise "Cannot transform #{inspect(input_format)} to #{input_format(output_format)} yet"
  end
end
