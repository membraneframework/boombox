defmodule Boombox.RTP.ParsingTest do
  use ExUnit.Case

  alias Boombox.Pipeline.Ready

  describe "Parsing RTP options succeeds" do
    test "for correct AAC + H264 options" do
      rtp_opts =
        [
          port: 5001,
          track_configs: [
            audio: [
              encoding:
                {:AAC, [bitrate_mode: :hbr, audio_specific_config: Base.decode16!("1210")]},
              payload_type: 100,
              clock_rate: 1234
            ],
            video: [
              encoding: {:H264, [ppss: ["abc"], spss: ["def"]]},
              payload_type: 101,
              clock_rate: 6789
            ]
          ]
        ]

      assert %Ready{} = Boombox.RTP.create_input(rtp_opts)
    end

    test "for minimal H264 options" do
      rtp_opts = [port: 5001, track_configs: [video: [encoding: :H264]]]

      assert %Ready{} = Boombox.RTP.create_input(rtp_opts)
    end
  end

  describe "Parsing RTP options fails" do
    test "for options with missing required encoding specific params" do
      rtp_opts = [port: 5001, track_configs: [audio: [encoding: :AAC]]]

      assert_raise MatchError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end

    test "for no tracks configured" do
      rtp_opts = [port: 5001, track_configs: []]

      assert_raise RuntimeError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end

    test "for no port provided" do
      rtp_opts = [track_configs: []]

      assert_raise RuntimeError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end
  end
end
