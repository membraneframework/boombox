defmodule Membrane.Boombox.Transcoder do
  @moduledoc false
  use Membrane.Bin

  require Membrane.Boombox.Transcoder
  alias Boombox.Transcoders.Helpers.ForwardingFilter
  alias Membrane.Funnel
  alias Membrane.H264
  alias Membrane.H265
  alias Membrane.RawVideo
  alias Membrane.VP8

  defguard is_video_format(format)
           when is_struct(format) and
                  (format.__struct__ in [AAC, Opus, RawAudio] or
                     (format.__struct__ == RemoteStream and format.content_format == Opus and
                        format.type == :packetized))

  defguard is_audio_format(format)
           when is_struct(format) and format.__struct__ in [RawVideo, H264, H265, VP8]

  def_input_pad :input,
    accepted_format: format when is_audio_format(format) or is_video_format(format)

  def_output_pad :output,
    accepted_format: format when is_audio_format(format) or is_video_format(format)

  @type stream_format ::
          H264.t()
          | H265.t()
          | VP8.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | RemoteStream.t()
          | RawAudio.t()

  @type stream_format_module :: H264 | VP8 | H265 | RawVideo | AAC | Opus | RawAudio

  @type stream_format_resolver :: (stream_format() -> stream_format() | stream_format_module())

  def_options output_stream_format: [
                spec: stream_format() | stream_format_module() | stream_format_resolver()
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input()
      |> child(:forwarding_filter, ForwardingFilter),
      child(:output_funnel, Funnel)
      |> bin_output()
    ]

    state =
      opts
      |> Map.from_struct()
      |> Map.put(:input_stream_format, nil)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:stream_format, format}, :forwarding_filter, _ctx, state) do
    state = %{state | input_stream_format: format}

    actions =
      cond do
        is_audio_format(format) -> Audio.link_actions(state)
        is_video_format(format) -> Video.link_actions(state)
      end

    {actions, state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp maybe_link_input_with_output(state) do
    state =
      %{state | input_linked_with_output?: true}
      |> resolve_output_stream_format()

    spec = link_input_with_output(state.input_stream_format, state.output_stream_format)
    {[spec: spec], state}
  end

  defp resolve_output_stream_format(%{output_stream_format: format} = state) do
    cond do
      is_struct(format) ->
        state

      is_module(format) ->
        %{state | output_stream_format: struct(format)}

      is_function(format) ->
        %{state | output_stream_format: format.(state.input_stream_format)}
        |> resolve_output_stream_format()
    end
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
