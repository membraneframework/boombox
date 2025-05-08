from abc import ABC
from pyrlang.process import Process
from pyrlang.node import Node
from term import Atom, Pid
from asyncio import Future
import numpy as np
import uuid
from typing import Generator, ClassVar, Optional, Any
from typing_extensions import override
from boombox.endpoints import BoomboxEndpoint, Array
import subprocess
import atexit
from os import path
from dataclasses import dataclass, KW_ONLY


@dataclass
class Packet(ABC):
    payload: np.ndarray
    timestamp: int


@dataclass
class VideoPacket(Packet):
    pass


@dataclass
class AudioPacket(Packet):
    _: KW_ONLY
    sample_format: str | None = None
    sample_rate: int | None = None
    channels: int | None = None


class Boombox(Process):
    _python_node_name: ClassVar[str]
    _cookie: ClassVar[str]

    _process_name: Atom
    _erlang_node_name: Atom
    _receiver: tuple[Atom, Atom] | Pid
    _response_received: Optional[Future]
    _finished: Future
    _erlang_process: subprocess.Popen
    _audio_stream_format: dict[Atom, Any] | None

    _python_node_name = f'{uuid.uuid4()}@127.0.0.1'
    _cookie = str(uuid.uuid4())
    Node(node_name=_python_node_name, cookie=_cookie)

    def __init__(self, input: BoomboxEndpoint | str,
                 output: BoomboxEndpoint | str) -> None:
        self._process_name = Atom(uuid.uuid4())
        self._erlang_node_name = Atom(f'{self._process_name}@127.0.0.1')
        env = {
            'NODE_TO_PING': self._python_node_name,
            'RELEASE_NODE': self._erlang_node_name,
            'RELEASE_COOKIE': self._cookie,
            'RELEASE_DISTRIBUTION': 'name'
        }
        release_path = path.join(path.dirname(path.abspath(__file__)),
                                      'erlang', 'bin', 'server')
        self._erlang_process = subprocess.Popen(
            [release_path, 'start'], env=env)
        atexit.register(lambda: self._erlang_process.kill())

        Process.__init__(self)
        self.get_node().register_name(self, self._process_name)
        self._finished = self.get_node().get_loop().create_future()
        self._receiver = (self._erlang_node_name, Atom('boombox_server'))
        self._receiver = self._call(Atom('get_pid'))
        if isinstance(input, Array) and input.audio:
            self._audio_stream_format = {
                Atom('sample_format'): Atom(
                    input.audio_format) if input.audio_format is not None
                else None,
                Atom('sample_rate'): input.audio_rate,
                Atom('channels'): input.audio_channels
            }
        else:
            self._audio_stream_format = None

        boombox_arg = [
            (Atom('input'), self._serialize_endpoint(input)),
            (Atom('output'), self._serialize_endpoint(output))
        ]
        self._call((Atom('run_boombox'), boombox_arg))
        self.get_node().link_nowait(self.pid_, self._receiver)
    def write(self, packet: Packet) -> None:
        serialized_packet = self._serialize_packet(packet)

        self._call((Atom('consume_packet'), serialized_packet))

    def read(self) -> Generator[Packet, None, None]:
        production_phase = Atom('ok')
        while production_phase != Atom('_finished'):
            production_phase, packet = self._call(Atom('produce_packet'))
            deserialized_packet = self._deserialize_packet(packet)
            yield deserialized_packet

    def close(self, wait: bool = False, kill: bool = False) -> None:
        self._call(Atom('finish_consuming'))
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
        if self._response_received is not None:
            self._response_received.set_result(msg)

    @override
    def exit(self, reason: Any = None) -> None:
        self._finished.set_result(None)
        super().exit(reason)

    def _call(self, message: Any) -> Any:
        message = (Atom('call'), (Atom(self._process_name),
                                  Atom(self.node_name_)), message)

        self.get_node().send_nowait(sender=self, receiver=self._receiver,
                                    message=message)
        self._response_received = self.get_node().get_loop().create_future()
        return self.get_node().get_loop().run_until_complete(
            self._response_received)

    def _deserialize_packet(self, packet: dict[Atom, Any]) -> Packet:
        media_type, payload = packet[Atom('payload')]
        if media_type == Atom('audio'):
            deserialized_payload = np.frombuffer(payload[Atom('data')],
                                                 np.uint8)
            return AudioPacket(deserialized_payload, packet[Atom('timestamp')],
                               sample_format=str(
                                   payload[Atom('sample_format')]),
                               sample_rate=payload[Atom('sample_rate')],
                               channels=payload[Atom('channels')]
                               )
        else:
            shape = (payload[Atom('height')], payload[Atom('width')],
                     payload[Atom('channels')])
            deserialized_payload = np.frombuffer(payload[Atom('data')],
                                                 np.uint8).reshape(shape)
            return VideoPacket(deserialized_payload, packet[Atom('timestamp')])

    def _serialize_packet(self, packet: Packet) -> dict[Atom, Any]:
        if isinstance(packet, AudioPacket):
            assert self._audio_stream_format is not None
            if packet.sample_format is not None:
                self._audio_stream_format[Atom('sample_format')] = Atom(
                    packet.sample_format)
            if packet.sample_rate is not None:
                self._audio_stream_format[
                    Atom('sample_rate')] = packet.sample_rate
            if packet.channels is not None:
                self._audio_stream_format[Atom('channels')] = packet.channels

            serialized_payload = (Atom('audio'), {
                Atom('data'): packet.payload.astype(np.uint8).tobytes(),
                **self._audio_stream_format
            })
        else:
            # frame shape (width, height, channels)
            if len(packet.payload.shape) == 2:
                height, width = packet.payload.shape
                frame = packet.payload.reshape(width, height, 1)

            frame = packet.payload.clip(0, 255)
            raw_frame = frame.tobytes()
            serialized_payload = (Atom('video'), {
                Atom('data'): raw_frame,
                Atom('height'): frame.shape[0],
                Atom('width'): frame.shape[1],
                Atom('channels'): frame.shape[2],
            })

        return {
            Atom('payload'): serialized_payload,
            Atom('timestamp'): packet.timestamp,
        }

    def _serialize_endpoint(self, endpoint: BoomboxEndpoint | str) -> Any:
        if isinstance(endpoint, str):
            return endpoint.encode()
        else:
            return endpoint.serialize()
