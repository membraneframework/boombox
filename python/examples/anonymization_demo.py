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
import logging
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
    print(f"Sender page available at http://{address}:{port}/sender.html")
    print(f"Receiver page available at http://{address}:{port}/receiver.html")
    httpd.serve_forever()


def read_packets(boombox: Boombox, packet_queue: queue.Queue) -> None:
    MAX_QUEUE_SIZE = 15
    for packet in boombox.read():
        packet_queue.put(packet)
        if packet_queue.qsize() > MAX_QUEUE_SIZE:
            packet_queue.get()
    print("dupsko")


def resize_frame(frame: np.ndarray, scale_factor: float) -> np.ndarray:
    original_h, original_w = frame.shape[:2]
    target_w = int(original_w * scale_factor)
    target_h = int(original_h * scale_factor)
    return cv2.resize(frame, (target_w, target_h))


def is_arm_raised(pose_model: ultralytics.YOLO, frame: np.ndarray) -> bool:
    LEFT_WRIST, RIGHT_WRIST = 9, 10
    NOSE = 1

    pose_results = pose_model(frame, verbose=False)
    if pose_results[0].keypoints.shape[1] > 0:
        for coordinates in pose_results[0].keypoints.xy:
            left_wrist_y = coordinates[LEFT_WRIST][1]
            right_wrist_y = coordinates[RIGHT_WRIST][1]
            nose_y = coordinates[NOSE][1]

            if nose_y > 0:
                if left_wrist_y > 0 and left_wrist_y < nose_y:
                    return True
                if right_wrist_y > 0 and right_wrist_y < nose_y:
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
    blur_kernel = (31, 31)

    frame_h, frame_w = frame.shape[:2]

    for x1, y1, x2, y2 in boxes:
        if x1 == x2 or y1 == y2:
            continue
        x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
        face_w, face_h = x2 - x1, y2 - y1

        # makes sure the kernel size is odd.
        smoothing_border_width = max(int(max(face_w, face_h) * 0.1) * 2 + 1, 3)
        half_border = smoothing_border_width // 2
        smoothing_kernel = (smoothing_border_width, smoothing_border_width)

        working_x1 = max(0, x1 - smoothing_border_width)
        working_y1 = max(0, y1 - smoothing_border_width)
        working_x2 = min(frame_w, x2 + smoothing_border_width)
        working_y2 = min(frame_h, y2 + smoothing_border_width)

        working_roi = frame[working_y1:working_y2, working_x1:working_x2]

        blurred_work_roi = cv2.GaussianBlur(working_roi, blur_kernel, 30)

        working_h, working_w = working_roi.shape[:2]
        mask = np.zeros((working_h, working_w), dtype=np.uint8)

        face_x_in_work = x1 - working_x1
        face_y_in_work = y1 - working_y1

        cv2.rectangle(
            mask,
            (face_x_in_work - half_border, face_y_in_work - half_border),
            (
                face_x_in_work + face_w + half_border,
                face_y_in_work + face_h + half_border,
            ),
            (255, 255, 255),
            -1,
        )

        soft_mask = cv2.GaussianBlur(mask, smoothing_kernel, 0)

        alpha = soft_mask / 255.0
        alpha = alpha[:, :, np.newaxis]

        blended_roi = (
            working_roi.astype(float) * (1.0 - alpha)
            + blurred_work_roi.astype(float) * alpha
        ).astype(np.uint8)

        frame[working_y1:working_y2, working_x1:working_x2] = blended_roi


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
    # Time of silence required to clear the current accumulated audio and start
    # accumulating from the start. This will clear the old transcription.
    CLEAR_BUFFERED_AUDIO_TIMEOUT_MS = 2000
    # Time of silence after which the current transcription will be cleared.
    CLEAR_TRANSCRIPTION_TIMEOUT_MS = 4000
    # Time of continous speech after which a transcription will be generated.
    FORCE_TRANSCRIPTION_TIMEOUT_MS = 2000
    # Maximum amount of transcription lines that will be displayed at a time.
    MAX_TRANSCRIPTION_LINES = 4
    # Address and port where the pages will be available at.
    SERVER_ADDRESS = "localhost"
    SERVER_PORT = 8000

    logging.basicConfig()
    Boombox.logger.setLevel(logging.INFO)

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
    last_silence_timestamp = 0
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
    packet_queue = queue.Queue()
    reading_thread = threading.Thread(
        target=read_packets,
        args=(input_boombox, packet_queue),
        daemon=True,
    )
    print("c")
    reading_thread.start()
    print("Input boombox initialized.")

    output_boombox = Boombox(
        input=RawData(video=True, audio=True, is_live=True),
        output=WebRTC("ws://localhost:8830"),
    )
    print("Output boombox initialized.")

    while reading_thread.is_alive() or not packet_queue.empty():
        packet = packet_queue.get()
        if isinstance(packet, AudioPacket):
            rms = np.sqrt(np.mean(packet.payload**2))

            if rms > VAD_THRESHOLD:
                if silence_duration > CLEAR_BUFFERED_AUDIO_TIMEOUT_MS:
                    audio_chunks.clear()
                last_speech_timestamp = packet.timestamp
                is_speaking = True
            elif not is_speaking:
                last_silence_timestamp = packet.timestamp
                if silence_duration > CLEAR_TRANSCRIPTION_TIMEOUT_MS:
                    transcription_lines.clear()

            silence_duration = packet.timestamp - last_speech_timestamp
            speech_duration = packet.timestamp - last_silence_timestamp

            if is_speaking:
                audio_chunks.append(packet.payload)
                if silence_duration > PHRASE_TIMEOUT_MS:
                    speech_audio = np.concatenate(audio_chunks, axis=0)
                    audio_queue.put(speech_audio)
                    is_speaking = False
                if speech_duration > FORCE_TRANSCRIPTION_TIMEOUT_MS:
                    speech_audio = np.concatenate(audio_chunks, axis=0)
                    audio_queue.put(speech_audio)
                    last_silence_timestamp = packet.timestamp

            if should_anonymize:
                packet.payload = distort_audio(packet.payload, packet.sample_rate)

            print(output_boombox.write(packet))

        if isinstance(packet, VideoPacket):
            video_read_end_time = time.time() * 1000
            if video_read_start_time is not None:
                video_read_time = video_read_end_time - video_read_start_time

            frame = np.flip(packet.payload, axis=1).astype(np.uint8)

            try:
                transcription = transcript_queue.get(block=False)
                transcription_lines = split_transcription(transcription, frame)[
                    -MAX_TRANSCRIPTION_LINES:
                ]
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
            print(output_boombox.write(packet))
            video_read_start_time = time.time() * 1000

    output_boombox.close()


if __name__ == "__main__":
    main()
