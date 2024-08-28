defmodule Boombox.Utils.CLI do
  @moduledoc false

  @spec parse_argv([String.t()]) ::
          {:args, input: Boombox.input(), output: Boombox.output()} | {:sript, String.t()}
  def parse_argv(argv) do
    OptionParser.parse(argv, strict: [script: :string], aliases: [s: :script, S: :script])
    |> case do
      {[], _argv, _switches} ->
        {:args, parse_args(argv)}

      result ->
        case handle_option_parser_result(result) do
          [script: script] -> {:script, script}
          [] -> cli_exit_error()
        end
    end
  end

  defp parse_args(argv) do
    aliases = [i: :input, o: :output]
    i_type = get_switch_type(argv, :input, aliases)
    o_type = get_switch_type(argv, :output, aliases)

    switches =
      [input: i_type, output: o_type] ++
        Keyword.from_keys([:mp4, :webrtc, :rtmp, :hls, :transport], :string)

    {input, output} =
      OptionParser.parse(argv, strict: switches, aliases: aliases)
      |> handle_option_parser_result()
      |> case do
        [input: _value] ++ _rest = parsed ->
          Enum.split_while(parsed, fn {k, _v} -> k != :output end)

        [output: _value] ++ _rest = parsed ->
          Enum.split_while(parsed, fn {k, _v} -> k != :input end)

        _other ->
          cli_exit_error()
      end

    [resolve_endpoint(input), resolve_endpoint(output)]
  end

  @spec get_switch_type([String.t()], atom(), Keyword.t()) :: :boolean | :string
  defp get_switch_type(argv, option, aliases) do
    with [] <- OptionParser.parse(argv, strict: [{option, :string}], aliases: aliases) |> elem(0),
         [] <- OptionParser.parse(argv, strict: [{option, :boolean}], aliases: aliases) |> elem(0) do
      cli_exit_error("#{option} not provided")
    else
      [{^option, true}] -> :boolean
      [{^option, string}] when is_binary(string) -> :string
    end
  end

  @spec resolve_endpoint(Keyword.t()) :: {:input, Boombox.input()} | {:output, Boombox.output()}
  defp resolve_endpoint(parsed) do
    case parsed do
      [{direction, true}, {endpoint, value}] -> {direction, {endpoint, value}}
      [{direction, true}, {endpoint, value} | opts] -> {direction, {endpoint, value, opts}}
      [{direction, value}] -> {direction, value}
      _other -> cli_exit_error()
    end
  end

  defp handle_option_parser_result(result) do
    case result do
      {parsed, [], []} -> parsed
      {_parsed, _argv, [{s, _v} | _switches]} -> cli_exit_error("unexpected option '#{s}'")
      {_parsed, [arg | _argv], []} -> cli_exit_error("unexpected value '#{arg}'")
    end
  end

  @spec cli_exit_error() :: no_return
  @spec cli_exit_error(String.t() | nil) :: no_return
  defp cli_exit_error(description \\ nil) do
    description = if description, do: "Error: #{description}\n\n"

    IO.puts("""
    #{description}\
    Usage: boombox -i [input] -o [output]

    Examples:

    boombox -i rtmp://localhost:5432 -o output/index.m3u8
    boombox -i file.mp4 -o --webrtc ws://localhost:1234
    """)

    System.halt(1)
  end
end
