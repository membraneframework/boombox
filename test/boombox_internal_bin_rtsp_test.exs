defmodule Boombox.InternalBin.RTSPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Boombox.InternalBin.{Ready, RTSP, State, Wait}

  @uri URI.parse("rtsp://example.org/stream")

  describe "create_input/2" do
    test "defaults to video + audio when no options are given" do
      assert %Wait{actions: [spec: spec]} = RTSP.create_input(@uri)
      assert allowed_media_types(spec) == [:video, :audio]
    end

    test "threads allowed_media_types through to the RTSP source" do
      assert %Wait{actions: [spec: spec]} =
               RTSP.create_input(@uri, allowed_media_types: [:video])

      assert allowed_media_types(spec) == [:video]
    end

    test "accepts an empty keyword list" do
      assert %Wait{actions: [spec: spec]} = RTSP.create_input(@uri, [])
      assert allowed_media_types(spec) == [:video, :audio]
    end
  end

  describe "handle_set_up_tracks/2" do
    test "routes H265 track to video track_builders with VPS/SPS/PPS from fmtp" do
      vpss = [<<0x40, 0x01>>]
      spss = [<<0x42, 0x01>>]
      ppss = [<<0x44, 0x01>>]

      track = %{
        type: :video,
        control_path: "track1",
        rtpmap: %{encoding: "H265"},
        fmtp: %{sprop_vps: vpss, sprop_sps: spss, sprop_pps: ppss}
      }

      s = state()

      assert {%Ready{actions: [spec: spec], track_builders: %{video: video_spec}}, ^s} =
               RTSP.handle_set_up_tracks([track], s)

      assert {:rtsp_in_h265_parser, parser, _opts} =
               find_child(video_spec, :rtsp_in_h265_parser)

      assert %Membrane.H265.Parser{vpss: ^vpss, spss: ^spss, ppss: ^ppss} = parser
      assert spec == []
    end

    test "handles nil fmtp for an H265 track without raising" do
      track = %{
        type: :video,
        control_path: "track1",
        rtpmap: %{encoding: "H265"},
        fmtp: nil
      }

      assert {%Ready{track_builders: %{video: video_spec}}, _state} =
               RTSP.handle_set_up_tracks([track], state())

      assert {:rtsp_in_h265_parser, parser, _opts} =
               find_child(video_spec, :rtsp_in_h265_parser)

      assert %Membrane.H265.Parser{vpss: [], spss: [], ppss: []} = parser
    end

    test "handles nil sprop_* fields inside fmtp by falling back to empty lists" do
      track = %{
        type: :video,
        control_path: "track1",
        rtpmap: %{encoding: "H265"},
        fmtp: %{sprop_vps: nil, sprop_sps: nil, sprop_pps: nil}
      }

      assert {%Ready{track_builders: %{video: video_spec}}, _state} =
               RTSP.handle_set_up_tracks([track], state())

      assert {:rtsp_in_h265_parser, parser, _opts} =
               find_child(video_spec, :rtsp_in_h265_parser)

      assert %Membrane.H265.Parser{vpss: [], spss: [], ppss: []} = parser
    end

    test "still raises for truly unsupported encodings" do
      track = %{
        type: :video,
        control_path: "track1",
        rtpmap: %{encoding: "MPEG4"},
        fmtp: nil
      }

      assert_raise RuntimeError, ~r/Received unsupported encoding with RTSP.*MPEG4/, fn ->
        RTSP.handle_set_up_tracks([track], state())
      end
    end

    test "drops a duplicate H265 track with a warning" do
      track1 = %{
        type: :video,
        control_path: "track1",
        rtpmap: %{encoding: "H265"},
        fmtp: nil
      }

      track2 = %{track1 | control_path: "track2"}

      {result, log} =
        with_log(fn -> RTSP.handle_set_up_tracks([track1, track2], state()) end)

      assert {%Ready{actions: [spec: drop_spec], track_builders: %{video: _video}}, _state} =
               result

      assert log =~ "another track"
      assert log =~ "dropping the track"

      assert {{:rtsp_in_fake_sink, "track2"}, Membrane.Fake.Sink, _opts} =
               find_child(drop_spec, {:rtsp_in_fake_sink, "track2"})
    end
  end

  defp state(),
    do: %State{status: :input_ready, input: {:rtsp, "rtsp://example"}, output: :webrtc}

  defp allowed_media_types(%Membrane.ChildrenSpec.Builder{} = spec) do
    [{:rtsp_source, %Membrane.RTSP.Source{allowed_media_types: types}, _opts}] = spec.children
    types
  end

  defp find_child(spec, name) do
    Enum.find(collect_children(spec), fn
      {^name, _mod_or_struct, _opts} -> true
      _other -> false
    end)
  end

  defp collect_children(%Membrane.ChildrenSpec.Builder{children: children}), do: children
  defp collect_children([head | tail]), do: collect_children(head) ++ collect_children(tail)
  defp collect_children([]), do: []
end
