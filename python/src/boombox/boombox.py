"""Boombox class and Packet classes."""

from __future__ import annotations

import numpy as np
import asyncio
import pyrlang.process
import pyrlang.node
import uuid
import subprocess
import atexit
import os
import sys
import warnings

from term import Atom, Pid
from .endpoints import BoomboxEndpoint, Array
from dataclasses import dataclass, KW_ONLY

from typing import Generator, ClassVar, TypeAlias, Literal, Optional, Any, get_args
from typing_extensions import override

AudioSampleFormat: TypeAlias = Literal[
    "s8",
    "u8",
    "s16le",
    "u16le",
    "s16be",
    "u16be",
    "s24le",
    "u24le",
    "s24be",
    "u24be",
    "s32le",
    "u32le",
    "s32be",
    "u32be",
    "f32le",
    "f32be",
    "f64le",
    "f64be",
]


class Boombox(pyrlang.process.Process):
    """Boombox class.

    Blah blah
    """

    _python_node_name: ClassVar[str]
    _cookie: ClassVar[str]

    _process_name: Atom
    _erlang_node_name: Atom
    _receiver: tuple[Atom, Atom] | Pid
    _response_received: Optional[asyncio.Future]
    _finished: asyncio.Future
    _erlang_process: subprocess.Popen
    _audio_stream_format: dict[Atom, Any] | None

    _python_node_name = f"{uuid.uuid4()}@127.0.0.1"
    _cookie = str(uuid.uuid4())
    pyrlang.node.Node(node_name=_python_node_name, cookie=_cookie)

    def __init__(
        self, input: BoomboxEndpoint | str, output: BoomboxEndpoint | str
    ) -> None:
        self._process_name = Atom(uuid.uuid4())
        self._erlang_node_name = Atom(f"{self._process_name}@127.0.0.1")
        env = {
            "NODE_TO_PING": self._python_node_name,
            "RELEASE_NODE": self._erlang_node_name,
            "RELEASE_COOKIE": self._cookie,
            "RELEASE_DISTRIBUTION": "name",
        }
        release_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "erlang", "bin", "server"
        )
        self._erlang_process = subprocess.Popen([release_path, "start"], env=env)
        atexit.register(lambda: self._erlang_process.kill())

        pyrlang.process.Process.__init__(self)
        self.get_node().register_name(self, self._process_name)
        self._finished = self.get_node().get_loop().create_future()
        self._receiver = (self._erlang_node_name, Atom("boombox_server"))
        self._receiver = self._call(Atom("get_pid"))
        if isinstance(input, Array) and input.audio:
            self._audio_stream_format = {
                Atom("sample_format"): None,
                Atom("sample_rate"): input.audio_rate,
                Atom("channels"): input.audio_channels,
            }
        else:
            self._audio_stream_format = None

        boombox_arg = [
            (Atom("input"), self._serialize_endpoint(input)),
            (Atom("output"), self._serialize_endpoint(output)),
        ]
        self._call((Atom("run"), boombox_arg))
        self.get_node().link_nowait(self.pid_, self._receiver)

    def write(self, packet: AudioPacket | VideoPacket) -> None:
        serialized_packet = self._serialize_packet(packet)

        self._call((Atom("consume_packet"), serialized_packet))

    def read(self) -> Generator[AudioPacket | VideoPacket, None, None]:
        production_phase = Atom("ok")
        while production_phase != Atom("finished"):
            production_phase, packet = self._call(Atom("produce_packet"))
            deserialized_packet = self._deserialize_packet(packet)
            yield deserialized_packet

    def close(self, wait: bool = False, kill: bool = False) -> None:
        self._call(Atom("finish_consuming"))
        if wait:
            self.wait()
        elif kill:
            self.kill()

    def wait(self) -> None:
        self.get_node().get_loop().run_until_complete(self._finished)

    def kill(self) -> None:
        self._erlang_process.kill()

    @override
    def handle_one_inbox_message(self, msg: Any) -> None:
        """:meta private:"""
        if self._response_received is not None:
            self._response_received.set_result(msg)

    @override
    def exit(self, reason: Any = None) -> None:
        """:meta private:"""
        self._finished.set_result(None)
        super().exit(reason)

    def _call(self, message: Any) -> Any:
        message = (
            Atom("call"),
            (Atom(self._process_name), Atom(self.node_name_)),
            message,
        )

        self.get_node().send_nowait(
            sender=self, receiver=self._receiver, message=message
        )
        self._response_received = self.get_node().get_loop().create_future()
        return self.get_node().get_loop().run_until_complete(self._response_received)

    def _dtype_to_sample_format(
        self, dtype: np.dtype
    ) -> tuple[AudioSampleFormat, np.dtype]:
        match dtype.kind:
            case "i":
                data_type = "s"
            case "u":
                data_type = "u"
            case "f":
                data_type = "f"
            case other:
                warnings.warn(
                    f"Arrays of dtype.kind == {other} not allowed, supported kinds are 'i', 'u', 'f', casting to 'f'."
                )
                data_type = "f"

        match dtype.itemsize:
            case 1 | 2 | 4 | 8:
                bit_size = str(dtype.itemsize * 8)
            case other:
                warnings.warn(
                    f"Item size {dtype.itemsize} not allowed, supported item sizes are 1, 2, 4 and 8, casting to 4"
                )
                bit_size = "32"

        match dtype.byteorder:
            case "<":
                endian = "le"
            case ">":
                endian = "be"
            case "=":
                endian = "le" if sys.byteorder == "little" else "be"
            case "|":
                endian = ""

        sample_format = data_type + bit_size + endian
        # trick to ensure that sample_format is of AudioSampleFormat type
        audio_sample_formats: tuple[AudioSampleFormat, ...] = get_args(
            AudioSampleFormat
        )
        assert sample_format in audio_sample_formats

        new_dtype = self._sample_format_to_dtype(sample_format)

        return sample_format, new_dtype

    def _sample_format_to_dtype(self, sample_format: AudioSampleFormat) -> np.dtype:
        type_mapping = {"s": "i", "u": "u", "f": "f"}

        if len(sample_format) == 2:  # Handle 8-bit case (without endian)
            data_type = sample_format[0]
            dtype_str = type_mapping[data_type] + "1"
        else:
            data_type, bit_size, endian = (
                sample_format[0],
                sample_format[1:-2],
                sample_format[-2:],
            )
            endian_symbol = "<" if endian == "le" else ">"
            # numpy doesn't support 24-bit size values
            bit_size = 32 if bit_size == "24" else int(bit_size)
            dtype_str = (
                endian_symbol + type_mapping[data_type] + str(int(bit_size) // 8)
            )

        return np.dtype(dtype_str)

    def _bytes_to_array(
        self, data: bytes, sample_format: AudioSampleFormat
    ) -> np.ndarray:
        dtype = self._sample_format_to_dtype(sample_format)
        if sample_format not in ["s24le", "u24le", "s24be", "u24be"]:
            return np.frombuffer(data, dtype)
        else:
            # numpy doesn't support 24-bit samples, this transforms them to 32-bit.
            endian = "little" if sample_format[-2:] == "le" else "big"
            is_signed = sample_format[0] == "s"
            return np.array(
                int.from_bytes(data[i : i + 3], endian, signed=is_signed)
                for i in range(0, len(data), 3)
            )

    def _deserialize_packet(self, packet: dict[Atom, Any]) -> AudioPacket | VideoPacket:
        media_type, payload = packet[Atom("payload")]
        if media_type == Atom("audio"):
            deserialized_payload = self._bytes_to_array(
                payload[Atom("data")], payload[Atom("sample_format")]
            )

            return AudioPacket(
                deserialized_payload,
                packet[Atom("timestamp")],
                sample_rate=payload[Atom("sample_rate")],
                channels=payload[Atom("channels")],
            )
        else:
            shape = (
                payload[Atom("height")],
                payload[Atom("width")],
                payload[Atom("channels")],
            )
            deserialized_payload = np.frombuffer(
                payload[Atom("data")], np.uint8
            ).reshape(shape)
            return VideoPacket(deserialized_payload, packet[Atom("timestamp")])

    def _serialize_packet(self, packet: AudioPacket | VideoPacket) -> dict[Atom, Any]:
        match packet:
            case AudioPacket():
                sample_format, new_dtype = self._dtype_to_sample_format(
                    packet.payload.dtype
                )
                assert self._audio_stream_format is not None
                self._audio_stream_format[Atom("sample_format")] = Atom(sample_format)

                if packet.sample_rate is not None:
                    self._audio_stream_format[Atom("sample_rate")] = packet.sample_rate
                if packet.channels is not None:
                    self._audio_stream_format[Atom("channels")] = packet.channels

                serialized_payload = (
                    Atom("audio"),
                    {
                        Atom("data"): packet.payload.astype(new_dtype).tobytes(),
                        **self._audio_stream_format,
                    },
                )
            case VideoPacket():
                # frame shape (width, height, channels)
                if len(packet.payload.shape) == 2:
                    height, width = packet.payload.shape
                    frame = packet.payload.reshape(width, height, 1)

                frame = packet.payload.clip(0, 255)
                raw_frame = frame.tobytes()
                serialized_payload = (
                    Atom("video"),
                    {
                        Atom("data"): raw_frame,
                        Atom("height"): frame.shape[0],
                        Atom("width"): frame.shape[1],
                        Atom("channels"): frame.shape[2],
                    },
                )

        return {
            Atom("payload"): serialized_payload,
            Atom("timestamp"): packet.timestamp,
        }

    def _serialize_endpoint(self, endpoint: BoomboxEndpoint | str) -> Any:
        if isinstance(endpoint, str):
            return endpoint.encode()
        else:
            return endpoint.serialize()


@dataclass
class VideoPacket:
    """A Boombox packet containing raw video.

    When writing to or reading video from Boombox it will
    be in form of numpy arrays of shape (width, height, channels).
    """

    payload: np.ndarray
    timestamp: int


@dataclass
class AudioPacket:
    """A Boombox packet containing raw audio.

    When writing to or reading video from Boombox it will
    be in form of numpy arrays.
    """

    payload: np.ndarray
    timestamp: int
    _: KW_ONLY
    sample_rate: int | None = None
    channels: int | None = None
