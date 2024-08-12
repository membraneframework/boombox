defmodule Boombox.Transcoders.Audio do
  @moduledoc false

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.Funnel
  alias Boombox.Transcoders.DataReceiver

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
  def handle_init(_ctx, %{input_stream_format: nil} = opts) do
    spec = [
      bin_input() |> child(:data_receiver, DataReceiver),
      child(:output_forward_filter, Funnel) |> bin_output()
    ]

    state =
      Map.from_struct(opts)
      |> Map.put(:spec_generated?, false)

    {[spec: spec], state}
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      bin_input()
      |> generate_transcoding_spec(opts.input_stream_format, opts.output_stream_format)
      |> bin_output()

    state =
      Map.from_struct(opts)
      |> Map.put(:spec_generated?, true)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(
        {:input_stream_format, stream_format},
        :data_receiver,
        _ctx,
        %{spec_generated?: false} = state
      ) do
    spec =
      get_child(:data_receiver)
      |> generate_transcoding_spec(stream_format, state.output_stream_format)
      |> get_child(:output_forward_filter)

    state = %{state | input_stream_format: stream_format, spec_generated?: true}
    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp generate_transcoding_spec(input_spec_builder, input_format, output_format) when output_format in [input_format, input_format.__struct__] do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same as the output stream format.
    """)

    input_spec_builder
    |> child(:forwarding_filter, Membrane.Debug.Filter)
  end

  defp generate_transcoding_spec(
         input_spec_builder,
         %Membrane.AAC{channels: channels} = input_format,
         Membrane.Opus
       ) do
    decoding_spec =
      input_spec_builder
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)

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
  end

  defp generate_transcoding_spec(
         input_spec_builder,
         %Membrane.Opus{},
         Membrane.AAC
       ) do
    input_spec_builder
    |> child(:opus_decoder, Membrane.Opus.Decoder)
    |> child(:aac_encoder, Membrane.AAC.FDK.Encoder)
  end

  defp generate_transcoding_spec(_input_spec_builder, input_format, output_format) do
    raise "Cannot transform #{inspect(input_format)} to #{inspect(output_format)} yet"
  end
end
