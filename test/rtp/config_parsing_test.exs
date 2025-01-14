defmodule Boombox.RTP.ParsingTest do
  use ExUnit.Case

  alias Boombox.Pipeline.Ready

  describe "Parsing RTP options succeeds" do
    test "for correct AAC + H264 options" do
      rtp_opts =
        [
          port: 5001,
          audio_encoding: :AAC,
          audio_payload_type: 100,
          audio_clock_rate: 1234,
          aac_bitrate_mode: :hbr,
          audio_specific_config: Base.decode16!("1210"),
          video_encoding: :H264,
          video_payload_type: 101,
          video_clock_rate: 6789,
          pps: "abc",
          sps: "def"
        ]

      assert %Ready{} = Boombox.RTP.create_input(rtp_opts)
    end

    test "for minimal H264 options" do
      rtp_opts = [port: 5001, video_encoding: :H264]

      assert %Ready{} = Boombox.RTP.create_input(rtp_opts)
    end
  end

  describe "Parsing RTP options fails" do
    test "for options with missing required encoding specific params" do
      rtp_opts = [port: 5001, audio_encoding: :AAC]

      assert_raise MatchError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end

    test "for no tracks configured" do
      rtp_opts = [port: 5001]

      assert_raise RuntimeError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end

    test "for no options provided" do
      rtp_opts = []

      assert_raise RuntimeError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end

    test "for unsupported encoding" do
      rtp_opts = [port: 5001, video_encoding: :Glorp]

      assert_raise RuntimeError, fn -> Boombox.RTP.create_input(rtp_opts) end
    end
  end
end
