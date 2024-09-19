defmodule Boombox.Utils.TranscodingBin do
  @moduledoc false

  use Membrane.Bin

  require Membrane.Logger

  alias Boombox.Utils.{ForwardingFilter, StreamFormatResolver}
  alias Membrane.{AAC, Funnel, Opus, RemoteStream}

  def_input_pad :input,
    accepted_format: any_of(AAC, Opus, %RemoteStream{content_format: Opus})

  def_output_pad :output, accepted_format: any_of(AAC, Opus)

  @type stream_format :: AAC.t() | Opus.t() | RemoteStream.t()
  @type stream_format_module :: AAC | Opus

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
      bin_input()
      |> child(:stream_format_resolver, StreamFormatResolver)
      |> child(:forwarding_filter, ForwardingFilter),
      child(:output_funnel, Funnel)
      |> bin_output()
    ]

    state =
      Map.from_struct(opts)
      |> Map.put(:input_linked_with_output?, false)

    {link_actions, state} = maybe_link_input_with_output(state)
    {[spec: spec] ++ link_actions, state}
  end

  @impl true
  def handle_child_notification(
        {:stream_format, stream_format},
        :stream_format_resolver,
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

    get_child(:forwarding_filter)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%RemoteStream{content_format: Opus}, Opus) do
    get_child(:forwarding_filter)
    |> child(:opus_parser, Opus.Parser)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%Opus{}, AAC) do
    get_child(:forwarding_filter)
    |> child(:opus_decoder, Opus.Decoder)
    |> child(:aac_encoder, AAC.FDK.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%RemoteStream{type: :packetized, content_format: Opus}, AAC) do
    get_child(:forwarding_filter)
    |> child(:opus_decoder, Opus.Decoder)
    |> child(:aac_encoder, AAC.FDK.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%AAC{sample_rate: @opus_sample_rate}, Opus) do
    get_child(:forwarding_filter)
    |> child(:aac_decoder, AAC.FDK.Decoder)
    |> child(:opus_encoder, Opus.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%AAC{} = input_format, Opus) do
    get_child(:forwarding_filter)
    |> child(:aac_decoder, AAC.FDK.Decoder)
    |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: @opus_sample_rate,
        channels: input_format.channels
      }
    })
    |> child(:opus_encoder, Opus.Encoder)
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(input_format, output_format_module) do
    raise "Cannot transcode #{inspect(input_format)} to #{inspect(output_format_module)} yet"
  end
end
