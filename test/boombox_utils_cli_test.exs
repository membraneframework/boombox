defmodule Boombox.Utils.CLITest do
  use ExUnit.Case, async: true

  alias Boombox.Utils.CLI

  test "parse args" do
    assert {:args, input: "rtmp://localhost:5432", output: "output/index.m3u8"} ==
             CLI.parse_argv(~w(-i rtmp://localhost:5432 -o output/index.m3u8))

    assert {:args, input: "file.mp4", output: {:webrtc, "ws://localhost:1234"}} ==
             CLI.parse_argv(~w(-i file.mp4 -o --webrtc ws://localhost:1234))

    assert {:script, "path/to/script.exs"} = CLI.parse_argv(~w(-S path/to/script.exs))
  end
end
