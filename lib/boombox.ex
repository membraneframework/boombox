defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `t:input/0` and `t:output/0` for supported protocols.
  """
  @type webrtc_opts :: Membrane.WebRTC.SignalingChannel.t() | URI.t()

  @type file_extension :: :mp4

  @type input ::
          String.t()
          | {:file, file_extension(), path :: String.t()}
          | {:http, file_extension(), url :: String.t()}
          | {:webrtc, webrtc_opts()}
          | {:rtmp, (url :: String.t()) | (client_ref :: pid())}
          | {:rtsp, url :: String.t()}
  @type output ::
          String.t()
          | {:file, file_extension(), path :: String.t()}
          | {:webrtc, webrtc_opts()}
          | {:hls, path :: String.t()}

  @spec run(input: input, output: output) :: :ok
  def run(opts) do
    {:ok, supervisor, _pipeline} = Membrane.Pipeline.start_link(Boombox.Pipeline, opts)
    Process.monitor(supervisor)

    receive do
      {:DOWN, _monitor, :process, ^supervisor, _reason} -> :ok
    end
  end

  @spec run_cli([String.t()]) :: :ok
  def run_cli(args \\ System.argv()) do
    args =
      Enum.map(args, fn
        "-" <> value -> String.to_atom(value)
        value -> value
      end)

    run(input: parse_cli_io(:i, args), output: parse_cli_io(:o, args))
  end

  defp parse_cli_io(type, args) do
    args
    |> Enum.drop_while(&(&1 != type))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 not in [:i, :o]))
    |> case do
      [value] -> value
      [_h | _t] = values -> List.to_tuple(values)
    end
  end
end
