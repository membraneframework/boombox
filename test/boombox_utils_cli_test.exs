defmodule Boombox.Utils.CLITest do
  use ExUnit.Case, async: true

  alias Boombox.Utils.CLI

  test "parse args" do
    assert {:args, input: "rtmp://localhost:5432", output: "output/index.m3u8"} ==
             CLI.parse_argv(~w(-i rtmp://localhost:5432 -o output/index.m3u8))

    assert {:args, input: "file.mp4", output: {:webrtc, "ws://localhost:1234"}} ==
             CLI.parse_argv(~w(-i file.mp4 -o --webrtc ws://localhost:1234))

    assert {:script, "path/to/script.exs"} = CLI.parse_argv(~w(-S path/to/script.exs))

    assert {:args,
            input:
              {:rtp,
               audio_encoding: :AAC,
               audio_payload_type: 123,
               audio_specific_config: <<161, 63>>,
               aac_bitrate_mode: :hbr},
            output: "file.mp4"} ==
             CLI.parse_argv(
               ~w(-i --rtp --audio-encoding AAC --audio-payload-type 123 --audio-specific-config a13f --aac-bitrate-mode hbr -o file.mp4 )
             )
  end
end

Boombox.run(
  input:
    {:rtp,
     audio_encoding: :AAC,
     audio_payload_type: 123,
     audio_specific_config: <<161, 63>>,
     aac_bitrate_mode: :hbr},
  output: "file.mp4"
)
