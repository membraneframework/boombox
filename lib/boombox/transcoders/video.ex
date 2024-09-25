defmodule Boombox.Transcoders.Video do
  @moduledoc false
  use Membrane.Bin

  alias Boombox.Transcoders.Helpers.{ForwardingFilter, StreamFormatResolver}
  alias Membrane.Funnel
  alias Membrane.H264
  alias Membrane.H265
  alias Membrane.RawVideo
  alias Membrane.VP8

  def_input_pad :input, accepted_format: any_of(RawVideo, H264, H265, VP8)
  def_output_pad :output, accepted_format: any_of(RawVideo, H264, VP8)

  @type stream_format :: H264.t() | H265.t() | VP8.t() | RawVideo.t()
  @type stream_format_module :: H264 | VP8 | H265 | RawVideo
  @type stream_format_resolver :: (stream_format() -> stream_format() | stream_format_module())

  def_options input_stream_format: [
                spec: stream_format(),
                default: nil
              ],
              output_stream_format: [
                spec: stream_format() | stream_format_module() | stream_format_resolver()
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
    state =
      %{state | input_linked_with_output?: true}
      |> resolve_output_stream_format()

    spec = link_input_with_output(state.input_stream_format, state.output_stream_format)
    {[spec: spec], state}
  end

  defp resolve_output_stream_format(%{output_stream_format: format} = state)
       when is_struct(format) do
    state
  end

  defp resolve_output_stream_format(%{output_stream_format: format_module} = state)
       when is_atom(format_module) do
    %{state | output_stream_format: struct(format_module)}
  end

  defp resolve_output_stream_format(%{output_stream_format: format_resolver} = state)
       when is_function(format_resolver) do
    %{state | output_stream_format: format_resolver.(state.input_stream_format)}
    |> resolve_output_stream_format()
  end

  defp link_input_with_output(%H264{}, %H264{} = output_format) do
    get_child(:forwarding_filter)
    |> child(:h264_parser, %H264.Parser{
      output_stream_structure: stream_structure_type(output_format),
      output_alignment: output_format.alignment
    })
    |> get_child(:output_funnel)
  end

  defp link_input_with_output(%format_module{}, %format_module{}) do
    Membrane.Logger.debug("""
    This bin will only forward buffers, as the input stream format is the same type as the output stream format.
    """)

    get_child(:forwarding_filter) |> get_child(:output_funnel)
  end

  defp link_input_with_output(input_format, output_format) do
    get_child(:forwarding_filter)
    |> maybe_plug_parser_and_decoder(input_format)
    |> maybe_plug_encoder_and_parser(output_format)
    |> get_child(:output_funnel)
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

  defp maybe_plug_parser_and_decoder(buidler, %VP8{}) do
    # todo: maybe specify framerate in decoder options
    buidler |> child(:vp8_decoder, %VP8.Decoder{})
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

  defp maybe_plug_encoder_and_parser(builder, %VP8{}) do
    # todo: check if no option is required
    builder |> child(:vp8_encoder, %VP8.Encoder{})
  end

  defp maybe_plug_encoder_and_parser(builder, %RawVideo{}) do
    builder
  end

  defp stream_structure_type(%H264{stream_structure: stream_structure}) do
    case stream_structure do
      type when type in [:annexb, :avc1, :avc3] -> type
      {type, _dcr} when type in [:avc1, :avc3] -> type
    end
  end
end
