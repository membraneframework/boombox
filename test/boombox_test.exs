defmodule BoomboxTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import AsyncTest

  require Membrane.Pad, as: Pad
  require Logger

  alias Membrane.Testing
  alias Support.Compare

  @bbb_mp4_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s.mp4"
  @bbb_mp4 "test/fixtures/bun10s.mp4"
  @bbb_mp4_a "test/fixtures/bun10s_a.mp4"
  @bbb_mp4_v "test/fixtures/bun10s_v.mp4"
  @bbb_mp4_h265 "test/fixtures/bun10s_h265.mp4"

  @moduletag :tmp_dir

  [
    file_file_mp4:
      Macro.escape({
        [@bbb_mp4, "output.mp4"],
        "ref_bun10s_aac.mp4",
        []
      }),
    file_h265_file_mp4:
      Macro.escape({
        [@bbb_mp4_h265, "output.mp4"],
        "ref_bun10s_h265.mp4",
        []
      }),
    file_file_mp4_audio:
      Macro.escape({
        [@bbb_mp4_a, "output.mp4"],
        "ref_bun10s_aac.mp4",
        [kinds: [:audio]]
      }),
    file_file_mp4_video:
      Macro.escape({
        [@bbb_mp4_v, "output.mp4"],
        "ref_bun10s_aac.mp4",
        [kinds: [:video]]
      }),
    http_file_mp4:
      Macro.escape({
        [@bbb_mp4_url, "output.mp4"],
        "ref_bun10s_aac.mp4",
        []
      }),
    file_file_file_mp4:
      Macro.escape({
        [@bbb_mp4, "mid_output.mp4", "output.mp4"],
        "ref_bun10s_aac.mp4",
        []
      }),
    file_webrtc:
      Macro.escape({
        [
          @bbb_mp4,
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        []
      }),
    file_whip:
      Macro.escape({
        [
          @bbb_mp4,
          {:async, {:whip, quote(do: get_free_local_address())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        []
      }),
    http_webrtc:
      Macro.escape({
        [
          @bbb_mp4_url,
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        []
      }),
    webrtc_audio:
      Macro.escape({
        [
          @bbb_mp4_a,
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        [kinds: [:audio]]
      }),
    webrtc_video:
      Macro.escape({
        [
          @bbb_mp4_v,
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        [kinds: [:video]]
      }),
    webrtc_webrtc:
      Macro.escape({
        [
          @bbb_mp4,
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          {:async, {:webrtc, quote(do: Membrane.WebRTC.Signaling.new())}},
          "output.mp4"
        ],
        "ref_bun10s_opus_aac.mp4",
        []
      })
  ]
  |> Enum.each(fn {tag, test_spec} ->
    @tag tag
    async_test "#{tag}", %{tmp_dir: tmp_dir} do
      {endpoints, fixture, compare_opts} = unquote(test_spec)

      endpoints = endpoints |> Enum.map(&Code.eval_quoted/1) |> preprocess_paths(tmp_dir)

      async_boomboxes =
        endpoints
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.flat_map(fn
          [input, {:async, output}] ->
            async_boombox = Boombox.async(input: get_input(input), output: output)
            [async_boombox]

          [input, output] ->
            Boombox.run(input: get_input(input), output: output)
            []
        end)

      Task.await_many(async_boomboxes)

      List.last(endpoints)
      |> Compare.compare("test/fixtures/#{fixture}", [{:tmp_dir, tmp_dir} | compare_opts])
    end
  end)

  defp preprocess_paths([first | rest], tmp_dir) do
    rest =
      rest
      |> Enum.map(
        &if is_binary(&1),
          do: Path.join(tmp_dir, &1),
          else: &1
      )

    [first | rest]
  end

  defp get_input({:async, input}), do: input
  defp get_input(input), do: input

  # defp preprocess({:asnyc, endpoint}, _tmp_dir), do: endpoint
  # defp preprocess(endpoint, tmp_dir) when is_binary(endpoint), do: Path.join(tmp_dir, endpoint)
  # defp preprocess(endpoint, _tmp_dir), do: endpoint

  # defp get_endpoint({:async, endpoint}), do: endpoint
  # defp get_endpoint(endpoint), do: endpoint

  defp reduce_test([{:async, output} | next], input, fixture, opts) do
    t = Boombox.async(input: input, output: output)

    reduce_test(
      next,
      output,
      fixture,
      Keyword.put(opts, :async, [t | Keyword.get(opts, :async, [])])
    )
  end

  defp reduce_test([output | next], input, fixture, opts) do
    output_path = Path.join(opts[:tmp_dir], output)
    Boombox.run(input: input, output: output_path)
    reduce_test(next, output_path, fixture, opts)
  end

  defp reduce_test([], input, fixture, opts) do
    Task.await_many(Keyword.get(opts, :async, []))
    Compare.compare(input, "test/fixtures/#{fixture}", opts)
  end

  defp get_free_local_address() do
    "http://127.0.0.1:#{get_free_port()}"
  end

  defp get_free_port() do
    {:ok, s} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(s)
    :ok = :gen_tcp.close(s)
    port
  end

  @tag :rtmp
  async_test "rtmp -> mp4", %{tmp_dir: tmp} do
    output = Path.join(tmp, "output.mp4")
    port = get_free_port()
    url = "rtmp://localhost:#{port}/app/stream_key"
    t = Boombox.async(input: url, output: output)

    p = send_rtmp(url)
    Task.await(t, 30_000)
    Testing.Pipeline.terminate(p)
    Compare.compare(output, "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :rtmp_external_server
  async_test "rtmp client_ref -> mp4", %{tmp_dir: tmp} do
    output = Path.join(tmp, "output.mp4")
    port = get_free_port()
    url = "rtmp://localhost:#{port}/app/stream_key"
    {use_ssl?, port, app, stream_key} = Membrane.RTMPServer.parse_url(url)

    parent_process_pid = self()

    handle_new_client = fn client_ref, app, stream_key ->
      send(parent_process_pid, {:client_ref, client_ref, app, stream_key})
      Membrane.RTMP.Source.ClientHandlerImpl
    end

    {:ok, server} =
      Membrane.RTMPServer.start_link(
        port: port,
        use_ssl?: use_ssl?,
        handle_new_client: handle_new_client,
        client_timeout: Membrane.Time.seconds(5)
      )

    p = send_rtmp(url)

    {:ok, client_ref} =
      receive do
        {:client_ref, client_ref, ^app, ^stream_key} ->
          {:ok, client_ref}
      after
        5_000 -> :timeout
      end

    Boombox.run(input: {:rtmp, client_ref}, output: output)
    Testing.Pipeline.terminate(p)
    Process.exit(server, :normal)
    Compare.compare(output, "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :rtmp_webrtc
  async_test "rtmp -> webrtc -> mp4", %{tmp_dir: tmp} do
    output = Path.join(tmp, "output.mp4")
    port = get_free_port()
    url = "rtmp://localhost:#{port}/app/stream_key"
    signaling = Membrane.WebRTC.Signaling.new()

    t1 =
      Boombox.async(input: url, output: {:webrtc, signaling})

    t2 =
      Boombox.async(input: {:webrtc, signaling}, output: output)

    p = send_rtmp(url)
    Task.await(t1, 30_000)
    Task.await(t2)
    Testing.Pipeline.terminate(p)
    Compare.compare(output, "test/fixtures/ref_bun10s_opus_aac.mp4")
  end

  @tag :file_hls
  async_test "mp4 file -> hls", %{tmp_dir: tmp} do
    manifest_filename = Path.join(tmp, "index.m3u8")
    Boombox.run(input: @bbb_mp4, output: manifest_filename)
    ref_path = "test/fixtures/ref_bun10s_aac_hls"
    Compare.compare(tmp, ref_path, format: :hls)

    Enum.zip(
      Path.join(tmp, "*.mp4") |> Path.wildcard(),
      Path.join(ref_path, "*.mp4") |> Path.wildcard()
    )
    |> Enum.each(fn {output_file, ref_file} ->
      assert File.read!(output_file) == File.read!(ref_file)
    end)
  end

  @tag :rtmp_hls
  async_test "rtmp -> hls", %{tmp_dir: tmp} do
    manifest_filename = Path.join(tmp, "index.m3u8")
    port = get_free_port()
    url = "rtmp://localhost:#{port}/app/stream_key"
    ref_path = "test/fixtures/ref_bun10s_aac_hls"

    t = Boombox.async(input: url, output: manifest_filename)

    p = send_rtmp(url)
    Task.await(t, 30_000)
    Testing.Pipeline.terminate(p)
    Compare.compare(tmp, ref_path, format: :hls)

    Enum.zip(
      Path.join(tmp, "*.mp4") |> Path.wildcard(),
      Path.join(ref_path, "*.mp4") |> Path.wildcard()
    )
    |> Enum.each(fn {output_file, ref_file} ->
      assert File.read!(output_file) == File.read!(ref_file)
    end)
  end

  @tag :flaky
  @tag :rtsp_mp4
  async_test "rtsp -> mp4", %{tmp_dir: tmp} do
    rtsp_port = get_free_port()
    output = Path.join(tmp, "output.mp4")

    Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)

    Boombox.run(input: "rtsp://localhost:#{rtsp_port}/", output: output)
    Compare.compare(output, "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :rtsp_hls
  async_test "rtsp -> hls", %{tmp_dir: tmp} do
    rtsp_port = get_free_port()
    Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)
    manifest_filename = Path.join(tmp, "index.m3u8")
    Boombox.run(input: "rtsp://localhost:#{rtsp_port}/", output: manifest_filename)
    Compare.compare(tmp, "test/fixtures/ref_bun10s_aac_hls", format: :hls)
  end

  @tag :rtsp_webrtc_mp4
  async_test "rtsp -> webrtc -> mp4", %{tmp_dir: tmp} do
    rtsp_port = get_free_port()
    output = Path.join(tmp, "output.mp4")
    signaling = Membrane.WebRTC.Signaling.new()

    Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)

    t =
      Boombox.async(
        input: "rtsp://localhost:#{rtsp_port}/",
        output: {:webrtc, signaling}
      )

    Boombox.run(input: {:webrtc, signaling}, output: output)
    Task.await(t)
    Compare.compare(output, "test/fixtures/ref_bun10s_opus_aac.mp4")
  end

  @tag :mp4_elixir_rotate_mp4
  async_test "mp4 -> elixir rotate -> mp4", %{tmp_dir: tmp} do
    Boombox.run(input: @bbb_mp4, output: {:stream, video: :image, audio: :binary})
    |> Stream.map(fn
      %Boombox.Packet{kind: :video, payload: image} = packet ->
        image = Image.rotate!(image, 180)
        %Boombox.Packet{packet | payload: image}

      %Boombox.Packet{kind: :audio} = packet ->
        packet
    end)
    |> Boombox.run(input: {:stream, video: :image, audio: :binary}, output: "#{tmp}/output.mp4")

    Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun_rotated.mp4")
  end

  @tag :bouncing_bubble_webrtc_mp4
  async_test "bouncing bubble -> webrtc -> mp4", %{tmp_dir: tmp} do
    signaling = Membrane.WebRTC.Signaling.new()

    Task.async(fn ->
      overlay =
        Image.new!(_w = 100, _h = 100, color: [0, 0, 0, 0])
        |> Image.Draw.circle!(_x = 50, _y = 50, _r = 48, color: :blue)

      bg = Image.new!(640, 480, color: :light_gray)
      max_x = Image.width(bg) - Image.width(overlay)
      max_y = Image.height(bg) - Image.height(overlay)
      fps = 60

      Stream.iterate({_x = 300, _y = 0, _dx = 1, _dy = 2, _pts = 0}, fn {x, y, dx, dy, pts} ->
        dx = if (x + dx) in 0..max_x, do: dx, else: -dx
        dy = if (y + dy) in 0..max_y, do: dy, else: -dy
        pts = pts + div(Membrane.Time.seconds(1), fps)
        {x + dx, y + dy, dx, dy, pts}
      end)
      |> Stream.map(fn {x, y, _dx, _dy, pts} ->
        img = Image.compose!(bg, overlay, x: x, y: y)
        %Boombox.Packet{kind: :video, payload: img, pts: pts}
      end)
      |> Stream.take(5 * fps)
      |> Boombox.run(
        input: {:stream, video: :image, audio: false},
        output: {:webrtc, signaling}
      )
    end)

    output = Path.join(tmp, "output.mp4")
    Boombox.run(input: {:webrtc, signaling}, output: output)
    Compare.compare(output, "test/fixtures/ref_bouncing_bubble.mp4", kinds: [:video])
  end

  @tag :mp4_resampled_pcm
  async_test "mp4 -> resampled PCM" do
    pcm =
      Boombox.run(
        input: @bbb_mp4,
        output:
          {:stream,
           video: false,
           audio: :binary,
           audio_rate: 16_000,
           audio_channels: 1,
           audio_format: :s16le}
      )
      |> Enum.map_join(& &1.payload)

    ref = File.read!("test/fixtures/ref_bun.pcm")
    assert Compare.samples_min_squared_error(ref, pcm, 16) < 500
  end

  @tag :rtp2
  async_test "mp4 -> rtp -> rtp -> hls", %{tmp_dir: tmp} do
    manifest_filename = Path.join(tmp, "index.m3u8")
    ref_path = "test/fixtures/ref_bun10s_aac_hls"

    t =
      Boombox.async(
        input:
          {:rtp,
           port: 50_001,
           audio_encoding: :AAC,
           aac_bitrate_mode: :hbr,
           audio_specific_config: Base.decode16!("1210"),
           video_encoding: :H264},
        output: manifest_filename
      )

    Boombox.run(
      input: @bbb_mp4,
      output:
        {:rtp,
         port: 50_001,
         address: {127, 0, 0, 1},
         audio_encoding: :AAC,
         aac_bitrate_mode: :hbr,
         video_encoding: :H264}
    )

    Task.shutdown(t)
    Compare.compare(tmp, ref_path, format: :hls, subject_terminated_early: true)
  end

  defp send_rtmp(url) do
    p =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(%Membrane.File.Source{location: @bbb_mp4, seekable?: true})
          |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
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
          output_config: :esds,
          audio_specific_config: nil
        })
        |> via_in(Pad.ref(:audio, 0))
        |> get_child(:rtmp_sink),
        child(:rtmp_sink, %Membrane.RTMP.Sink{rtmp_url: url})
      ]
    )

    p
  end
end
