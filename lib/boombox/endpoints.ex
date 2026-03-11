defmodule Boombox.Endpoints do
  @moduledoc """
  Definitions of all available Boombox endpoints.

  Endpoints define possible inputs and outputs of Boombox. Each endpoint
  represents a different media format or protocol. See `t:input/0` and
  `t:output/0` for available inputs and outputs.
  """

  alias Membrane.HTTPAdaptiveStream
  alias Membrane.RTP

  @typedoc """
  Controls the transcoding behavior. Allowed only for output.

  The default transcoding behavior is `:if_needed`, which means that if the
  format of the media is the same for input and output, the stream is not
  decoded and re-encoded. This saves resources but in some cases transcoding
  is necessary. Set to `:always` to force transcoding regardless of whether
  formats differ. Set to `:never` to never transcode, raising if the desired
  operation can't be done without transcoding.
  """
  @type transcoding_policy_opt :: {:transcoding_policy, :always | :if_needed | :never}

  @typedoc """
  Determines if the HLS session is live or VOD type. Allowed only for HLS output.

  Influences the type of metadata inserted into the playlist manifest.
  Defaults to `:vod`.
  """
  @type hls_mode_opt :: {:mode, :live | :vod}

  @typedoc """
  Controls the variant selection policy for HLS input.
  """
  @type hls_variant_selection_policy_opt ::
          {:variant_selection_policy, HTTPAdaptiveStream.Source.variant_selection_policy()}

  @typedoc """
  Explicitly specifies the transport for storage endpoints.

  If not provided, transport is inferred from the location — file paths
  resolve to `:file`, HTTP URLs to `:http`.
  """
  @type transport_opt :: {:transport, :file | :http}

  @typedoc """
  Signaling channel for a WebRTC connection.

  Can be a `Membrane.WebRTC.Signaling.t()` struct or a WebSocket URL string.
  """
  @type webrtc_signaling :: Membrane.WebRTC.Signaling.t() | String.t()

  @typedoc """
  An authentication option for SRT connections.

  * `{:stream_id, id}` - ID of the stream. When using SRT as input,
    determines the stream ID the server will accept. When using for output,
    determines the stream ID being sent.
  * `{:password, password}` - Authentication password. When using SRT as
    input, determines the password required from clients. When using for
    output, determines the password the client uses to authenticate.
  """
  @type srt_auth_opt ::
          {:stream_id, String.t()}
          | {:password, String.t()}

  @typedoc """
  An option for the raw data input endpoints (`:stream`, `:writer`, `:message`).

  * `{:audio | :video, value}` - Determines if and in what form Boombox will accept audio / video.
    If not `false`, Boombox will accept the media encapsulated with
    `t:Boombox.Packet.t/0` structs in `:payload` field. Value of this option
    determines in what form the media has to be:
    - `:audio` - if this option is set to `true`, `:binary` default value is assumed
      and the audio chunks have to be in form of `t:binary/0` data.
    - `:video` - if this option is set to `true`, `:image` default value is assumed
      and the video frames have to be in form of `t:Vix.Vips.Image.t/0` structs.
  * `{:is_live, value}` - If `true`, Boombox assumes that packets are provided
    in realtime and won't control their pace when passing them to the output.
    `false` by default.
  """
  @type in_raw_data_opt ::
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
          | {:is_live, boolean()}

  @typedoc """
  An option for the raw data output endpoints (`:stream`, `:reader`, `:message`).

  * `{:audio | :video, value}` - Determines if and how Boombox will produce audio / video.
    If not `false`, Boombox will produce the media and encapsulate it with
    `t:Boombox.Packet.t/0` structs in `:payload` field. Value of this option
    determines how the media will be stored:
    - `:audio` - if this option is set to `true`, `:binary` default value is assumed
      and the audio chunks are stored as `t:binary/0` data.
    - `:video` - if this option is set to `true`, `:image` default value is assumed
      and the video frames are stored as `t:Vix.Vips.Image.t/0` structs.
  * `{:audio_format, format}` - Sample format of the produced audio stream.
  * `{:audio_rate, rate}` - Sample rate of the produced audio stream (samples
    per second).
  * `{:audio_channels, channels}` - Number of channels in the produced audio
    stream. Channels are interleaved.
  * `{:video_width, width}`, `{:video_height, height}` - Dimensions of the
    produced video stream.
  * `{:pace_control, value}` - If `true`, the incoming streams are passed to
    the output according to their timestamps. If `false`, they are passed as
    fast as possible. `true` by default.
  """
  @type out_raw_data_opt ::
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
          | {:audio_format, Membrane.RawAudio.SampleFormat.t()}
          | {:audio_rate, Membrane.RawAudio.sample_rate_t()}
          | {:audio_channels, Membrane.RawAudio.channels_t()}
          | {:video_width, non_neg_integer()}
          | {:video_height, non_neg_integer()}
          | {:pace_control, boolean()}

  @typedoc """
  A common option shared by RTP input and output.

  When configuring a track for a media type (video or audio):

  * `{:audio_encoding | :video_encoding, name}` - MUST be provided to configure a given
    media type. Some options are encoding-specific. Currently supported
    encodings are: AAC, Opus, H264, H265. The encoding name must match the
    `rtpmap` attribute of an SDP description.
  * `{:audio_payload_type | :video_payload_type, type}`, `{:audio_clock_rate | :video_clock_rate, rate}` -
    MAY be provided. If not, an unofficial default will be used. Must match
    the `rtpmap` attribute of an SDP description.
  * `{:aac_bitrate_mode, mode}` - MUST be provided for AAC encoding. Defines
    which mode should be assumed/set when depayloading/payloading.
  """
  @type common_rtp_opt ::
          {:video_encoding, RTP.encoding_name()}
          | {:video_payload_type, RTP.payload_type()}
          | {:video_clock_rate, RTP.clock_rate()}
          | {:audio_encoding, RTP.encoding_name()}
          | {:audio_payload_type, RTP.payload_type()}
          | {:audio_clock_rate, RTP.clock_rate()}
          | {:aac_bitrate_mode, RTP.AAC.Utils.mode()}

  @typedoc """
  An option for the `t:rtp_input/0` endpoint.

  A receiving `{:port, port}` MUST be provided and the media to be received
  MUST be configured. Media configuration is explained in `t:common_rtp_opt/0`.

  In addition to `t:common_rtp_opt/0`, the following encoding-specific options
  are available for RTP input only:

  * `{:audio_specific_config, config}` - MUST be provided for AAC encoding.
    Contains crucial information about the stream obtained from a side channel.
  * `{:vps, vps}` (H265 only), `{:pps, pps}`, `{:sps, sps}` - MAY be
    provided for H264 or H265 encodings. Parameter sets obtained from a side
    channel, containing information about the encoded stream.
  """
  @type in_rtp_opt ::
          common_rtp_opt()
          | {:port, :inet.port_number()}
          | {:audio_specific_config, binary()}
          | {:vps, binary()}
          | {:pps, binary()}
          | {:sps, binary()}

  @typedoc """
  An option for the `t:rtp_output/0` endpoint.

  The target `{:port, port}` and `{:address, address}` MUST be provided
  (alternatively combined as a `<address>:<port>` string via `{:target, target}`)
  and the media to be sent MUST be configured. Media configuration is explained
  in `t:common_rtp_opt/0`.
  """
  @type out_rtp_opt ::
          common_rtp_opt()
          | {:address, :inet.ip_address() | String.t()}
          | {:port, :inet.port_number()}
          | {:target, String.t()}
          | transcoding_policy_opt()

  @typedoc """
  MP4 container input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type mp4_input ::
          {:mp4, location :: String.t()}
          | {:mp4, location :: String.t(), [transport_opt()]}

  @typedoc """
  MP4 container output endpoint.

  `location` is a file path.
  """
  @type mp4_output ::
          {:mp4, location :: String.t()}
          | {:mp4, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  AAC audio codec input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type aac_input ::
          {:aac, location :: String.t()}
          | {:aac, location :: String.t(), [transport_opt()]}

  @typedoc """
  AAC audio codec output endpoint.

  `location` is a file path.
  """
  @type aac_output ::
          {:aac, location :: String.t()}
          | {:aac, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  WAV audio format input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type wav_input ::
          {:wav, location :: String.t()}
          | {:wav, location :: String.t(), [transport_opt()]}

  @typedoc """
  WAV audio format output endpoint.

  `location` is a file path.
  """
  @type wav_output ::
          {:wav, location :: String.t()}
          | {:wav, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  MP3 audio format input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type mp3_input ::
          {:mp3, location :: String.t()}
          | {:mp3, location :: String.t(), [transport_opt()]}

  @typedoc """
  MP3 audio format output endpoint.

  `location` is a file path.
  """
  @type mp3_output ::
          {:mp3, location :: String.t()}
          | {:mp3, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  IVF container format input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type ivf_input ::
          {:ivf, location :: String.t()}
          | {:ivf, location :: String.t(), [transport_opt()]}

  @typedoc """
  IVF container format output endpoint.

  `location` is a file path.
  """
  @type ivf_output ::
          {:ivf, location :: String.t()}
          | {:ivf, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  Ogg container format input endpoint.

  `location` is a file path or HTTP URL.
  """
  @type ogg_input ::
          {:ogg, location :: String.t()}
          | {:ogg, location :: String.t(), [transport_opt()]}

  @typedoc """
  Ogg container format output endpoint.

  `location` is a file path.
  """
  @type ogg_output ::
          {:ogg, location :: String.t()}
          | {:ogg, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  H264 video codec input endpoint in Annex-B format.

  `location` is a file path or HTTP URL. The `framerate` option defaults to `{30, 1}`.
  """
  @type h264_input ::
          {:h264, location :: String.t()}
          | {:h264, location :: String.t(),
             [transport_opt() | {:framerate, Membrane.H264.framerate()}]}

  @typedoc """
  H264 video codec output endpoint in Annex-B format.

  `location` is a file path.
  """
  @type h264_output ::
          {:h264, location :: String.t()}
          | {:h264, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  H265 video codec input endpoint in Annex-B format.

  `location` is a file path or HTTP URL. The `framerate` option defaults to `{30, 1}`.
  """
  @type h265_input ::
          {:h265, location :: String.t()}
          | {:h265, location :: String.t(),
             [transport_opt() | {:framerate, Membrane.H265.framerate_t()}]}

  @typedoc """
  H265 video codec output endpoint in Annex-B format.

  `location` is a file path.
  """
  @type h265_output ::
          {:h265, location :: String.t()}
          | {:h265, location :: String.t(), [transport_opt() | transcoding_policy_opt()]}

  @typedoc """
  WebRTC input endpoint.

  See `t:webrtc_signaling/0` for the `signaling` argument.
  """
  @type webrtc_input :: {:webrtc, webrtc_signaling()}

  @typedoc """
  WebRTC output endpoint.

  See `t:webrtc_signaling/0` for the `signaling` argument.
  """
  @type webrtc_output ::
          {:webrtc, webrtc_signaling()}
          | {:webrtc, webrtc_signaling(), [transcoding_policy_opt()]}

  @typedoc """
  WHIP (WebRTC-HTTP Ingestion Protocol) input endpoint.

  `uri` is an HTTP URL for the WHIP server. The `token` is used for
  authentication and authorization.
  """
  @type whip_input :: {:whip, uri :: String.t(), [token: String.t()]}

  @typedoc """
  WHIP (WebRTC-HTTP Ingestion Protocol) output endpoint.

  `uri` is an HTTP URL for the WHIP server. The `token` is used for
  authentication and authorization. Custom Bandit server options can
  also be provided.
  """
  @type whip_output ::
          {:whip, uri :: String.t(),
           [
             {:token, String.t()}
             | {bandit_option :: atom(), term()}
             | transcoding_policy_opt()
           ]}

  @typedoc "HLS (HTTP Live Streaming) input endpoint. `url` points to the HLS stream."
  @type hls_input ::
          {:hls, url :: String.t()}
          | {:hls, url :: String.t(), [hls_variant_selection_policy_opt()]}

  @typedoc """
  HLS (HTTP Live Streaming) output endpoint.

  `location` is the path where the HLS playlist will be created. If it's a
  directory, an `index.m3u8` manifest and segment files will be created there.
  If it's a `.m3u8` path, the manifest will be created at that location and
  other files in the same directory.
  """
  @type hls_output ::
          {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [hls_mode_opt() | transcoding_policy_opt()]}

  @typedoc """
  RTMP (Real-Time Messaging Protocol) input endpoint.

  Currently Boombox supports only client-side functionality — receiving
  streams from a RTMP server. `uri` can be a URL string or a PID of an
  existing RTMP client handler process.
  """
  @type rtmp :: {:rtmp, (uri :: String.t()) | (client_handler :: pid())}

  @typedoc """
  RTSP (Real-Time Streaming Protocol) input endpoint.

  Currently Boombox supports only client-side functionality — receiving
  media from a RTSP server.
  """
  @type rtsp :: {:rtsp, url :: String.t()}

  @typedoc """
  RTP (Real-time Transport Protocol) input endpoint.

  Since RTP doesn't incorporate any negotiation, media information must be
  provided manually. See `t:in_rtp_opt/0`.
  """
  @type rtp_input :: {:rtp, [in_rtp_opt()]}

  @typedoc """
  RTP (Real-time Transport Protocol) output endpoint.

  Since RTP doesn't incorporate any negotiation, media information must be
  provided manually. See `t:out_rtp_opt/0`.
  """
  @type rtp_output :: {:rtp, [out_rtp_opt()]}

  @typedoc """
  SRT (Secure Reliable Transport) input endpoint.

  Boombox acts as an SRT server and expects connections from clients at the
  provided address. `url` is an address in the form of `<ip>:<port>`.
  Alternatively, an existing `ExLibSRT.Server.t()` can be passed directly.
  """
  @type srt_input ::
          {:srt, (url :: String.t()) | (server_awaiting_accept :: ExLibSRT.Server.t())}
          | {:srt, url :: String.t(), [srt_auth_opt()]}

  @typedoc """
  SRT (Secure Reliable Transport) output endpoint.

  Boombox acts as an SRT client and connects to a server at the provided
  address. `url` is an address in the form of `<ip>:<port>`.
  """
  @type srt_output ::
          {:srt, url :: String.t()}
          | {:srt, url :: String.t(), [srt_auth_opt()]}

  @typedoc "Plays the output stream with the local SDL2 media player."
  @type player :: :player

  @typedoc """
  Defines a Boombox input endpoint.

  Available inputs:

  * `path_or_uri` - a path or URI string. The format is detected automatically
    based on the file extension or URI scheme.
  * `{path_or_uri, opts}` - a path or URI string with additional options:
    `t:hls_variant_selection_policy_opt/0` or `{:framerate, framerate}` for
    H264/H265.
  * `t:mp4_input/0`, `t:aac_input/0`, `t:wav_input/0`, `t:mp3_input/0`,
    `t:ivf_input/0`, `t:ogg_input/0` - file/HTTP storage endpoints.
  * `t:h264_input/0`, `t:h265_input/0` - raw video codec storage endpoints.
  * `t:webrtc_input/0` - WebRTC endpoint.
  * `t:whip_input/0` - WHIP endpoint.
  * `t:rtmp/0` - RTMP endpoint.
  * `t:rtsp/0` - RTSP endpoint.
  * `t:rtp_input/0` - RTP endpoint.
  * `t:hls_input/0` - HLS endpoint.
  * `t:srt_input/0` - SRT endpoint.
  """
  @type input ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(),
             [
               hls_variant_selection_policy_opt()
               | {:framerate, Membrane.H264.framerate() | Membrane.H265.framerate_t()}
             ]}
          | mp4_input()
          | aac_input()
          | wav_input()
          | mp3_input()
          | ivf_input()
          | ogg_input()
          | h264_input()
          | h265_input()
          | webrtc_input()
          | whip_input()
          | rtmp()
          | rtsp()
          | rtp_input()
          | hls_input()
          | srt_input()

  @typedoc """
  Defines an input endpoint for direct Elixir integration.

  * `{:stream, opts}` - an `Enumerable` of `t:Boombox.Packet.t/0`s is expected
    as the first argument to `Boombox.run/2`.
  * `{:writer, opts}` - `Boombox.run/2` returns a `t:Boombox.Writer.t/0` for
    writing packets via `Boombox.write/2` and finishing via `Boombox.close/1`.
  * `{:message, opts}` - `Boombox.run/2` returns a PID to communicate with.
    The process accepts:
    * `{:boombox_packet, packet}` - provides a media packet. The process sends
      `{:boombox_finished, boombox_pid}` to the sender when it has finished.
    * `:boombox_close` - signals no more packets will be provided.

  See `t:in_raw_data_opt/0` for available options.
  """
  @type elixir_input :: {:stream | :writer | :message, [in_raw_data_opt()]}

  @typedoc """
  Defines a Boombox output endpoint.

  Available outputs:

  * `path_or_uri` - a path or URI string. The format is detected automatically
    based on the file extension or URI scheme.
  * `{path_or_uri, opts}` - a path or URI string with additional options:
    `t:transcoding_policy_opt/0` or `t:hls_mode_opt/0` for HLS.
  * `t:mp4_output/0`, `t:aac_output/0`, `t:wav_output/0`, `t:mp3_output/0`,
    `t:ivf_output/0`, `t:ogg_output/0` - file storage endpoints.
  * `t:h264_output/0`, `t:h265_output/0` - raw video codec storage endpoints.
  * `t:webrtc_output/0` - WebRTC endpoint.
  * `t:whip_output/0` - WHIP endpoint.
  * `t:hls_output/0` - HLS endpoint.
  * `t:rtp_output/0` - RTP endpoint.
  * `t:srt_output/0` - SRT endpoint.
  * `t:player/0` - plays the stream with the local media player.
  """
  @type output ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(), [transcoding_policy_opt() | hls_mode_opt()]}
          | mp4_output()
          | aac_output()
          | wav_output()
          | mp3_output()
          | ivf_output()
          | ogg_output()
          | h264_output()
          | h265_output()
          | webrtc_output()
          | whip_output()
          | hls_output()
          | rtp_output()
          | srt_output()
          | player()

  @typedoc """
  Defines an output endpoint for direct Elixir integration.

  * `{:stream, opts}` - `Boombox.run/2` returns a `Stream` of
    `t:Boombox.Packet.t/0`s.
  * `{:reader, opts}` - `Boombox.run/2` returns a `t:Boombox.Reader.t/0` for
    reading packets via `Boombox.read/1` and stopping via `Boombox.close/1`.
  * `{:message, opts}` - `Boombox.run/2` returns a PID to communicate with.
    The process sends:
    * `{:boombox_packet, boombox_pid, packet}` - a `t:Boombox.Packet.t/0`
      produced by Boombox.
    * `{:boombox_finished, boombox_pid}` - Boombox has finished producing
      packets and will terminate. No more messages will be sent.

  See `t:out_raw_data_opt/0` for available options.
  """
  @type elixir_output :: {:stream | :reader | :message, [out_raw_data_opt()]}
end
