from dataclasses import dataclass, KW_ONLY, fields, is_dataclass
from term import Atom
from typing import Any, Literal
from typing_extensions import override
from abc import ABC


class BoomboxEndpoint(ABC):
    """Abstract base class of a Boombox endpoint.

    Boombox endpoints are the definitions of Boombox inputs and outputs. This
    class is a base class for these definitions. When creating a Boombox
    instance it expects a specification of it's input and output as
    BoomboxEndpoints.
    """

    # TODO: consider checking whether an endpoint with given attributes is
    #  valid for a direction, like so:
    # def validate_direction(self, direction: Literal['input', 'output']) ->
    # bool: ...

    def serialize(self) -> tuple:
        """Serializes itself to an erlang-compatible term.

        To allow Pyrlang to send the endpoint definition to erlang it first
        needs to be serialized into an erlang-compatible term. This function
        serializes the endpoint to a tuple that matches the structure of
        Boombox endpoints in elixir.

        Returns:
            A tuple representing the endpoint. The first element is an Atom
            representing the endpoint name, next elements are required field
            values and in case there are any keyword fields they are in the
            last element.
        """

        assert is_dataclass(self)
        atom_fields = self._get_atom_fields()
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
        if not keyword_fields:
            return self._get_endpoint_name(), *required_field_values
        else:
            return (self._get_endpoint_name(), *required_field_values,
                    keyword_fields)

    def _get_endpoint_name(self) -> Atom:
        return Atom(self.__class__.__name__.lower())

    def _get_atom_fields(self) -> set[str]:
        return set()

    def _serialize_field(self, field_name: str, atom_fields: set[str]) -> Any:
        field_value = self.__dict__[field_name]
        if not isinstance(field_value, str):
            return field_value
        elif field_name in atom_fields:
            return Atom(field_value)
        else:
            return field_value.encode()


@dataclass
class StorageEndpoint(BoomboxEndpoint, ABC):
    """Abstract base class for storage endpoints.

    Storage endpoints are endpoints that are used for putting the media in
    some type of storage.

    Attributes:
        location:
          A path to a file or an HTTP URL, location where the media should be
          read from or written to.
        transport:
          An optional attribute that explicitly states whether a file or HTTP
          storage should be assumed.
    """

    location: str
    _: KW_ONLY
    transport: Literal['file', 'http'] | None = None

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'transport'}


@dataclass
class H264(StorageEndpoint):
    """Storage endpoint for H264 codec.

    When used for output the stored stream will have Annex-B format, and when
    reading the stream has to already be in Annex-B format.

    Attributes:
        framerate:
          Framerate of the stream, if not provided 30 FPS will be assumed.
    """

    _: KW_ONLY
    framerate: tuple[int, int] | None = None


@dataclass
class H265(StorageEndpoint):
    """Storage endpoint for H265 codec.

    When used for output the stored stream will have Annex-B format, when
    reading the stream has to already be in Annex-B format.

    Attributes:
        framerate:
          Framerate of the stream, if not provided 30 FPS will be assumed.
    """

    _: KW_ONLY
    framerate: tuple[int, int] | None = None


@dataclass
class MP4(BoomboxEndpoint):
    """Endpoint for MP4 container format.

    Attributes:
        force_transcoding:
          Allowed only for output. The default transcoding behavior is that if
          the format of the media is the same for input and output, then the
          stream is not decoded and encoded. This approach saves resources and
          time, but in some cases transcoding can be necessary. This attribute
          determines whether Boombox should transcode audio, video or both.
        """

    force_transcoding: bool | Literal['audio', 'video'] | None = None


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

    Attributes:
        signaling:
          URL of the WebSocket that is the signaling channel of the WebRTC
          connection.
        force_transcoding:
          Allowed only for output. The default transcoding behavior is that if
          the format of the media is the same for input and output, then the
          stream is not decoded and encoded. This approach saves resources and
          time, but in some cases transcoding can be necessary. This attribute
          determines whether Boombox should transcode audio, video or both.
    """
    signaling: str
    _: KW_ONLY
    force_transcoding: bool | Literal['audio', 'video'] | None = None

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'force_transcoding'}


@dataclass
class WHIP(BoomboxEndpoint):
    """Endpoint for communication over WHIP.

    Attributes:
        url: HTTP url for the WHIP server.
        token: Token used for authentication and authorization.
    """
    url: str
    _: KW_ONLY
    token: str


@dataclass
class HLS(BoomboxEndpoint):
    location: str
    _: KW_ONLY
    force_transcoding: bool | Literal['audio', 'video'] | None = None

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'force_transcoding'}


@dataclass
class RTMP(BoomboxEndpoint):
    uri: str


@dataclass
class RTSP(BoomboxEndpoint):
    uri: str
    _: KW_ONLY
    force_transcoding: bool | Literal['audio', 'video'] | None = None

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'force_transcoding'}


@dataclass
class RTP(BoomboxEndpoint):
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
    force_transcoding: bool | Literal['audio', 'video'] | None = None

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'video_encoding', 'audio_encoding', 'force_transcoding'}


@dataclass
class Array(BoomboxEndpoint):
    _: KW_ONLY
    audio: bool = False
    video: bool = False
    audio_format: str | None = None
    audio_rate: int | None = None
    audio_channels: int | None = None
    video_width: int | None = None
    video_height: int | None = None

    @override
    def _get_endpoint_name(self) -> Atom:
        return Atom('stream')

    @override
    def _get_atom_fields(self) -> set[str]:
        return {'audio_format'}
