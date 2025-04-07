defmodule Boombox.InternalBinTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Logger

  alias Membrane.{
    AAC,
    H264,
    Opus,
    RawAudio,
    RawVideo,
    Testing,
    Transcoder,
    VP8
  }

  alias Support.Compare

  @bbb_mp4 "test/fixtures/bun10s.mp4"

  @video_formats Macro.escape([
                   {H264, :avc3, :au},
                   {H264, :annexb, :nalu},
                   RawVideo,
                   VP8,
                   nil
                 ])

  @audio_formats Macro.escape([AAC, Opus, RawAudio, nil])

  defmodule Format do
    @spec to_string(any()) :: String.t()
    def to_string(nil), do: "absent"
    def to_string(format), do: inspect(format)
  end

  for video_format <- @video_formats, audio_format <- @audio_formats do
    if video_format != nil or audio_format != nil do
      @tag :tmp_dir
      test "Boombox bin with input pad when video is #{Format.to_string(video_format)} and audio is #{Format.to_string(audio_format)}",
           %{tmp_dir: tmp_dir} do
        video_format =
          with {H264, stream_structure, alignment} <- unquote(video_format) do
            %H264{stream_structure: stream_structure, alignment: alignment}
          end

        do_test(video_format, unquote(audio_format), tmp_dir)
      end
    end
  end

  defp do_test(video_format, audio_format, tmp_dir) do
    out_file = Path.join(tmp_dir, "out.mp4")

    spec = [
      child(:boombox, %Boombox{output: out_file}),
      spec_branch(:video, video_format),
      spec_branch(:audio, audio_format)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :boombox, :processing_finished)
    Testing.Pipeline.terminate(pipeline)

    tracks_number = [video_format, audio_format] |> Enum.count(&(&1 != nil))

    if video_format != nil do
      Compare.compare(out_file, "test/fixtures/ref_bun10s_aac.mp4",
        kinds: [:video],
        expected_subject_tracks_number: tracks_number
      )
    end

    if audio_format != nil do
      Compare.compare(out_file, audio_fixture(audio_format),
        kinds: [:audio],
        audio_error_bounadry: 40_000,
        expected_subject_tracks_number: tracks_number
      )
    end
  end

  defp audio_fixture(Opus), do: "test/fixtures/ref_bun10s_opus_aac.mp4"
  defp audio_fixture(_format), do: "test/fixtures/ref_bun10s_aac.mp4"

  defp spec_branch(_kind, nil), do: []

  defp spec_branch(kind, transcoding_format) do
    {opposite_kind, boombox_pad} =
      case kind do
        :audio -> {:video, :audio_input}
        :video -> {:audio, :video_input}
      end

    [
      child(%Membrane.File.Source{location: @bbb_mp4})
      |> child({:mp4_demuxer, kind}, Membrane.MP4.Demuxer.ISOM)
      |> via_out(:output, options: [kind: kind])
      |> child(%Transcoder{output_stream_format: transcoding_format})
      |> via_in(boombox_pad)
      |> get_child(:boombox),
      get_child({:mp4_demuxer, kind})
      |> via_out(:output, options: [kind: opposite_kind])
      |> child(Membrane.Debug.Sink)
    ]
  end

  test "Boombox bin raises when it has input pad linked and `:input` option set at the same time" do
    spec =
      child(Testing.Source)
      |> via_in(:audio_input)
      |> child(%Boombox{
        input: {:webrtc, "ws://localhost:5432"},
        output: {:webrtc, "ws://localhost:5433"}
      })

    {:ok, supervisor, _pipeline} = Testing.Pipeline.start(spec: spec)
    ref = Process.monitor(supervisor)
    assert_receive {:DOWN, ^ref, :process, _supervisor, _reason}
  end
end
