defmodule BoomboxBrowserTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Support.Async

  require Membrane.Pad, as: Pad
  require Logger

  alias Playwright.Page

  setup_all do
    browser_launch_opts = %{
      args: [
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream"
      ],
      headless: true
    }

    Application.put_env(:playwright, LaunchOptions, browser_launch_opts)
    {:ok, _} = Application.ensure_all_started(:playwright)

    []
  end

  setup do
    {:ok, browser} = Playwright.BrowserType.launch(:chromium)

    on_exit(fn ->
      Playwright.Browser.close(browser)
    end)

    [browser: browser]
  end

  test "browser <-(via WebRTC)-> boombox", %{browser: browser} do
    {:ok, task} =
      Task.start_link(fn ->
        Boombox.run(input: {:webrtc, "ws://localhost:8829"}, output: "#{out_dir}/webrtc_to_mp4.mp4")
      end)

    Process.sleep(500)

    path = __DIR__ |> Path.join("../boombox_examples_data/webrtc_from_browser.html")
    Page.goto(page, path)
    # Page.click(page, selector)




  end

end
