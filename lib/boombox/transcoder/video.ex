defmodule Membrane.Boombox.Transcoder.Video do
  @moduledoc false

  alias Membrane.H264
  alias Membrane.H265
  alias Membrane.RawVideo
  alias Membrane.VP8

  defguard is_video_format(format)
           when is_struct(format) and
                  (format.__struct__ in [AAC, Opus, RawAudio] or
                     (format.__struct__ == RemoteStream and format.content_format == Opus and
                        format.type == :packetized))



end
