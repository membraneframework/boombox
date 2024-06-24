defmodule BoomboxTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Support.Async

  require Membrane.Pad, as: Pad
  require Logger

  alias Membrane.Testing
  alias Support.Compare

  @bbb_mp4 "test/fixtures/bun10s.mp4"
  @bbb_mp4_a "test/fixtures/bun10s_a.mp4"
  @bbb_mp4_v "test/fixtures/bun10s_v.mp4"

  @moduletag :tmp_dir

  @tag :mp4
  async_test "mp4 -> mp4", %{tmp_dir: tmp} do
    Boombox.run(input: @bbb_mp4, output: "#{tmp}/output.mp4")
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :mp4_audio
  async_test "mp4 -> mp4 audio", %{tmp_dir: tmp} do
    Boombox.run(input: @bbb_mp4_a, output: "#{tmp}/output.mp4")
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_aac.mp4", :audio)
  end

  @tag :mp4_video
  async_test "mp4 -> mp4 audio", %{tmp_dir: tmp} do
    Boombox.run(input: @bbb_mp4_v, output: "#{tmp}/output.mp4")
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_aac.mp4", :video)
  end

  @tag :webrtc
  async_test "mp4 -> webrtc -> mp4", %{tmp_dir: tmp} do
    signaling = Membrane.WebRTC.SignalingChannel.new()
    t = Task.async(fn -> Boombox.run(input: @bbb_mp4, output: [:webrtc, signaling]) end)
    Boombox.run(input: [:webrtc, signaling], output: "#{tmp}/output.mp4")
    Task.await(t)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_opus_aac.mp4")
  end

  @tag :webrtc_audio
  async_test "mp4 -> webrtc -> mp4 audio", %{tmp_dir: tmp} do
    signaling = Membrane.WebRTC.SignalingChannel.new()

    t =
      Task.async(fn -> Boombox.run(input: @bbb_mp4_a, output: [:webrtc, signaling]) end)

    Boombox.run(input: [:webrtc, signaling], output: "#{tmp}/output.mp4")
    Task.await(t)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_opus_aac.mp4", :audio)
  end

  @tag :webrtc_video
  async_test "mp4 -> webrtc -> mp4 video", %{tmp_dir: tmp} do
    signaling = Membrane.WebRTC.SignalingChannel.new()

    t =
      Task.async(fn -> Boombox.run(input: @bbb_mp4_v, output: [:webrtc, signaling]) end)

    Boombox.run(input: [:webrtc, signaling], output: "#{tmp}/output.mp4")
    Task.await(t)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_opus_aac.mp4", :video)
  end

  @tag :webrtc2
  async_test "mp4 -> webrtc -> webrtc -> mp4", %{tmp_dir: tmp} do
    signaling1 = Membrane.WebRTC.SignalingChannel.new()
    signaling2 = Membrane.WebRTC.SignalingChannel.new()

    t1 =
      Task.async(fn -> Boombox.run(input: @bbb_mp4, output: [:webrtc, signaling1]) end)

    t2 =
      Task.async(fn ->
        Boombox.run(input: [:webrtc, signaling1], output: [:webrtc, signaling2])
      end)

    Boombox.run(input: [:webrtc, signaling2], output: "#{tmp}/output.mp4")
    Task.await(t1)
    Task.await(t2)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_opus2_aac.mp4")
  end

  @tag :rtmp
  async_test "rtmp -> mp4", %{tmp_dir: tmp} do
    url = "rtmp://localhost:5000"
    t = Task.async(fn -> Boombox.run(input: url, output: "#{tmp}/output.mp4") end)

    # Wait for boombox to be ready
    Process.sleep(200)
    p = send_rtmp(url)
    Task.await(t, 30_000)
    Testing.Pipeline.terminate(p)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :rtmp_webrtc
  async_test "rtmp -> webrtc -> mp4", %{tmp_dir: tmp} do
    url = "rtmp://localhost:5002"
    signaling = Membrane.WebRTC.SignalingChannel.new()

    t1 =
      Task.async(fn -> Boombox.run(input: url, output: [:webrtc, signaling]) end)

    t2 =
      Task.async(fn -> Boombox.run(input: [:webrtc, signaling], output: "#{tmp}/output.mp4") end)

    # Wait for boombox to be ready
    Process.sleep(200)
    p = send_rtmp(url)
    Task.await(t1, 30_000)
    Task.await(t2)
    Testing.Pipeline.terminate(p)
    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun10s_opus_aac.mp4")
  end

  defp send_rtmp(url) do
    p = Testing.Pipeline.start_link_supervised!()

    Testing.Pipeline.execute_actions(p,
      spec: [
        child(%Membrane.File.Source{location: @bbb_mp4, seekable?: true})
        |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
      ]
    )

    assert_pipeline_notified(p, :demuxer, {:new_tracks, tracks})

    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    Testing.Pipeline.execute_actions(p,
      spec: [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, video_id))
        |> child(Membrane.Realtimer)
        |> child(:video_parser, %Membrane.H264.Parser{
          output_stream_structure: :avc1
        })
        |> via_in(Pad.ref(:video, 0))
        |> get_child(:rtmp_sink),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, audio_id))
        |> child(Membrane.Realtimer)
        |> child(:audio_parser, %Membrane.AAC.Parser{
          out_encapsulation: :none,
          output_config: :esds
        })
        |> via_in(Pad.ref(:audio, 0))
        |> get_child(:rtmp_sink),
        child(:rtmp_sink, %Membrane.RTMP.Sink{rtmp_url: url})
      ]
    )

    p
  end
end
