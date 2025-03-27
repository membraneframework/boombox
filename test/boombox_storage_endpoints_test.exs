defmodule BoomboxStorageEndpointsTest do
  use ExUnit.Case, async: true

  alias Support.Compare

  @just_audio_inputs ["bun10s.aac", "bun10s.ogg", "bun10s.mp3", "bun10s.wav"]
  @just_audio_outputs [
    {:aac, [:audio]},
    {:ogg, [:audio]},
    {:mp3, [:audio]},
    {:wav, [:audio]}
  ]
  @just_audio_cases for input <- @just_audio_inputs,
                        output <- @just_audio_outputs,
                        do: {input, output}

  @just_video_inputs ["bun10s.ivf", "bun10s.h264"]
  @just_video_outputs [{:ivf, [:video]}, {:h264, [:video]}]
  @just_video_cases for input <- @just_video_inputs,
                        output <- @just_video_outputs,
                        do: {input, output}
  @av_inputs ["bun10s.mp4"]
  @av_outputs [{:mp4, [:audio, :video]}]
  @av_cases for input <- @av_inputs,
                output <- @av_outputs,
                do: {input, output}

  @test_cases @just_audio_cases ++ @just_video_cases ++ @av_cases

  @moduletag :tmp_dir

  Enum.each(@test_cases, fn {input_path, {output_type, kinds}} ->
    test "#{inspect(input_path)} file -> #{inspect(output_type)} file", %{tmp_dir: tmp} do
      fixtures_dir = "test/fixtures/storage_endpoints/"
      ref_file = Path.join(fixtures_dir, "bun10s.mp4")
      output_path = Path.join(tmp, "output")

      Boombox.run(
        input: Path.join(fixtures_dir, unquote(input_path)),
        output: {unquote(output_type), output_path}
      )

      output_mp4_path = Path.join(tmp, "output.mp4")

      Boombox.run(
        input: {unquote(output_type), output_path},
        output: output_mp4_path
      )

      Compare.compare(output_mp4_path, ref_file, kinds: unquote(kinds))
    end
  end)
end
