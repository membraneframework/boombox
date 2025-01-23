defmodule BrowserTest do
  use ExUnit.Case, async: false

  require Logger

  @port 1235

  setup_all do
    browser_launch_opts = %{
      args: [
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream",
        "--auto-accept-camera-and-microphone-capture"
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

    Process.sleep(5_000)
    Playwright.Page.close(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around 450_000
    assert size > 200_000
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

      Process.sleep(1_000)

      [ingress_page, egress_page]
      |> Enum.each(&assert_page_connected/1)

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

  defp assert_page_connected(page) do
    assert page
           |> Playwright.Page.text_content("[id=\"status\"]")
           |> String.contains?("Connected")
  end
end
