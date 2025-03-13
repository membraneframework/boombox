defmodule Boombox.BrowserTest do
  use ExUnit.Case, async: false

  # Tests from this module are currently switched off on the CI because
  # they raise some errors there, that doesn't occur locally (probably
  # because of the problems with granting permissions for camera and
  # microphone access)

  require Logger

  @port 1235

  @moduletag :browser

  setup_all do
    browser_launch_opts = %{
      args: [
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream"
      ],
      headless: true
    }

    Application.put_env(:playwright, LaunchOptions, browser_launch_opts)
    {:ok, _apps} = Application.ensure_all_started(:playwright)

    :inets.stop()
    :ok = :inets.start()

    {:ok, _server} =
      :inets.start(:httpd,
        bind_address: ~c"localhost",
        port: @port,
        document_root: ~c"boombox_examples_data",
        server_name: ~c"assets_server",
        server_root: ~c"/tmp",
        erl_script_nocache: true
      )

    []
  end

  setup do
    {_pid, browser} = Playwright.BrowserType.launch(:chromium)

    on_exit(fn ->
      Playwright.Browser.close(browser)
    end)

    [browser: browser]
  end

  @tag :tmp_dir
  test "browser -> boombox -> mp4", %{browser: browser, tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "/webrtc_to_mp4.mp4")

    boombox_task =
      Task.async(fn ->
        Boombox.run(
          input: {:webrtc, "ws://localhost:8829"},
          output: output_path
        )
      end)

    ingress_page = start_page(browser, "webrtc_from_browser")

    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(ingress_page)
    assert_frames_encoded(ingress_page, seconds)

    close_page(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around ~850_000
    assert size > 400_000
  end

  @tag :tmp_dir
  test "browser -> (whip) boombox -> mp4", %{browser: browser, tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "/webrtc_to_mp4.mp4")

    boombox_task =
      Task.async(fn ->
        Boombox.run(
          input: {:whip, "http://localhost:8829", token: "whip_it!"},
          output: output_path
        )
      end)

    ingress_page = start_page(browser, "whip")
    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(ingress_page)
    assert_frames_encoded(ingress_page, seconds)

    close_page(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around ~850_000
    assert size > 400_000
  end

  for first <- [:ingress, :egress], transcoding? <- [true, false] do
    test "browser -> boombox -> browser, but #{first} browser page connects first and :enforce_audio/video_transcoding? is set to #{transcoding?}",
         %{
           browser: browser
         } do
      transcoding? = unquote(transcoding?)

      boombox_task =
        Task.async(fn ->
          Boombox.run(
            input: {:webrtc, "ws://localhost:8829"},
            output: {:webrtc, "ws://localhost:8830", force_transcoding: transcoding?}
          )
        end)

      {ingress_page, egress_page} =
        case unquote(first) do
          :ingress ->
            ingress_page = start_page(browser, "webrtc_from_browser")
            Process.sleep(500)
            egress_page = start_page(browser, "webrtc_to_browser")
            {ingress_page, egress_page}

          :egress ->
            egress_page = start_page(browser, "webrtc_to_browser")
            Process.sleep(500)
            ingress_page = start_page(browser, "webrtc_from_browser")
            {ingress_page, egress_page}
        end

      seconds = 10
      Process.sleep(seconds * 1000)

      [ingress_page, egress_page]
      |> Enum.each(&assert_page_connected/1)

      assert_frames_encoded(ingress_page, seconds)
      assert_frames_decoded(egress_page, seconds)

      assert_page_codecs(ingress_page, [:vp8, :opus])
      egress_video_codec = if unquote(transcoding?), do: :h264, else: :vp8
      assert_page_codecs(egress_page, [egress_video_codec, :opus])

      [ingress_page, egress_page]
      |> Enum.each(&close_page/1)

      Task.await(boombox_task)
    end
  end

  test "boombox -> browser (bouncing logo)", %{browser: browser} do
    overlay =
      __DIR__
      |> Path.join("fixtures/logo.png")
      |> Image.open!()

    bg = Image.new!(640, 480, color: :light_gray)
    max_x = Image.width(bg) - Image.width(overlay)
    max_y = Image.height(bg) - Image.height(overlay)

    stream =
      Stream.iterate({_x = 300, _y = 0, _dx = 1, _dy = 2, _pts = 0}, fn {x, y, dx, dy, pts} ->
        dx = if (x + dx) in 0..max_x, do: dx, else: -dx
        dy = if (y + dy) in 0..max_y, do: dy, else: -dy
        pts = pts + div(Membrane.Time.seconds(1), _fps = 60)
        {x + dx, y + dy, dx, dy, pts}
      end)
      |> Stream.map(fn {x, y, _dx, _dy, pts} ->
        img = Image.compose!(bg, overlay, x: x, y: y)
        %Boombox.Packet{kind: :video, payload: img, pts: pts}
      end)

    boombox_task =
      Task.async(fn ->
        stream
        |> Boombox.run(
          input: {:stream, video: :image, audio: false},
          output: {:webrtc, "ws://localhost:8830"}
        )
      end)

    page = start_page(browser, "webrtc_to_browser")

    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(page)
    assert_frames_decoded(page, seconds)

    close_page(page)
    Task.shutdown(boombox_task)
  end

  defp start_page(browser, page) do
    url = "http://localhost:#{@port}/#{page}.html"
    do_start_page(browser, url)
  end

  defp do_start_page(browser, url) do
    page = Playwright.Browser.new_page(browser)

    response = Playwright.Page.goto(page, url)
    assert response.status == 200

    Playwright.Page.click(page, "button[id=\"button\"]")

    page
  end

  defp close_page(page) do
    Playwright.Page.click(page, "button[id=\"button\"]")
    Playwright.Page.close(page)
  end

  defp assert_page_connected(page) do
    assert page
           |> Playwright.Page.text_content("[id=\"status\"]")
           |> String.contains?("Connected")
  end

  defp assert_page_codecs(page, codecs) do
    page_codecs =
      get_webrtc_stats(page, type: "codec")
      |> MapSet.new(& &1.mimeType)

    expected_codecs =
      codecs
      |> MapSet.new(fn
        :h264 -> "video/H264"
        :vp8 -> "video/VP8"
        :opus -> "audio/opus"
      end)

    assert page_codecs == expected_codecs
  end

  defp assert_frames_encoded(page, time_seconds) do
    fps_lowerbound = 12

    [%{framesEncoded: frames_encoded}] =
      get_webrtc_stats(page, type: "outbound-rtp", kind: "video")

    assert frames_encoded >= time_seconds * fps_lowerbound
  end

  defp assert_frames_decoded(page, time_seconds) do
    fps_lowerbound = 12

    [%{framesDecoded: frames_decoded}] =
      get_webrtc_stats(page, type: "inbound-rtp", kind: "video")

    assert frames_decoded >= time_seconds * fps_lowerbound
  end

  defp get_webrtc_stats(page, constraints) do
    js_fuj =
      "async () => {const stats = await window.pc.getStats(null); return Array.from(stats)}"

    Playwright.Page.evaluate(page, js_fuj)
    |> Enum.map(fn [_id, data] -> data end)
    |> Enum.filter(fn stat -> Enum.all?(constraints, fn {k, v} -> stat[k] == v end) end)
  end
end
