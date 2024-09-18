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
  @type stream_format_module :: Membrane.AAC | Membrane.Opus

  @opus_sample_rate 48_000

  def_options input_stream_format: [
                spec: stream_format(),
                default: nil,
                description: """
                Format of the input stream.

                If set to nil, bin will resolve it based on the input stream format coming via the \
                `:input` pad.
                """
              ],
              output_stream_format_module: [
                spec: stream_format_module(),
                description: """
                Format of the output stream.

                Input stream will be transcoded, if it doesn't match the output stream format.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input() |> child(:data_receiver, DataReceiver),
      child(:output_funnel, Funnel) |> bin_output()
    ]

    state =
      Map.from_struct(opts)
      |> Map.put(:input_linked_with_output?, false)

    {link_actions, state} = maybe_link_input_with_output(state)
    {[spec: spec] ++ link_actions, state}
  end

  @impl true
  def handle_child_notification(
        {:input_stream_format, stream_format},
        :data_receiver,
        _ctx,
        state
      ) do
    %{state | input_stream_format: stream_format}
    |> maybe_link_input_with_output()
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp maybe_link_input_with_output(state)
       when state.input_linked_with_output? or state.input_stream_format == nil do
    {[], state}
  end

  defp maybe_link_input_with_output(state) do
    spec =
      link_input_with_output(
        state.input_stream_format,
        state.output_stream_format_module
      )

    state = %{state | input_linked_with_output?: true}
    {[spec: spec], state}
  end

  defp link_input_with_output(%format{}, format) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same as the output stream format.
    """)

    get_child(:data_receiver)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%Membrane.Opus{}, Membrane.AAC) do
    get_child(:data_receiver)
    |> child(:opus_decoder, Membrane.Opus.Decoder)
    |> child(:aac_encoder, Membrane.AAC.FDK.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%Membrane.AAC{sample_rate: @opus_sample_rate}, Membrane.Opus) do
    get_child(:data_receiver)
    |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
    |> child(:opus_encoder, Membrane.Opus.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%Membrane.AAC{} = input_format, Membrane.Opus) do
    get_child(:data_receiver)
    |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: @opus_sample_rate,
        channels: input_format.channels
      }
    })
    |> child(:opus_encoder, Membrane.Opus.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(input_format, output_format_module) do
    raise "Cannot transcode #{inspect(input_format)} to #{inspect(output_format_module)} yet"
  end
end
