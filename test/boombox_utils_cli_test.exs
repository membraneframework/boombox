defmodule Boombox.Utils.CLITest do
  use ExUnit.Case, async: true

  alias Boombox.Utils.CLI

  test "parse args" do
    assert [input: "rtmp://localhost:5432", output: "output/index.m3u8"] ==
             CLI.parse_args(~w(-i rtmp://localhost:5432 -o output/index.m3u8))

    assert [input: "file.mp4", output: {:webrtc, "ws://localhost:1234"}] ==
             CLI.parse_args(~w(-i file.mp4 -o --webrtc ws://localhost:1234))
  end
end
