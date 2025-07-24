"""Boombox endpoints.

Endpoints are classes defining possible inputs and outputs of
:py:class:`.Boombox`. Each endpoint represents a different media format and has
appropriate attributes that describe it.

Examples:
  * MP4("path/to/file.mp4") - an endpoint defining an MP4 container. If
    provided for input, then Boombox will read a MP4 file from this location. If
    provided for output, then Boombox will create a file at that location and
    store the produced stream in it in MP4 format.
  * HLS("path/to/playlist") - an endpoint defining a HLS playlist. Only
    output is supported. If used, a playlist will be created in the specified
    location.
  * WebRTC("ws://host:port") - an endpoint defining a WebRTC connection.
    Both input and output is supported. Websocket at the provided URL is used as
    a signaling channel.

"""

from dataclasses import dataclass, KW_ONLY, fields, is_dataclass
from term import Atom
from typing import Any, Literal
from typing_extensions import override
from abc import ABC


@dataclass
class BoomboxEndpoint(ABC):
    """Abstract base class of a Boombox endpoint.

    Boombox endpoints are the definitions of Boombox inputs and outputs. This
    class is a base class for these definitions. When creating a Boombox
    instance it expects a specification of it's input and output as
    BoomboxEndpoints.

    Attributes
    ----------
    transcoding_policy : {None, "if_needed", "always", "never"}
        Allowed only for output. The default transcoding behavior is "if_needed",
        which means that if the format of the media is the same for input and
        output, then the stream is not decoded and encoded. This approach saves
        resources and time, but in some cases transcoding can be necessary. To
        force transcoding regardless if the formats differ or not, this option
        can be set to "always". If set to "never", Boombox will never transcode,
        raising if the desired operation can't be done without transcoding.
    """

    _: KW_ONLY
    transcoding_policy: Literal["if_needed", "always", "never"] | None = None

    def get_atom_fields(self) -> set[str]:
        """:meta private:"""
        return {"transcoding_policy"}

    # TODO: consider checking whether an endpoint with given attributes is
    #  valid for a direction, like so:
    # def validate_direction(self, direction: Literal['input', 'output']) ->
    # bool: ...

    def serialize(self) -> tuple:
        """Serializes itself to an Elixir-compatible term.

        To allow Pyrlang to send the endpoint definition to Elixir it first
        needs to be serialized into an Elixir-compatible term. This function
        serializes the endpoint to a tuple that matches the structure of
        Boombox endpoints in Elixir.

        Returns
        -------
        endpoint_tuple : tuple
            A tuple representing the endpoint. The first element is an Atom
            representing the endpoint name, next elements are required field
            values and in case there are any keyword fields they are in the
            last element.
        """

        assert is_dataclass(self)
        atom_fields = self.get_atom_fields()
        required_field_values = [
            self._serialize_field(f.name, atom_fields)
            for f in fields(self)
            if not f.kw_only
        ]
        keyword_fields = [
            (Atom(f.name), self._serialize_field(f.name, atom_fields))
            for f in fields(self)
            if f.kw_only and self.__dict__[f.name] is not None
        ]
        if keyword_fields:
            return (self.get_endpoint_name(), *required_field_values, keyword_fields)
        else:
            return (self.get_endpoint_name(), *required_field_values)

    def get_endpoint_name(self) -> Atom:
        """:meta private:"""
        return Atom(self.__class__.__name__.lower())

    def _serialize_field(self, field_name: str, atom_fields: set[str]) -> Any:
        field_value = self.__dict__[field_name]
        if not isinstance(field_value, str):
            return field_value
        elif field_name in atom_fields:
            return Atom(field_value)
        else:
            return field_value.encode()


@dataclass
class RawData(BoomboxEndpoint):
    """Endpoint for communication through numpy arrays containing raw media
    data.

    This endpoint defines the behavior of Boombox allowing for interacting
    with Python code directly. For more details refer to
    :py:class:`.Boombox` class.

    Attributes
    ----------
    audio, video : bool
        Determines whether this endpoint will accept/produce video packets,
        audio packets, or both.
    audio_rate : int, optional
        Applicable only when `audio` is set to True and the endpoint defines
        the output. Determines the sample rate of the produced stream (number
        of samples per second).
    audio_channels : int, optional
        Applicable only when `audio` is set to True and the endpoint defines
        the output. Determines how many channels does the produced stream have.
        The channels are interleaved.
    video_width, video_height : int, optional
        Applicable only when `video` is set to True and the endpoint defines
        the output. Determines the dimensions of the produced video stream.
    """

    _: KW_ONLY
    audio: bool
    video: bool
    audio_rate: int | None = None
    audio_channels: int | None = None
    video_width: int | None = None
    video_height: int | None = None

    @override
    def get_endpoint_name(self) -> Atom:
        return Atom("stream")

    @override
    def get_atom_fields(self) -> set[str]:
        return {"audio_format"} | super().get_atom_fields()


@dataclass
class StorageEndpoint(BoomboxEndpoint, ABC):
    """Abstract base class for storage endpoints.

    Storage endpoints are endpoints that are used for putting the media in
    some type of storage.

    Attributes
    ----------
    location : str
        A path to a file or an HTTP URL, location where the media should be
        read from or written to.
    transport : {None, "file", "http"}:
        An optional attribute that explicitly states whether a file or HTTP
        storage should be assumed. If not provided transport will be determined
        from `location` - paths will resolve to "file" location,
        HTTP URLs to "http".
    """

    location: str
    _: KW_ONLY
    transport: Literal["file", "http"] | None = None

    @override
    def get_atom_fields(self) -> set[str]:
        return {"transport"} | super().get_atom_fields()


@dataclass
class H264(StorageEndpoint):
    """Storage endpoint for H264 codec.

    When used for output the stored stream will have Annex-B format, and when
    reading the stream has to already be in Annex-B format.

    Attributes
    ----------
    framerate : tuple[int, int], optional
        Framerate of the stream, if not provided 30 FPS will be assumed.
    """

    _: KW_ONLY
    framerate: tuple[int, int] | None = None


@dataclass
class H265(StorageEndpoint):
    """Storage endpoint for H265 codec.

    When used for output the stored stream will have Annex-B format, when
    reading the stream has to already be in Annex-B format.


    Attributes
    ----------
    framerate : tuple[int, int], optional
        Framerate of the stream, if not provided 30 FPS will be assumed.
    """

    _: KW_ONLY
    framerate: tuple[int, int] | None = None


@dataclass
class MP4(StorageEndpoint):
    """Endpoint for MP4 container format."""

    pass


@dataclass
class AAC(StorageEndpoint):
    """Endpoint for AAC codec."""

    pass


@dataclass
class WAV(StorageEndpoint):
    """Endpoint for WAV format."""

    pass


@dataclass
class MP3(StorageEndpoint):
    """Endpoint for MP3 format."""

    pass


@dataclass
class IVF(StorageEndpoint):
    """Endpoint for IVF container format."""

    pass


@dataclass
class Ogg(StorageEndpoint):
    """Endpoint for Ogg container format."""

    pass


@dataclass
class WebRTC(BoomboxEndpoint):
    """Endpoint for communication over WebRTC.

    Attributes
    ----------
    signaling : str
        URL of the WebSocket that is the signaling channel of the WebRTC
        connection.
    """

    signaling: str


@dataclass
class WHIP(BoomboxEndpoint):
    """Endpoint for communication over WebRTC-HTTP ingestion protocol (WHIP).

    Attributes
    ----------
    url : str
        HTTP url for the WHIP server.
    token : str
        Token used for authentication and authorization.
    """

    url: str
    _: KW_ONLY
    token: str


@dataclass
class HLS(BoomboxEndpoint):
    """Endpoint for HTTP Live Streaming.

    Currently Boombox supports only HLS output - creating playlists.

    Attributes
    ----------
    location : str
        Path to the location where the HLS playlist will be created. If the
        path is to a directory, then an "index.m3u8" manifest file and the
        other files will be created there. If it's a path to ".m3u8" file,
        the file will be created in provided location and all the other
        files will be created in the same directory.
    """

    location: str


@dataclass
class RTMP(BoomboxEndpoint):
    """Endpoint for communication over Real-Time Messaging Protocol (RTMP).

    Currently Boombox supports only client-side functionality - streaming
    media to a RTMP server.

    Attributes
    ----------
    url : str
        URL of a RTMP server.
    """

    url: str


@dataclass
class RTSP(BoomboxEndpoint):
    """Endpoint for communication over Real-Time Streaming Protocol (RTSP).

    Currently Boombox supports only client-side functionality - receiving
    media from a RTSP server.

    Attributes
    ----------
    url : str
        URL of a RTSP server.
    """

    url: str


@dataclass
class RTP(BoomboxEndpoint):
    """Endpoint for communication over Real-time Transport Protocol (RTP).

    Since RTP doesn't incorporate any negotiation a lot of information about
    streamed media has to be provided manually via the attributes.

    Attributes
    ----------
    port : int
        Port on which Boombox will receive the stream or to which it will
        send it to.
    address : str, optional
        IP address which Boombox will send the stream to.
    audio_encoding, video_encoding : str, optional
        Encoding name of given media type. Has to be the same as it would be
        in `rtpmap` attribute of a SDP description.
    audio_payload_type, video_payload_type : int, optional
        Payload type of given media type. Has to be the same as it would be
        in `rtpmap` attribute of a SDP description.
    audio_clock_rate, video_clock_rate : int, optional
        Clock rate of given media type. Has to be the same as it would be
        in `rtpmap` attribute of a SDP description.
    aac_bitrate_mode : {None, "lbr", "hbr"}
        Applicable only for AAC payload. Defines which mode should be
        assumed/set when depayloading/payloading.
    audio_specific_config : bytes, optional
        Applicable only for AAC payload. Contains crucial information about
        the stream and has to be obtained from a side channel.
    vps, pps, sps : bytes, optional
        Applicable only for H264 and H265 payloads. Parameter sets, could be
        obtained from a side channel. They contain information about the
        encoded stream.
    """

    _: KW_ONLY
    port: int
    address: str | None = None
    video_encoding: str | None = None
    video_payload_type: int | None = None
    video_clock_rate: int | None = None
    audio_encoding: str | None = None
    audio_payload_type: int | None = None
    audio_clock_rate: int | None = None
    aac_bitrate_mode: Literal["lbr", "hbr"] | None = None
    audio_specific_config: bytes | None = None
    vps: bytes | None = None
    pps: bytes | None = None
    sps: bytes | None = None

    @override
    def get_atom_fields(self) -> set[str]:
        return {
            "video_encoding",
            "audio_encoding",
            "aac_bitrate_mode",
        } | super().get_atom_fields()
