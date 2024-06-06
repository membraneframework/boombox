defmodule Support.Compare do
  alias Membrane.Testing

  require Membrane.Pad, as: Pad

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  defmodule GetBuffers do
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

  def compare(subject, reference) do
    p = Testing.Pipeline.start_link_supervised!()

    Testing.Pipeline.execute_actions(p,
      spec: [
        child(%Membrane.File.Source{location: subject, seekable?: true})
        |> child(:sub_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true}),
        child(%Membrane.File.Source{location: reference, seekable?: true})
        |> child(:ref_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
      ]
    )

    assert_pipeline_notified(p, :ref_demuxer, {:new_tracks, tracks})

    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    spec =
      [
        get_child(:ref_demuxer)
        |> via_out(Pad.ref(:output, video_id))
        |> child(:ref_video_bufs, GetBuffers),
        get_child(:ref_demuxer)
        |> via_out(Pad.ref(:output, audio_id))
        |> child(:ref_aac, Membrane.AAC.Parser)
        |> child(Membrane.AAC.FDK.Decoder)
        |> child(:ref_audio_bufs, GetBuffers)
      ]

    assert_pipeline_notified(p, :sub_demuxer, {:new_tracks, tracks})

    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    spec =
      spec ++
        [
          get_child(:sub_demuxer)
          |> via_out(Pad.ref(:output, video_id))
          |> child(:sub_video_bufs, GetBuffers),
          get_child(:sub_demuxer)
          |> via_out(Pad.ref(:output, audio_id))
          |> child(Membrane.AAC.Parser)
          |> child(Membrane.AAC.FDK.Decoder)
          |> child(:sub_audio_bufs, GetBuffers)
        ]

    Testing.Pipeline.execute_actions(p, spec: spec)

    assert_pipeline_notified(p, :sub_video_bufs, {:buffers, sub_video_bufs})
    assert_pipeline_notified(p, :ref_video_bufs, {:buffers, ref_video_bufs})
    assert_pipeline_notified(p, :sub_audio_bufs, {:buffers, sub_audio_bufs})
    assert_pipeline_notified(p, :ref_audio_bufs, {:buffers, ref_audio_bufs})

    assert length(ref_video_bufs) == length(sub_video_bufs)

    Enum.zip(sub_video_bufs, ref_video_bufs)
    |> Enum.each(fn {sub, ref} ->
      assert sub.payload == ref.payload
    end)

    assert length(ref_audio_bufs) == length(sub_audio_bufs)

    Enum.zip(sub_audio_bufs, ref_audio_bufs)
    |> Enum.each(fn {sub, ref} ->
      assert sub.payload == ref.payload
    end)

    Testing.Pipeline.terminate(p)
  end
end
