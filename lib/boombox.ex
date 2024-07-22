defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `t:input/0` and `t:output/0` for supported protocols.
  """
  @type webrtc_opts :: Membrane.WebRTC.SignalingChannel.t() | URI.t()

  @type input ::
          URI.t()
          | Path.t()
          | [:file | :mp4 | Path.t()]
          | [:webrtc | webrtc_opts()]
          | [:rtmp | URI.t()]
          | [:rtsp | URI.t()]
  @type output :: URI.t() | Path.t() | [:file | :mp4 | Path.t()] | [:webrtc | webrtc_opts()]

  @spec run(input: input, output: output) :: :ok
  def run(opts) do
    {:ok, supervisor, _pipeline} = Membrane.Pipeline.start_link(Boombox.Pipeline, opts)
    Process.monitor(supervisor)

    receive do
      {:DOWN, _monitor, :process, ^supervisor, _reason} -> :ok
    end
  end
end
