defmodule BoomboxStorageEndpointsTest do
  use ExUnit.Case, async: true
  import AsyncTest
  alias Support.Compare

  @inputs [
    {"bun10s.aac", [:audio]},
    {"bun10s.ogg", [:audio]},
    {"bun10s.mp3", [:audio]},
    {"bun10s.wav", [:audio]},
    {"bun10s.ivf", [:video]},
    {"bun10s.h264", [:video]},
    {"bun10s.h265", [:video]},
    {"bun10s.mp4", [:audio, :video]}
  ]

  @outputs [
    {:aac, [:audio]},
    {:ogg, [:audio]},
    {:mp3, [:audio]},
    {:wav, [:audio]},
    {:ivf, [:video]},
    {:h264, [:video]},
    {:h265, [:video]},
    {:mp4, [:audio, :video]}
  ]

  @test_cases for {input_path, input_kinds} <- @inputs,
                  {output_type, output_kinds} <- @outputs,
                  not Enum.empty?(Enum.filter(input_kinds, &(&1 in output_kinds))),
                  do: {input_path, output_type, Enum.filter(input_kinds, &(&1 in output_kinds))}

  @moduletag :tmp_dir

  Enum.each(@test_cases, fn {input_path, output_type, kinds} ->
    async_test "#{inspect(input_path)} file -> #{inspect(output_type)} file", %{tmp_dir: tmp} do
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
