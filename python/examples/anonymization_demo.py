"""
This demo is a simple app that is an example usage of Boombox in python.
The app receives a WebRTC stream from a webcam from one browser, conditionally
transforms it, and streams it to another browser.

While a person in front of the webcam raises their hand, then the stream is
"anonymized":
  - Their face is blurred.
  - Their voice is distorted.
  - Their speech is transcribed to text, which is then displayed.

Detection of a hand being raised and the region of a face is done with
[YOLO models](https://docs.ultralytics.com). Speech to text transcription is
done with [Whisper model](https://openai.com/index/whisper).
"""

from boombox import Boombox, RawData, AudioPacket, VideoPacket, WebRTC
import torch
import numpy as np
import cv2
import ultralytics
import whisper

import os
import http.server
import queue
import threading
import time
from typing import NoReturn


def stt_worker(
    stt_model: whisper.Whisper, audio_queue: queue.Queue, transcript_queue: queue.Queue
) -> NoReturn:
    while True:
        audio_chunk = audio_queue.get(block=True)

        result = stt_model.transcribe(
            audio_chunk,
            fp16=torch.cuda.is_available(),
        )
        text = result["text"]

        if text != "":
            transcript_queue.put(text)


def run_server(address: str, port: int) -> None:
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            directory = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "assets"
            )

            super().__init__(*args, **kwargs, directory=directory)

    httpd = http.server.HTTPServer((address, port), Handler)
    httpd.serve_forever()


def resize_frame(frame: np.ndarray, scale_factor: float) -> np.ndarray:
    original_h, original_w = frame.shape[:2]
    target_w = int(original_w * scale_factor)
    target_h = int(original_h * scale_factor)
    return cv2.resize(frame, (target_w, target_h))


def is_arm_raised(pose_model: ultralytics.YOLO, frame: np.ndarray) -> bool:
    LEFT_SHOULDER, RIGHT_SHOULDER = 5, 6
    LEFT_WRIST, RIGHT_WRIST = 9, 10

    pose_results = pose_model(frame, verbose=False)
    if pose_results[0].keypoints.shape[1] > 0:
        for coordinates in pose_results[0].keypoints.xy:
            left_wrist_y = coordinates[LEFT_WRIST][1]
            right_wrist_y = coordinates[RIGHT_WRIST][1]

            left_shoulder_y = coordinates[LEFT_SHOULDER][1]
            right_shoulder_y = coordinates[RIGHT_SHOULDER][1]

            # coordinates equal to 0 should be ignored
            if (
                left_wrist_y > 0
                and left_shoulder_y > 0
                and left_wrist_y < left_shoulder_y
            ) or (
                right_wrist_y > 0
                and right_shoulder_y > 0
                and right_wrist_y < right_shoulder_y
            ):
                return True

    return False


def draw_joints(coordinates: torch.Tensor, frame: np.ndarray) -> None:
    for detection in coordinates:
        for x, y in detection:
            if x > 0 and y > 0:
                cv2.circle(
                    frame,
                    (int(x), int(y)),
                    5,
                    (0, 255, 0),
                    -1,
                )


def detect_face(face_model: ultralytics.YOLO, frame: np.ndarray) -> torch.Tensor:
    face_results = face_model(frame, verbose=False)
    return face_results[0].boxes.xyxy


def blur_face(boxes: torch.Tensor, frame: np.ndarray) -> None:
    for x1, y1, x2, y2 in boxes:
        face = frame[y1:y2, x1:x2]

        if face.size > 0:
            blurred_face = cv2.GaussianBlur(face, (31, 31), 30)
            frame[y1:y2, x1:x2] = blurred_face


FONT = cv2.FONT_HERSHEY_DUPLEX
FONT_SCALE = 0.8
FONT_THICKNESS = 1
TEXT_MARGIN = 25
LINE_SPACING = 10
TEXT_HEIGHT = 18
TEXT_BASELINE = 10


def split_transcription(text: str, frame: np.ndarray) -> list[tuple[str, int]]:
    text = text.strip()

    max_line_width = frame.shape[1] - 2 * TEXT_MARGIN
    words = text.split()

    lines = []
    candidate_line_text = current_line_text = ""
    current_line_width = 0

    for word in words:
        sep = "" if current_line_text == "" else " "
        candidate_line_text = current_line_text + sep + word
        (candidate_line_width, _), _ = cv2.getTextSize(
            candidate_line_text, FONT, FONT_SCALE, FONT_THICKNESS
        )
        if candidate_line_width >= max_line_width:
            lines.append((current_line_text, current_line_width))
            candidate_line_text = current_line_text = word
            (current_line_width, _), _ = cv2.getTextSize(
                current_line_text, FONT, FONT_SCALE, FONT_THICKNESS
            )
        else:
            current_line_text = candidate_line_text
            current_line_width = candidate_line_width

    lines.append((current_line_text, current_line_width))

    return lines


def render_transcription(lines: list[tuple[str, int]], frame: np.ndarray) -> None:
    for i, (line_text, line_width) in enumerate(reversed(lines)):
        text_y = frame.shape[0] - TEXT_MARGIN - (TEXT_HEIGHT + LINE_SPACING) * i
        text_x = (frame.shape[1] - line_width) // 2
        cv2.rectangle(
            frame,
            (text_x, text_y + TEXT_BASELINE),
            (text_x + line_width, text_y - TEXT_HEIGHT),
            (0, 0, 0, 127),
            cv2.FILLED,
        )
        cv2.putText(
            frame,
            line_text,
            (text_x, text_y),
            FONT,
            FONT_SCALE,
            (255, 255, 255),
            FONT_THICKNESS,
            cv2.LINE_AA,
        )


def distort_audio(
    audio_chunk: np.ndarray,
    sample_rate: int,
    carrier_freq: float = 120.0,
) -> np.ndarray:
    num_samples = len(audio_chunk)
    time_vector = np.arange(num_samples) / sample_rate
    carrier_wave = np.sin(2 * np.pi * carrier_freq * time_vector)
    return audio_chunk * carrier_wave


def main():
    # YOLO performs it's detections on scaled-down frames for better
    # performance, this determines the scale factor.
    SCALE_FACTOR = 0.25
    # Value determining the energy level to isolate speech from silence.
    VAD_THRESHOLD = 0.05
    # Minimum time of reading a video packet to assume that the stream
    # is up to date and computation-heavy model inference can be performed.
    MIN_PACKET_READ_TIME_MS = 10
    # Minimum time of silence to transcribe buffered speech and update the
    # displayed transcription.
    PHRASE_TIMEOUT_MS = 250
    # Minimum time of silence to clear the current transcription and start
    # a new one.
    CLEAR_TRANSCRIPTION_TIMEOUT_MS = 2000
    # Address and port where the pages will be available at.
    SERVER_ADDRESS = "localhost"
    SERVER_PORT = 8000

    threading.Thread(
        target=run_server, args=(SERVER_ADDRESS, SERVER_PORT), daemon=True
    ).start()

    if torch.cuda.is_available():
        yolo_device = "cuda"
        whisper_device = "cuda"
    elif torch.backends.mps.is_available():
        yolo_device = "mps"
        whisper_device = "cpu"
    else:
        yolo_device = "cpu"
        whisper_device = "cpu"
    pose_model = ultralytics.YOLO("yolo11n-pose.pt").to(yolo_device)
    face_model = ultralytics.YOLO(
        "https://github.com/akanametov/yolo-face/releases/download/v0.0.0/yolov11n-face.pt"
    ).to(yolo_device)
    stt_model = whisper.load_model("base.en", device=whisper_device)
    print("Models loaded.")

    audio_queue = queue.Queue()
    transcript_queue = queue.Queue()
    threading.Thread(
        target=stt_worker, args=(stt_model, audio_queue, transcript_queue), daemon=True
    ).start()

    audio_chunks = []
    transcription_lines = []

    video_read_start_time = None
    video_read_time = 10000

    face_boxes = torch.empty((0, 4))
    should_anonymize = False
    is_speaking = False
    last_speech_timestamp = 0
    silence_duration = 0

    input_boombox = Boombox(
        input=WebRTC("ws://localhost:8829"),
        output=RawData(
            video=True,
            audio=True,
            audio_rate=16000,
            audio_channels=1,
            audio_format="f32le",
        ),
    )
    print("Input boombox initialized.")

    output_boombox = Boombox(
        input=RawData(video=True, audio=True), output=WebRTC("ws://localhost:8830")
    )
    print("Output boombox initialized.")

    for packet in input_boombox.read():
        if isinstance(packet, AudioPacket):
            rms = np.sqrt(np.mean(packet.payload**2))

            if rms > VAD_THRESHOLD:
                if silence_duration > CLEAR_TRANSCRIPTION_TIMEOUT_MS:
                    audio_chunks.clear()
                last_speech_timestamp = packet.timestamp
                is_speaking = True

            silence_duration = packet.timestamp - last_speech_timestamp

            if is_speaking:
                audio_chunks.append(packet.payload)
                if silence_duration > PHRASE_TIMEOUT_MS:
                    speech_audio = np.concatenate(audio_chunks, axis=0)
                    audio_queue.put(speech_audio)
                    is_speaking = False

            if should_anonymize:
                packet.payload = distort_audio(packet.payload, packet.sample_rate)

            output_boombox.write(packet)

        if isinstance(packet, VideoPacket):
            video_read_end_time = time.time() * 1000
            if video_read_start_time is not None:
                video_read_time = video_read_end_time - video_read_start_time

            frame = packet.payload.astype(np.uint8)

            try:
                transcription = transcript_queue.get(block=False)
                transcription_lines = split_transcription(transcription, frame)
            except queue.Empty:
                pass

            # If we have waited at least MIN_PACKET_READ_TIME_MS until getting
            # the next video packet we assume that there were no packets
            # buffered and we are up-to-date with the stream, therefore we can
            # run the models, which tend to run for longer than a single frame
            # should last.
            if video_read_time > MIN_PACKET_READ_TIME_MS:
                # resize the frame for better performance of the models
                resized_frame = resize_frame(frame, SCALE_FACTOR)

                should_anonymize = is_arm_raised(pose_model, resized_frame)
                if should_anonymize:
                    face_boxes = detect_face(face_model, resized_frame)

            if should_anonymize:
                blur_face((face_boxes / SCALE_FACTOR).int(), frame)
                render_transcription(transcription_lines, frame)

            packet.payload = frame
            output_boombox.write(packet)
            video_read_start_time = time.time() * 1000
            print(f"{video_read_start_time - video_read_end_time:2f}ms")

    output_boombox.close(wait=True)


if __name__ == "__main__":
    main()
