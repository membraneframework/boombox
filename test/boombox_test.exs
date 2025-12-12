defmodule BoomboxTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import AsyncTest

  require Membrane.Pad, as: Pad
  require Logger
  require Boombox.InternalBin.StorageEndpoints, as: StorageEndpoints

  alias Membrane.Testing
  alias Support.Compare

  @bbb_mp4_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s.mp4"
  @bbb_mp4 "test/fixtures/bun10s.mp4"
  @bbb_mp4_a "test/fixtures/bun10s_a.mp4"
  @bbb_mp4_v "test/fixtures/bun10s_v.mp4"
  @bbb_mp4_h265 "test/fixtures/bun10s_h265.mp4"
  @bbb_hls_fmp4_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s_hls_fmp4/index.m3u8"
  @bbb_hls_mpegts_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun15s_hls_mpegts/index.m3u8"

  @moduletag :tmp_dir

  [
    file_file_mp4: {[@bbb_mp4, "output.mp4"], "ref_bun10s_aac.mp4", []},
    file_h265_file_mp4: {[@bbb_mp4_h265, "output.mp4"], "ref_bun10s_h265.mp4", []},
    file_file_mp4_audio: {[@bbb_mp4_a, "output.mp4"], "ref_bun10s_aac.mp4", kinds: [:audio]},
    file_file_mp4_video: {[@bbb_mp4_v, "output.mp4"], "ref_bun10s_aac.mp4", kinds: [:video]},
    http_file_mp4: {[@bbb_mp4_url, "output.mp4"], "ref_bun10s_aac.mp4", []},
    file_file_file_mp4: {[@bbb_mp4, "mid_output.mp4", "output.mp4"], "ref_bun10s_aac.mp4", []},
    file_webrtc: {
      quote do
        [@bbb_mp4, {:webrtc, Membrane.WebRTC.Signaling.new()}, "output.mp4"]
      end,
      "ref_bun10s_opus_aac.mp4",
      []
    },
    file_whip:
      {quote do
         [@bbb_mp4, {:whip, get_free_local_address(:http)}, "output.mp4"]
       end, "ref_bun10s_opus_aac.mp4", []},
    http_webrtc:
      {quote do
         [
           @bbb_mp4_url,
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "ref_bun10s_opus_aac.mp4", []},
    webrtc_audio:
      {quote do
         [
           @bbb_mp4_a,
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "ref_bun10s_opus_aac.mp4", [kinds: [:audio]]},
    webrtc_video:
      {quote do
         [
           @bbb_mp4_v,
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "ref_bun10s_opus_aac.mp4", [kinds: [:video]]},
    webrtc_webrtc:
      {quote do
         [
           @bbb_mp4,
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "ref_bun10s_opus_aac.mp4", []},
    hls_fmp4_mp4: {[@bbb_hls_fmp4_url, "output.mp4"], "bun_hls.mp4", []},
    hls_fmp4_webrtc:
      {quote do
         [
           @bbb_hls_fmp4_url,
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "bun_hls_webrtc.mp4", []},
    hls_mpegts_mp4: {[@bbb_hls_mpegts_url, "output.mp4"], "bun_hls_mpegts.mp4", []},
    # we need `subject_terminated_early: true` as the `srt_send()` function from SRT API (used in
    # `SRT Sink`) does not immediately write a frame, but instead it puts the frame in a buffer,
    # and SRT API does not support flushing of that buffer
    mp4_srt_mp4:
      {quote do
         [
           @bbb_mp4,
           {:srt, get_free_local_address(:srt)},
           "output.mp4"
         ]
       end, "bun10s.mp4", [subject_terminated_early: true]},
    mp4_a_srt_mp4:
      {quote do
         [
           @bbb_mp4_a,
           {:srt, get_free_local_address(:srt)},
           "output.mp4"
         ]
       end, "bun10s.mp4", [kinds: [:audio], subject_terminated_early: true]},
    mp4_v_srt_mp4:
      {quote do
         [
           @bbb_mp4_v,
           {:srt, get_free_local_address(:srt)},
           "output.mp4"
         ]
       end, "bun10s.mp4", [kinds: [:video], subject_terminated_early: true]},
    mp4_srt_mp4_with_auth:
      {quote do
         [
           @bbb_mp4,
           {:srt, get_free_local_address(:srt),
            [stream_id: "some_stream_id", password: "some_password"]},
           "output.mp4"
         ]
       end, "bun10s.mp4", [subject_terminated_early: true]},
    mp4_a_srt_mp4_with_auth:
      {quote do
         [
           @bbb_mp4_a,
           {:srt, get_free_local_address(:srt),
            [stream_id: "some_stream_id", password: "some_password"]},
           "output.mp4"
         ]
       end, "bun10s.mp4", [kinds: [:audio], subject_terminated_early: true]},
    mp4_v_srt_mp4_with_auth:
      {quote do
         [
           @bbb_mp4_v,
           {:srt, get_free_local_address(:srt),
            [stream_id: "some_stream_id", password: "some_password"]},
           "output.mp4"
         ]
       end, "bun10s.mp4", [kinds: [:video], subject_terminated_early: true]},
    live_hls_mp4:
      {quote do
         [@bbb_mp4_url, {:hls, "index.m3u8", mode: :live}, "output.mp4"]
       end, "bun_hls.mp4", []},
    hls_fmp4_live_hls_webrtc_mp4:
      {quote do
         [
           @bbb_hls_fmp4_url,
           {:hls, "index.m3u8", mode: :live},
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "bun_hls_webrtc.mp4", []},
    vod_hls_mp4:
      {quote do
         [@bbb_mp4_url, {:hls, "index.m3u8", mode: :vod}, "output.mp4"]
       end, "bun_hls.mp4", []},
    hls_fmp4_vod_hls_webrtc_mp4:
      {quote do
         [
           @bbb_hls_fmp4_url,
           {:hls, "index.m3u8", mode: :vod},
           {:webrtc, Membrane.WebRTC.Signaling.new()},
           "output.mp4"
         ]
       end, "bun_hls_webrtc.mp4", []}
  ]
  |> Enum.each(fn {tag, {endpoints, fixture, compare_opts}} ->
    @tag tag
    async_test "#{tag}", %{tmp_dir: tmp_dir} do
      endpoints = unquote(endpoints) |> parse_endpoints(tmp_dir)

      endpoints
      |> Enum.chunk_every(2, 1, :discard)
      |> sort_endpoint_pairs()
      |> Enum.flat_map(fn
        [{webrtc, _signaling} = input, output] when webrtc in [:webrtc, :whip] ->
          boombox_task = Boombox.async(input: input, output: output)
          [boombox_task]

        [input, {:hls, playlist, mode: :live} = output] ->
          boombox_task = Boombox.async(input: input, output: output)
          await_until_file_exists!(playlist)
          [boombox_task]

        [{:srt, _url} = input, output] ->
          boombox_task = Boombox.async(input: input, output: output)
          [boombox_task]

        [{:srt, _url, _opts} = input, output] ->
          boombox_task = Boombox.async(input: input, output: output)
          [boombox_task]

        [input, output] ->
          Boombox.run(input: input, output: output)
          []
      end)
      |> Task.await_many(15_000)

      compare_opts = [tmp_dir: tmp_dir] ++ unquote(compare_opts)

      List.last(endpoints)
      |> Compare.compare(
        "test/fixtures/#{unquote(fixture)}",
        compare_opts
      )
    end
  end)

  defp file_endpoint?({endpoint_type, _location})
       when StorageEndpoints.is_storage_endpoint_type(endpoint_type),
       do: true

  defp file_endpoint?({endpoint_type, _location, _opts})
       when StorageEndpoints.is_storage_endpoint_type(endpoint_type),
       do: true

  defp file_endpoint?(uri) when is_binary(uri) do
    URI.parse(uri).scheme in [nil, "http", "https"]
  end

  defp file_endpoint?({uri, _opts}) when is_binary(uri) do
    URI.parse(uri).scheme in [nil, "http", "https"]
  end

  defp file_endpoint?(_other), do: false

  defp hls_endpoint?({:hls, _playlist} = _endpoint), do: true
  defp hls_endpoint?({:hls, _playlist, _opts} = _endpoint), do: true
  defp hls_endpoint?(uri) when is_binary(uri), do: String.ends_with?(uri, ".m3u8")
  defp hls_endpoint?({uri, _opts}) when is_binary(uri), do: String.ends_with?(uri, ".m3u8")
  defp hls_endpoint?(_other), do: false

  defp order_requiring_endpoint?(endpoint),
    do: file_endpoint?(endpoint) or hls_endpoint?(endpoint)

  # This function sorts endpoint pairs in the following manner:
  # * it splits the whole endpoint pairs list into the smallest chunks possible
  #   such that each chunk starts with the file or HLS input and ends with the file
  #   or HLS output
  # * reverses the order of endpoint pairs within each chunk
  # * so that:
  #   - if pair A and pair B are in the same chunk and originally A was before B,
  #     then in the final list B will be before A
  #   - if pair A and pair B are in different chunks and originally A was before B,
  #     then in the final list A will be before B as well
  # It means that all the Boomboxes in each chunk are started in reversed
  # order so we can be sure that e.g. the listening socket of a SRT server
  # is spawned before the SRT client tries to connect to it

  defp sort_endpoint_pairs(endpoint_pairs, to_reverse \\ [])

  defp sort_endpoint_pairs([[input, output] = endpoints_pair | rest], to_reverse) do
    cond do
      order_requiring_endpoint?(input) and order_requiring_endpoint?(output) ->
        [endpoints_pair] ++ sort_endpoint_pairs(rest)

      order_requiring_endpoint?(input) and to_reverse == [] ->
        sort_endpoint_pairs(rest, [endpoints_pair])

      order_requiring_endpoint?(output) ->
        [endpoints_pair | to_reverse] ++ sort_endpoint_pairs(rest)

      true ->
        sort_endpoint_pairs(rest, [endpoints_pair | to_reverse])
    end
  end

  defp sort_endpoint_pairs([], to_reverse) do
    to_reverse
  end

  defp parse_endpoints([head | tail], tmp_dir) do
    modified_tail =
      Enum.map(tail, fn
        endpoint when is_binary(endpoint) -> Path.join(tmp_dir, endpoint)
        {:hls, playlist, opts} -> {:hls, Path.join(tmp_dir, playlist), opts}
        {:srt, uri, opts} -> {:srt, uri <> ":#{get_free_port()}", opts}
        {:srt, uri} -> {:srt, uri <> ":#{get_free_port()}"}
        endpoint -> endpoint
      end)

    [head | modified_tail]
  end

  defp await_until_file_exists!(file, seconds \\ 20) do
    cond do
      File.exists?(file) ->
        :ok

      seconds <= 0 ->
        raise "File #{file} not created within timeout"

      true ->
        Process.sleep(1_000)
        await_until_file_exists!(file, seconds - 1)
    end
  end

  defp get_free_local_address(protocol) do
    "#{protocol}://127.0.0.1:#{get_free_port()}"
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
    assert_hls(tmp, "test/fixtures/ref_bun10s_aac_hls")
  end

  @tag :rtmp_hls
  async_test "rtmp -> hls", %{tmp_dir: tmp} do
    manifest_filename = Path.join(tmp, "index.m3u8")
    port = get_free_port()
    url = "rtmp://localhost:#{port}/app/stream_key"

    t = Boombox.async(input: url, output: manifest_filename)

    p = send_rtmp(url)
    Task.await(t, 30_000)
    Testing.Pipeline.terminate(p)

    assert_hls(tmp, "test/fixtures/ref_bun10s_aac_hls")
  end

  defp assert_hls(out_path, ref_path) do
    Compare.compare(out_path, ref_path, format: :hls)

    Enum.zip(
      Path.join(out_path, "*.mp4") |> Path.wildcard(),
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

    {:ok, server} = Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)
    on_exit(fn -> Process.exit(server, :normal) end)

    Boombox.run(input: "rtsp://localhost:#{rtsp_port}/", output: output)
    Compare.compare(output, "test/fixtures/ref_bun10s_aac.mp4")
  end

  @tag :rtsp_hls
  async_test "rtsp -> hls", %{tmp_dir: tmp} do
    rtsp_port = get_free_port()
    {:ok, server} = Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)
    on_exit(fn -> Process.exit(server, :normal) end)

    manifest_filename = Path.join(tmp, "index.m3u8")
    Boombox.run(input: "rtsp://localhost:#{rtsp_port}/", output: manifest_filename)
    Compare.compare(tmp, "test/fixtures/ref_bun10s_aac_hls", format: :hls)
  end

  @tag :rtsp_webrtc_mp4
  async_test "rtsp -> webrtc -> mp4", %{tmp_dir: tmp} do
    rtsp_port = get_free_port()
    output = Path.join(tmp, "output.mp4")
    signaling = Membrane.WebRTC.Signaling.new()

    {:ok, server} = Membrane.SimpleRTSPServer.start_link(@bbb_mp4, port: rtsp_port)
    on_exit(fn -> Process.exit(server, :normal) end)

    t =
      Boombox.async(
        input: "rtsp://localhost:#{rtsp_port}/",
        output: {:webrtc, signaling}
      )

    Boombox.run(input: {:webrtc, signaling}, output: output)
    Task.await(t)
    Compare.compare(output, "test/fixtures/ref_bun10s_opus_aac.mp4")
  end

  for(
    output <- [:stream, :reader, :message],
    input <- [:stream, :writer, :message],
    do: {output, input}
  )
  |> Enum.each(fn {output, input} ->
    @tag :mp4_elixir_rotate_mp4
    @tag String.to_atom("mp4_#{output}_rotate_#{input}_mp4")
    async_test "mp4 -> #{output} -> rotate -> #{input} -> mp4", %{tmp_dir: tmp} do
      produce_packet_stream(
        input: @bbb_mp4,
        output: {unquote(output), video: :image, audio: :binary}
      )
      |> Stream.map(fn
        %Boombox.Packet{kind: :video, payload: image} = packet ->
          image = Image.rotate!(image, 180)
          %Boombox.Packet{packet | payload: image}

        %Boombox.Packet{kind: :audio} = packet ->
          packet
      end)
      |> consume_packet_stream(
        input: {unquote(input), video: :image, audio: :binary},
        output: "#{tmp}/output.mp4"
      )

      Process.sleep(100)

      Compare.compare("#{tmp}/output.mp4", "test/fixtures/ref_bun_rotated.mp4")
    end
  end)

  [:stream, :writer, :message]
  |> Enum.each(fn elixir_endpoint ->
    @tag :bouncing_bubble_elixir_webrtc_mp4
    @tag String.to_atom("bouncing_bubble_#{elixir_endpoint}_webrtc_mp4")
    async_test "bouncing bubble -> #{elixir_endpoint} -> webrtc -> mp4", %{tmp_dir: tmp} do
      signaling = Membrane.WebRTC.Signaling.new()

      overlay =
        Image.new!(_w = 100, _h = 100, color: [0, 0, 0, 0])
        |> Image.Draw.circle!(_x = 50, _y = 50, _r = 48, color: :blue)

      bg = Image.new!(640, 480, color: :light_gray)
      max_x = Image.width(bg) - Image.width(overlay)
      max_y = Image.height(bg) - Image.height(overlay)
      fps = 60

      Task.async(fn ->
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
        |> consume_packet_stream(
          input: {unquote(elixir_endpoint), video: :image, audio: false},
          output: {:webrtc, signaling}
        )
      end)

      output = Path.join(tmp, "output.mp4")
      Boombox.run(input: {:webrtc, signaling}, output: output)

      Compare.compare(output, "test/fixtures/ref_bouncing_bubble.mp4", kinds: [:video])
    end
  end)

  [:stream, :reader, :message]
  |> Enum.each(fn elixir_endpoint ->
    @tag :mp4_elixir_resampled_pcm
    @tag String.to_atom("mp4_#{elixir_endpoint}_resampled_pcm")
    async_test "mp4 -> #{elixir_endpoint} -> resampled PCM" do
      output_pcm =
        produce_packet_stream(
          input: @bbb_mp4,
          output:
            {unquote(elixir_endpoint),
             video: false,
             audio: :binary,
             audio_rate: 16_000,
             audio_channels: 1,
             audio_format: :s16le}
        )
        |> Enum.map_join(& &1.payload)

      ref = File.read!("test/fixtures/ref_bun.pcm")
      assert Compare.samples_min_squared_error(ref, output_pcm, 16) < 500
    end
  end)

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

  Enum.each([@bbb_mp4, @bbb_mp4_v, @bbb_mp4_a], fn input ->
    @tag :srt_external_server_input
    async_test "srt with external server -> mp4 with #{input} fixture", %{tmp_dir: tmp} do
      input = unquote(input)
      output = Path.join(tmp, "output.mp4")
      ip = "127.0.0.1"
      port = get_free_port()
      stream_id = "some_stream_id"
      password = "some_password"
      {:ok, server} = ExLibSRT.Server.start_link(ip, port, password)
      p = send_srt(ip, port, stream_id, password, input)

      assert_receive {:srt_server_connect_request, _address, ^stream_id}
      t = Boombox.async(input: {:srt, server}, output: output)
      Task.await(t, 30_000)
      Testing.Pipeline.terminate(p)

      # we need `subject_terminated_early: true` as the `srt_send()` function from SRT API (used in
      # `send_srt/5`) does not immediately write a frame, but instead it puts the frame in a buffer,
      # and SRT API does not support flushing of that buffer
      Compare.compare(output, input, kinds: get_kinds(input), subject_terminated_early: true)
    end
  end)

  @spec produce_packet_stream(input: Boombox.input(), output: Boombox.elixir_output()) ::
          Enumerable.t()
  defp produce_packet_stream([input: _input, output: {:stream, _opts}] = opts) do
    Boombox.run(opts)
  end

  defp produce_packet_stream([input: _input, output: {:reader, _opts}] = opts) do
    boombox = Boombox.run(opts)

    Stream.repeatedly(fn ->
      case Boombox.read(boombox) do
        {:ok, packet} -> packet
        :finished -> :eos
      end
    end)
    |> Stream.take_while(&(&1 != :eos))
  end

  defp produce_packet_stream([input: _input, output: {:message, _opts}] = opts) do
    boombox = Boombox.run(opts)

    Stream.repeatedly(fn ->
      receive do
        {:boombox_packet, ^boombox, packet} ->
          packet

        {:boombox_finished, ^boombox} ->
          :eos
      end
    end)
    |> Stream.take_while(&(&1 != :eos))
  end

  @spec consume_packet_stream(Enumerable.t(),
          input: Boombox.elixir_input(),
          output: Boombox.output()
        ) :: term()
  defp consume_packet_stream(stream, [input: {:stream, _opts}, output: _output] = opts) do
    stream |> Boombox.run(opts)
  end

  defp consume_packet_stream(stream, [input: {:writer, _opts}, output: _output] = opts) do
    writer = Boombox.run(opts)

    Enum.each(stream, &Boombox.write(writer, &1))
    Boombox.close(writer)
  end

  defp consume_packet_stream(stream, [input: {:message, _opts}, output: _output] = opts) do
    server = Boombox.run(opts)

    Enum.each(stream, &send(server, {:boombox_packet, &1}))
    send(server, :boombox_close)
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

  defp send_srt(ip, port, stream_id, password, input_path) do
    p =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(%Membrane.File.Source{location: input_path, seekable?: true})
          |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
      )

    assert_pipeline_notified(p, :demuxer, {:new_tracks, tracks})

    spec =
      Enum.map(tracks, fn
        {audio_id, %Membrane.AAC{}} ->
          get_child(:demuxer)
          |> via_out(Pad.ref(:output, audio_id))
          |> child(Membrane.Realtimer)
          |> child(:audio_parser, %Membrane.AAC.Parser{
            out_encapsulation: :ADTS
          })
          |> via_in(:audio_input)
          |> get_child(:mpeg_ts_muxer)

        {video_id, %Membrane.H264{}} ->
          get_child(:demuxer)
          |> via_out(Pad.ref(:output, video_id))
          |> child(Membrane.Realtimer)
          |> child(:video_parser, %Membrane.H264.Parser{
            output_stream_structure: :annexb
          })
          |> via_in(:video_input)
          |> get_child(:mpeg_ts_muxer)
      end) ++
        [
          child(:mpeg_ts_muxer, Membrane.MPEGTS.Muxer)
          |> child(:srt_sink, %Membrane.SRT.Sink{
            ip: ip,
            port: port,
            stream_id: stream_id,
            password: password
          })
        ]

    Testing.Pipeline.execute_actions(p, spec: spec)
    p
  end

  defp get_kinds(@bbb_mp4), do: [:audio, :video]
  defp get_kinds(@bbb_mp4_a), do: [:audio]
  defp get_kinds(@bbb_mp4_v), do: [:video]
end
