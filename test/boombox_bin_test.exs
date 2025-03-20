defmodule Boombox.BinTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Support.Async

  @bbb_mp4 "test/fixtures/bun10s.mp4"

  alias Membrane.{
    AAC,
    H264,
    Opus,
    RawAudio,
    RawVideo,
    RemoteStream,
    Transcoder,
    VP8
  }

  @video_formats [
    %H264{stream_structure: :avc3, alignment: :au},
    %H264{stream_structure: :avc1, alignment: :nalu},
    RawVideo,
    VP8
  ]

  @audio_formats [AAC, Opus, RawAudio]

  defp do_test(audio_format, video_format, tmp_dir) do
    # out_path = Path.join(tmp_dir, "out.mp4")

    # todo: parse boombox bin opts as in Boombox Elixir command

    spec = [
      child(%Membrane.File.Source{location: @bbb_mp4})
      |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(:output, options: [kind: :video])
      |> child( %Transcoder{output_stream_format: video_format})
      |> via_in(:video_input)
      |> child(:boombox, %Boombox.Bin{output: {:mp4, "out.mp4", []}}),
      get_child(:mp4_demuxer)
      |> via_out(:output, options: [kind: :audio])
      |> child(%Transcoder{output_stream_format: audio_format})
      |> via_in(:audio_input)
      |> get_child(:boombox)
    ]
  end
end
