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
    {{:h264, "bun10s.h264", framerate: {30, 1}}, [:video]},
    {"bun10s.h265", [:video]},
    {{:h265, "bun10s.h265", framerate: {30, 1}}, [:video]},
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

  @test_cases for {input_spec, input_kinds} <- @inputs,
                  {output_type, output_kinds} <- @outputs,
                  kinds = Enum.filter(input_kinds, &(&1 in output_kinds)),
                  not Enum.empty?(kinds),
                  do: {input_spec, output_type, kinds}

  @moduletag :tmp_dir

  Enum.each(@test_cases, fn {input_spec, output_type, kinds} ->
    async_test "#{inspect(input_spec)} -> #{inspect(output_type)} file", %{tmp_dir: tmp} do
      fixtures_dir = "test/fixtures/storage_endpoints/"
      ref_file = Path.join(fixtures_dir, "bun10s.mp4")
      output_path = Path.join(tmp, "output")

      input = resolve_input(unquote(Macro.escape(input_spec)), fixtures_dir)

      Boombox.run(input: input, output: {unquote(output_type), output_path})

      output_mp4_path = Path.join(tmp, "output.mp4")

      Boombox.run(
        input: {unquote(output_type), output_path},
        output: output_mp4_path
      )

      Compare.compare(output_mp4_path, ref_file, kinds: unquote(kinds))
    end
  end)

  defp resolve_input(path, fixtures_dir) when is_binary(path), do: Path.join(fixtures_dir, path)

  defp resolve_input({type, file, opts}, fixtures_dir),
    do: {type, Path.join(fixtures_dir, file), opts}
end
