defmodule BrowserTest do
  use ExUnit.Case, async: false

  # Tests from this module are currently switched off on the CI because
  # they raise some errors there, that doesn't occur locally (probably
  # because of the problems with granting permissions for camera and
  # microphone access)

  require Logger

  @port 1235

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
        document_root: ~c"#{__DIR__}/assets",
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

  @tag :browser
  @tag :tmp_dir
  @tag :a
  test "browser -> boombox -> mp4", %{browser: browser, tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "/webrtc_to_mp4.mp4")

    boombox_task =
      Task.async(fn ->
        Boombox.run(
          input: {:webrtc, "ws://localhost:8829"},
          output: output_path
        )
      end)

    ingress_page = start_ingress_page(browser)

    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(ingress_page)
    assert_frames_on_ingress_page(ingress_page, seconds)

    Playwright.Page.close(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around ~850_000
    assert size > 400_000
  end

  for first <- [:ingress, :egress] do
    @tag :browser
    test "browser -> boombox -> browser, but #{first} browser page connects first", %{
      browser: browser
    } do
      boombox_task =
        Task.async(fn ->
          Boombox.run(
            input: {:webrtc, "ws://localhost:8829"},
            output: {:webrtc, "ws://localhost:8830"}
          )
        end)

      {ingress_page, egress_page} =
        case unquote(first) do
          :ingress ->
            ingress_page = start_ingress_page(browser)
            Process.sleep(500)
            egress_page = start_egress_page(browser)
            {ingress_page, egress_page}

          :egress ->
            egress_page = start_egress_page(browser)
            Process.sleep(500)
            ingress_page = start_ingress_page(browser)
            {ingress_page, egress_page}
        end

      seconds = 10
      Process.sleep(seconds * 1000)

      [ingress_page, egress_page]
      |> Enum.each(&assert_page_connected/1)

      assert_frames_on_ingress_page(ingress_page, seconds)
      assert_frames_on_egress_page(egress_page, seconds)

      [ingress_page, egress_page]
      |> Enum.each(&Playwright.Page.close/1)

      Task.await(boombox_task)
    end
  end

  defp start_ingress_page(browser) do
    url = "http://localhost:#{inspect(@port)}/webrtc_from_browser.html"
    start_page(browser, url)
  end

  defp start_egress_page(browser) do
    url = "http://localhost:#{inspect(@port)}/webrtc_to_browser.html"
    start_page(browser, url)
  end

  defp start_page(browser, url) do
    page = Playwright.Browser.new_page(browser)

    response = Playwright.Page.goto(page, url)
    assert response.status == 200

    Playwright.Page.click(page, "button[id=\"button\"]")

    page
  end

  defp assert_frames_on_ingress_page(page, seconds_since_launch) do
    div_id = "outbound-rtp-frames-encoded"
    assert_frames_on_page(page, div_id, seconds_since_launch)
  end

  defp assert_frames_on_egress_page(page, seconds_since_launch) do
    div_id = "inbound-rtp-frames-decoded"
    assert_frames_on_page(page, div_id, seconds_since_launch)
  end

  defp assert_frames_on_page(page, id, seconds_since_launch) do
    frames_number =
      page
      |> Playwright.Page.text_content("[id=\"#{id}\"]")
      |> String.to_integer()

    frames_per_second_lowerbound = 12
    frames_number_lowerbound = frames_per_second_lowerbound * seconds_since_launch

    assert frames_number >= frames_number_lowerbound
  end

  defp assert_page_connected(page) do
    assert page
           |> Playwright.Page.text_content("[id=\"status\"]")
           |> String.contains?("Connected")
  end
end
