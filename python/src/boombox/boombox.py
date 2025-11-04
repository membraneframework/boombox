"""Module containing Boombox class and media packet classes."""

from __future__ import annotations

import numpy as np
import asyncio
import uuid
import subprocess
import atexit
import os
import sys
import warnings
import dataclasses
import threading
import tqdm
import urllib.request
import platformdirs
import platform
import importlib.metadata
import tarfile
import logging

from ._vendor.pyrlang import process, node
from ._vendor.term import Atom, Pid
from .endpoints import BoomboxEndpoint, AudioSampleFormat

from typing import Generator, ClassVar, Optional, Any, get_args
from typing_extensions import override


RELEASES_URL = "https://github.com/membraneframework/boombox/releases"
PACKAGE_NAME = "boomboxlib"


class Boombox(process.Process):
    """
    Boombox is a tool that allows to transform a media stream from one
    format into another.

    When creating an instance of Boombox the input and output are
    specified by providing an appropriate endpoint object for each of them.
    These objects define the format and its parameters that are used for
    the input or output, whichever they were provided for.

    For example, if an ``RTMP("rtmp://my.stream.source:2137/app/key")`` endpoint
    was provided for input and ``MP4("path/to/target.mp4")`` for output, then
    Boombox will become a RTMP server, wait for clients to connect and save
    the acquired stream to a ``.mp4`` file at the provided location.

    Input and output can also be specified by strings alone, as in
    ``"rtmp://my.stream.source:2137/app/key"`` or ``"path/to/target.mp4"``,
    and Boombox will automatically interpret them as :py:class:`.RTMP` and
    :py:class:`.MP4` endpoints.

    For more information about endpoints and to see supported formats refer to
    :py:mod:`.endpoints`.

    One of the main reasons to use Boombox in a Python project is to interact
    with it from Python code directly. This can be achieved with
    :py:class:`.RawData` endpoint, that enables methods allowing for this
    interactions.

    If the input is defined by :py:class:`.RawData`, Boombox will accept packets
    provided by :py:meth:`.write` method. This method will return once Boombox
    has processed the provided packet and is ready for the next one. Once
    Boombox should stop accepting more packets, :py:meth:`.close` should be
    called to informing it about the end of the stream. Calling this method can
    be skipped if opening Boombox using a context manager.

    If the output is defined by :py:class:`.RawData`, Boombox will produce
    packets that are yielded by a generator returned by :py:meth:`.read`.

    These methods operate on :py:class:`.AudioPacket` and
    :py:class:`.VideoPacket` objects. These objects contain raw media data and
    accompanying metadata.

    If not using :py:class:`.RawData` endpoints Boombox operates fully
    asynchronously, it'll work in the background if not interacted with. For
    more control regarding the termination of Boombox refer to
    :py:meth:`.close`, :py:meth:`.wait` and :py:meth:`.kill` methods.

    Parameters
    ----------
    input, output : BoomboxEndpoint or str
        Definition of an input or output of Boombox. Can be provided explicitly
        by an appropriate :py:class:`.BoomboxEndpoint` or a string of a path to
        a file or an URL, that Boombox will attempt to interpret as an endpoint.
    """

    _python_node_name: ClassVar[str]
    _cookie: ClassVar[str]

    _data_dir: str
    _server_release_path: str
    _version: str
    _process_name: Atom
    _erlang_node_name: Atom
    _receiver: tuple[Atom, Atom] | Pid
    _response: Optional[asyncio.Future]
    _terminated: asyncio.Future
    _finished: bool
    _erlang_process: subprocess.Popen

    _python_node_name = f"{uuid.uuid4()}@127.0.0.1"
    _cookie = str(uuid.uuid4())
    _node = node.Node(node_name=_python_node_name, cookie=_cookie)
    threading.Thread(target=_node.run, daemon=True).start()

    def __init__(
        self, input: BoomboxEndpoint | str, output: BoomboxEndpoint | str
    ) -> None:
        self._process_name = Atom(uuid.uuid4())
        self._erlang_node_name = Atom(f"{self._process_name}@127.0.0.1")
        env = {
            "BOOMBOX_NODE_TO_PING": self._python_node_name,
            "RELEASE_NODE": self._erlang_node_name,
            "RELEASE_COOKIE": self._cookie,
            "RELEASE_DISTRIBUTION": "name",
        }

        self._download_elixir_boombox_release()

        self._erlang_process = subprocess.Popen([self._server_release_path, "start"], env=env)
        atexit.register(lambda: self._erlang_process.kill())

        super().__init__(True)
        self.get_node().register_name(self, self._process_name)
        self._terminated = self.get_node().get_loop().create_future()
        self._finished = False
        self._receiver = (self._erlang_node_name, Atom("boombox_server"))
        self._receiver = self._call(Atom("get_pid"))
        self.get_node().monitor_process(self.pid_, self._receiver)

        boombox_arg = [
            (Atom("input"), self._serialize_endpoint(input)),
            (Atom("output"), self._serialize_endpoint(output)),
        ]
        self._call((Atom("run"), boombox_arg))

    def read(self) -> Generator[AudioPacket | VideoPacket, None, None]:
        """Read media packets produced by Boombox.

        Enabled only if Boombox has been initialized with output defined with
        an :py:class:`.RawData` endpoint.

        This generator yields packets as fast as Boombox produces them.

        Yields
        ------
        AudioPacket or VideoPacket
            Raw media packets produced by Boombox.

        Raises
        ------
        RuntimeError
            If Boombox's output was not defined by an :py:class:`.RawData` endpoint.
        """
        while True:
            match self._call(Atom("produce_packet")):
                case (Atom("ok"), packet):
                    yield self._deserialize_packet(packet)
                case (Atom("finished"), packet):
                    yield self._deserialize_packet(packet)
                    return
                case (Atom("error"), Atom("incompatible_mode")):
                    raise RuntimeError("Output not defined with an RawData endpoint.")
                case other:
                    raise RuntimeError(f"Unknown response: {other}")

    def write(self, packet: AudioPacket | VideoPacket) -> bool:
        """Write packets to Boombox.

        Enabled only if Boombox has been initialized with input defined with an
        :py:class:`.RawData` endpoint and if Boombox hasn't already finished
        accepting packets.

        This method provides Boombox with a packet to process and returns once
        Boombox is ready to accept the next packet.

        Parameters
        ----------
        packet : AudioPacket or VideoPacket
            Raw media packet to be consumed by Boombox.

        Returns
        -------
        finished : bool
            Informs if Boombox has finished accepting packets and closed its
            input for any further ones. Once it finishes processing the
            previously provided packet, it will terminate.

        Raises
        ------
        RuntimeError
            If Boombox's input was not defined with an :py:class:`.RawData`
            endpoint or if Boombox has already finished accepting packets.
        """
        if self._finished:
            raise RuntimeError("Boombox has already finished accepting packets.")

        serialized_packet = self._serialize_packet(packet)

        match self._call((Atom("consume_packet"), serialized_packet)):
            case Atom("finished"):
                self._finished = True
                return True
            case Atom("ok"):
                return False
            case (Atom("error"), Atom("incompatible_mode")):
                raise RuntimeError("Input should be defined with an RawData endpoint.")
            case other:
                raise RuntimeError(f"Unknown response: {other}")

    def close(self, wait: bool = True, kill: bool = False) -> None:
        """Closes Boombox for writing.

        Enabled only if Boombox has been initialized with input defined with an
        :py:class:`.RawData` endpoint.

        This method informs Boombox that it shouldn't expect any more packets.

        Parameters
        ----------
        wait : bool, default=True
            Determines whether this method should wait until Boombox finishes
            it's operation and only then return, or if it should return
            immediately and let Boombox finish in the background. Ignored if
            `kill` set to true.
        kill : bool, default=False
            Determines whether Boombox should be killed without waiting for it
            to gracefully finish it's operation. If True this method will
            return immediately.

        Raises
        ------
        RuntimeError
            If Boombox's input was not defined with an :py:class:`.RawData`
            endpoint.
        """
        match self._call(Atom("finish_consuming")):
            case Atom("finished"):
                if kill:
                    self.kill()
                elif wait:
                    self.wait()
            case (Atom("error"), Atom("incompatible_mode")):
                raise RuntimeError("Input should be defined with an RawData endpoint.")
            case other:
                raise RuntimeError(f"Unknown response: {other}")

    def wait(self) -> None:
        """Waits until Boombox finishes it's operation and then returns."""
        asyncio.run_coroutine_threadsafe(
            self._await_future(self._terminated), self.get_node().get_loop()
        ).result()

    def kill(self) -> None:
        """Forces Boombox to exit without waiting for it to gracefully finish
        it's operation."""
        self._erlang_process.kill()

    def __enter__(self) -> Boombox:
        return self

    def __exit__(self, *_) -> None:
        self.close()

    @override
    def handle_one_inbox_message(self, msg: Any) -> None:
        """:meta private:"""
        assert self._response is not None
        match msg:
            case (Atom("response"), response):
                if not self._response.done():
                    self._response.set_result(response)
            case (Atom("DOWN"), _, Atom("process"), _, Atom("normal")):
                self._terminated.set_result(Atom("normal"))
            case (Atom("DOWN"), _, Atom("process"), _, reason):
                self._terminated.set_result(reason)
                if not self._response.done():
                    self._response.set_exception(
                        RuntimeError(f"Boombox crashed with reason {reason}")
                    )

    @override
    def exit(self, reason: Any = None) -> None:
        """:meta private:"""
        self._terminated.set_result(None)
        super().exit(reason)

    def _call(self, request: Any) -> Any:
        message = (
            Atom("call"),
            (Atom(self._process_name), Atom(self.node_name_)),
            request,
        )

        self._handle_termination()
        self.get_node().send_nowait(
            sender=self, receiver=self._receiver, message=message
        )
        self._response = self.get_node().get_loop().create_future()
        response = asyncio.run_coroutine_threadsafe(
            self._await_future(self._response), self.get_node().get_loop()
        ).result()
        self._handle_termination()
        return response

    def _handle_termination(self) -> None:
        if self._terminated.done():
            if (reason := self._terminated.result()) != Atom("normal"):
                raise RuntimeError(f"Boombox crashed with reason {reason}")

    async def _await_future(self, response_future):
        return await response_future

    def _download_elixir_boombox_release(self) -> None:
        class TqdmUpTo(tqdm.tqdm):
            def update_to(self, b=1, bsize=1, tsize=None):
                if tsize is not None:
                    self.total = tsize
                self.update(b * bsize - self.n)

        try:
            self._version = importlib.metadata.version(PACKAGE_NAME)
        except importlib.metadata.PackageNotFoundError:
            self._version = "dev"

        self._data_dir = platformdirs.user_data_dir(
            appname=PACKAGE_NAME, ensure_exists=True, version=self._version
        )
        self._server_release_path = os.path.join(self._data_dir, "bin", "server")

        if os.path.exists(self._server_release_path):
            logging.info("Elixir boombox release already present.")
            return
        logging.info("Elixir boombox release not found, downloading...")

        if self._version == "dev":
            release_url = os.path.join(RELEASES_URL, "latest/download")
        else:
            release_url = os.path.join(RELEASES_URL, f"download/v{self._version}")

        system = platform.system().lower()
        arch = platform.machine().lower()

        if system == "linux" and arch == "x86_64":
            release_tarball = "boombox-server-linux-x86.tar.gz"
        elif system == "darwin" and arch == "arm64":
            release_tarball = "boombox-server-macos-arm.tar.gz"
        else:
            raise RuntimeError(f"Unsupported platform: {system} {arch}")

        download_url = os.path.join(release_url, release_tarball)
        tarball_path = os.path.join(self._data_dir, release_tarball)

        with TqdmUpTo(
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            miniters=1,
            desc=f"Downloading {release_tarball}",
        ) as t:
            urllib.request.urlretrieve(
                download_url, filename=tarball_path, reporthook=t.update_to
            )

        logging.info("Download complete. Extracting...")
        with tarfile.open(tarball_path) as tar:
            tar.extractall(self._data_dir)
            os.remove(tarball_path)

    @staticmethod
    def _dtype_to_sample_format(dtype: np.dtype) -> tuple[AudioSampleFormat, np.dtype]:
        type_mapping = {"i": "s", "u": "u", "f": "f"}
        data_type = type_mapping.get(dtype.kind)
        if data_type is None:
            warnings.warn(
                f"Arrays of dtype.kind == {dtype.kind} not allowed, supported kinds are 'i', 'u', 'f', casting to 'f'."
            )
            data_type = "f"

        if dtype.itemsize in [1, 2, 4, 8]:
            bit_size = str(dtype.itemsize * 8)
        else:
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

        new_dtype = Boombox._sample_format_to_dtype(sample_format)

        return sample_format, new_dtype

    @staticmethod
    def _sample_format_to_dtype(sample_format: AudioSampleFormat) -> np.dtype:
        type_mapping = {"s": "i", "u": "u", "f": "f"}

        if len(sample_format) == 2:  # Handle 8-bit case (without endian)
            data_type = sample_format[0]
            dtype_str = type_mapping[data_type] + "1"
        else:
            data_type = sample_format[0]
            bit_size = sample_format[1:-2]
            endian = sample_format[-2:]

            # numpy doesn't support 24-bit size values
            bit_size = 32 if bit_size == "24" else int(bit_size)
            endian_symbol = "<" if endian == "le" else ">"
            dtype_str = (
                endian_symbol + type_mapping[data_type] + str(int(bit_size) // 8)
            )

        return np.dtype(dtype_str)

    @staticmethod
    def _audio_bytes_to_array(
        data: bytes, sample_format: AudioSampleFormat
    ) -> np.ndarray:
        dtype = Boombox._sample_format_to_dtype(sample_format)
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

    @staticmethod
    def _deserialize_packet(packet: dict[Atom, Any]) -> AudioPacket | VideoPacket:
        media_type, payload = packet[Atom("payload")]
        if media_type == Atom("audio"):
            deserialized_payload = Boombox._audio_bytes_to_array(
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

    @staticmethod
    def _serialize_packet(packet: AudioPacket | VideoPacket) -> dict[Atom, Any]:
        match packet:
            case AudioPacket():
                sample_format, new_dtype = Boombox._dtype_to_sample_format(
                    packet.payload.dtype
                )

                serialized_payload = (
                    Atom("audio"),
                    {
                        Atom("data"): packet.payload.astype(new_dtype).tobytes(),
                        Atom("sample_format"): Atom(sample_format),
                        Atom("sample_rate"): packet.sample_rate,
                        Atom("channels"): packet.channels,
                    },
                )
            case VideoPacket():
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

    @staticmethod
    def _serialize_endpoint(endpoint: BoomboxEndpoint | str) -> Any:
        if isinstance(endpoint, str):
            return endpoint.encode()
        else:
            return endpoint.serialize()


@dataclasses.dataclass
class VideoPacket:
    """A Boombox packet containing raw video.

    Objects of this class are used when writing/reading raw video data to/from
    Boombox through the usage of :py:class:`.RawData` endpoint.

    Attributes
    ----------
    payload : np.ndarray
        Raw data of a single frame of the video stream. Shape of the array is
        (width, height, channels).
    timestamp : int
        Timestamp of the frame in milliseconds.
    """

    payload: np.ndarray
    timestamp: int


@dataclasses.dataclass
class AudioPacket:
    """A Boombox packet containing raw audio.

    Objects of this class are used when writing/reading raw audio data to/from
    Boombox through the usage of :py:class:`.RawData` endpoint.

    Attributes
    ----------
    payload : np.ndarray
        Raw data of an audio chunk of the video stream. The array is
        one-dimentional.
    timestamp : int
        Timestamp of the first sample in the chunk in milliseconds.
    sample_rate : int
        Number of audio samples per second.
    channels : int
        Number of channels interleaved in the stream.
    """

    payload: np.ndarray
    timestamp: int
    sample_rate: int
    channels: int
