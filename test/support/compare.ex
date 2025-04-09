defmodule Support.Compare do
  @moduledoc false

  import ExUnit.Assertions
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad

  alias Membrane.Testing

  @type compare_option ::
          {:kinds, [:audio | :video]}
          | {:format, :mp4 | :hls}
          | {:subject_terminated_early, boolean()}

  defmodule GetBuffers do
    @moduledoc false
    use Membrane.Sink

    def_input_pad :input, accepted_format: _any

    @impl true
    def handle_init(_ctx, _opts) do
      {[], %{acc: []}}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[], %{acc: [buffer | state.acc]}}
    end

    @impl true
    def handle_end_of_stream(:input, _ctx, state) do
      {[notify_parent: {:buffers, Enum.reverse(state.acc)}], state}
    end
  end

  @spec compare(Path.t(), Path.t(), [compare_option()]) :: :ok
  def compare(subject, reference, options \\ []) do
    kinds = options[:kinds] || [:audio, :video]
    format = options[:format] || :mp4
    subject_terminated_early = options[:subject_terminated_early] || false
    p = Testing.Pipeline.start_link_supervised!()

    Testing.Pipeline.execute_actions(p, spec: get_source_spec(subject, reference, format))

    assert_pipeline_notified(p, :ref_demuxer, {:new_tracks, ref_tracks})

    ref_spec =
      Enum.map(ref_tracks, fn
        {id, %Membrane.AAC{}} ->
          get_child(:ref_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(Membrane.AAC.Parser)
          |> child(Membrane.AAC.FDK.Decoder)
          |> child(:ref_audio_bufs, GetBuffers)

        {id, %h26x{}} when h26x in [Membrane.H264, Membrane.H265] ->
          {parser, decoder} = get_h26x_parser_and_decoder(h26x)

          get_child(:ref_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(parser)
          |> child(decoder)
          |> child(:ref_video_bufs, GetBuffers)
      end)

    assert_pipeline_notified(p, :sub_demuxer, {:new_tracks, sub_tracks})

    assert length(sub_tracks) == length(kinds)

    sub_spec =
      Enum.map(sub_tracks, fn
        {id, %Membrane.AAC{}} ->
          assert :audio in kinds

          get_child(:sub_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(Membrane.AAC.Parser)
          |> child(Membrane.AAC.FDK.Decoder)
          |> child(%Membrane.FFmpeg.SWResample.Converter{
            output_stream_format: %Membrane.RawAudio{
              sample_format: :s16le,
              sample_rate: 44_100,
              channels: 1
            }
          })
          |> child(:sub_audio_bufs, GetBuffers)

        {id, %h26x{}} when h26x in [Membrane.H264, Membrane.H265] ->
          assert :video in kinds

          {parser, decoder} = get_h26x_parser_and_decoder(h26x)

          get_child(:sub_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(parser)
          |> child(decoder)
          |> child(:sub_video_bufs, GetBuffers)
      end)

    Testing.Pipeline.execute_actions(p, spec: [ref_spec, sub_spec])

    if :video in kinds do
      assert_pipeline_notified(p, :sub_video_bufs, {:buffers, sub_video_bufs})
      assert_pipeline_notified(p, :ref_video_bufs, {:buffers, ref_video_bufs})

      ref_video_bufs =
        if subject_terminated_early do
          Enum.take(ref_video_bufs, length(sub_video_bufs))
        else
          ref_video_bufs
        end

      assert length(ref_video_bufs) == length(sub_video_bufs)

      Enum.zip(sub_video_bufs, ref_video_bufs)
      |> Enum.each(fn {sub, ref} ->
        # The results differ between operating systems
        # and subsequent runs due to transcoding.
        # The threshold here is obtained empirically and may need
        # to be adjusted, or a better metric should be used.
        assert samples_min_squared_error(sub.payload, ref.payload, 8) < 10
      end)
    end

    if :audio in kinds do
      assert_pipeline_notified(p, :sub_audio_bufs, {:buffers, sub_audio_bufs})
      assert_pipeline_notified(p, :ref_audio_bufs, {:buffers, ref_audio_bufs})

      ref_audio = Enum.map_join(ref_audio_bufs, & &1.payload)
      sub_audio = Enum.map_join(sub_audio_bufs, & &1.payload)
      assert byte_size(sub_audio) - byte_size(ref_audio) < 0.01 * byte_size(sub_audio)
      # The results differ between operating systems
      # and subsequent runs due to transcoding.
      # The threshold here is obtained empirically and may need
      # to be adjusted, or a better metric should be used.

      assert samples_min_squared_error(sub_audio, ref_audio, 16) < 30_000
    end

    Testing.Pipeline.terminate(p)
  end

  @spec samples_min_squared_error(binary, binary, pos_integer) :: float()
  def samples_min_squared_error(bin1, bin2, sample_size) do
    Enum.zip_with(
      for(<<b::size(sample_size) <- bin1>>, do: b),
      for(<<b::size(sample_size) <- bin2>>, do: b),
      fn b1, b2 -> (b1 - b2) ** 2 end
    )
    |> then(&:math.sqrt(Enum.sum(&1) / length(&1)))
  end

  @spec get_source_spec(String.t(), String.t(), :mp4 | :hls) :: Membrane.ChildrenSpec.t()
  defp get_source_spec(subject, reference, format) do
    case format do
      :mp4 ->
        [
          child(%Membrane.File.Source{location: subject, seekable?: true})
          |> child(:sub_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true}),
          child(%Membrane.File.Source{location: reference, seekable?: true})
          |> child(:ref_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
        ]

      :hls ->
        [
          child(:sub_demuxer, %Membrane.HTTPAdaptiveStream.Source{directory: subject}),
          child(:ref_demuxer, %Membrane.HTTPAdaptiveStream.Source{directory: reference})
        ]
    end
  end

  defp get_h26x_parser_and_decoder(h26x) when h26x in [Membrane.H264, Membrane.H265] do
    parser = h26x |> Module.concat(Parser) |> struct!(output_stream_structure: :annexb)
    decoder = h26x |> Module.concat(FFmpeg.Decoder)
    {parser, decoder}
  end
end
