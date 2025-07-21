import numpy as np
import cv2
from torch.cpu import is_available
from ultralytics import YOLO
import torch
import time
import queue
import threading
from src.boombox import Boombox, RawData, AudioPacket, VideoPacket, WebRTC
import whisper
from scipy.io.wavfile import write


def stt_worker(audio_q: queue.Queue, transcript_q: queue.Queue, model: whisper.Whisper):
    while True:
        audio_np = audio_q.get(block=True)

        print(f"queue size {audio_q.qsize()}")
        print(f"Transcribing audio chunk of length {audio_np.size}")
        result = model.transcribe(
            audio_np,
            fp16=torch.cuda.is_available(),
        )
        text = result["text"]
        print(text)
        # write(f"{text}.wav", 16000, audio_np)

        if text:
            transcript_q.put(text)


def resize_frame(frame: np.ndarray, scale_factor: float) -> np.ndarray:
    original_h, original_w = frame.shape[:2]
    target_w = int(original_w * scale_factor)
    target_h = int(original_h * scale_factor)
    return cv2.resize(frame, (target_w, target_h))


def detect_pose(pose_model: YOLO, frame: np.ndarray) -> tuple[torch.Tensor, bool]:
    LEFT_SHOULDER, RIGHT_SHOULDER = 5, 6
    LEFT_WRIST, RIGHT_WRIST = 9, 10

    should_blur_face = False
    pose_results = pose_model(frame, verbose=False)
    if pose_results[0].keypoints.shape[1] > 0:
        for coordinates in pose_results[0].keypoints.xy:
            left_wrist_y = coordinates[LEFT_WRIST][1]
            right_wrist_y = coordinates[RIGHT_WRIST][1]

            left_shoulder_y = coordinates[LEFT_SHOULDER][1]
            right_shoulder_y = coordinates[RIGHT_SHOULDER][1]

            if (
                left_wrist_y > 0
                and left_shoulder_y > 0
                and left_wrist_y < left_shoulder_y
            ) or (
                right_wrist_y > 0
                and right_shoulder_y > 0.2
                and right_wrist_y < right_shoulder_y
            ):
                should_blur_face = True

        return (pose_results[0].keypoints.xy, should_blur_face)
    else:
        return (torch.empty((0, 17, 2)), False)


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


def detect_face(face_model: YOLO, frame: np.ndarray) -> torch.Tensor:
    face_results = face_model(frame, verbose=False)
    return face_results[0].boxes.xyxy


def blurr_face(boxes: torch.Tensor, frame: np.ndarray) -> None:
    for x1, y1, x2, y2 in boxes:
        face_roi = frame[y1:y2, x1:x2]

        # Apply blur directly to the ROI
        if face_roi.size > 0:
            blurred_face = cv2.GaussianBlur(face_roi, (99, 99), 30)
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
    current_line_text = ""
    candidate_line_text = current_line_text
    current_line_width = 0

    for word in words:
        sep = "" if current_line_text == "" else " "
        candidate_line_text += sep + word
        (candidate_line_width, _), _ = cv2.getTextSize(
            candidate_line_text, FONT, FONT_SCALE, FONT_THICKNESS
        )
        if candidate_line_width >= max_line_width:
            lines.append((current_line_text, current_line_width))
            current_line_text = word
            candidate_line_text = word
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


def ring_modulate(
    audio_chunk: np.ndarray,
    sample_rate: int,
    carrier_freq: float = 40.0,
) -> np.ndarray:
    num_samples = len(audio_chunk)
    time_vector = np.arange(num_samples) / sample_rate
    carrier_wave = np.sin(2 * np.pi * carrier_freq * time_vector)
    return audio_chunk * carrier_wave


# --- Main Processing Logic ---
def process_stream():
    if torch.cuda.is_available():
        yolo_device = "cuda"
        whisper_device = "cuda"
    elif torch.backends.mps.is_available():
        yolo_device = "mps"
        whisper_device = "cpu"
    else:
        yolo_device = "cpu"
        whisper_device = "cpu"

    pose_model = YOLO("yolov11n-pose.pt").to(yolo_device)
    face_model = YOLO("yolov11n-face.pt").to(yolo_device)
    stt_model = whisper.load_model("base.en", device=whisper_device)

    audio_queue = queue.Queue()
    transcript_queue = queue.Queue()
    threading.Thread(
        target=stt_worker, args=(audio_queue, transcript_queue, stt_model), daemon=True
    ).start()

    audio_buffer = []
    transcription_lines = []

    video_read_start_time = None
    video_read_time = 10000
    audio_read_start_time = None
    audio_read_time = 10000

    SCALE_FACTOR = 0.25
    scaled_keypoints = torch.empty((0, 17, 2))
    scaled_boxes = torch.empty((0, 4))
    should_anonymise = False
    is_speaking = False
    silence_start_timestamp = None
    MIN_PACKET_READ_TIME = 0.01

    VAD_THRESHOLD = 0.05  # Energy threshold for detecting speech. Adjust this based on your mic sensitivity.
    PHRASE_CHUNK_TIMEOUT_MS = 250
    PHRASE_TIMEOUT_MS = 2000
    silence_time = 0

    boombox1 = Boombox(
        input=WebRTC("ws://localhost:8829"),
        # output=RawData(video=True, audio=False),
        output=RawData(
            video=True,
            audio=True,
            audio_rate=16000,
            audio_channels=1,
            audio_format="f32le",
        ),
    )
    # boombox2 = Boombox
    # input=RawData(video=True, audio=True), output=WebRTC("ws://localhost:8830")
    # )

    try:
        for packet in boombox1.read():
            time.sleep(0.2)
            if isinstance(packet, AudioPacket):
                audio_read_end_time = time.time()
                if audio_read_start_time is not None:
                    audio_read_time = audio_read_end_time - audio_read_start_time
                # print(f"audio reading: {audio_read_time * 1000:.2f}ms")
                if should_anonymise or True:
                    rms = np.sqrt(np.mean(packet.payload**2))

                    if rms > VAD_THRESHOLD:
                        if silence_time > PHRASE_TIMEOUT_MS:
                            audio_buffer.clear()
                        # if last_silent_chunk is not None:
                        # audio_buffer = [last_silent_chunk]
                        silence_time = 0
                        is_speaking = True
                        silence_start_timestamp = None
                        audio_buffer.append(packet.payload)
                    else:
                        if silence_start_timestamp is None:
                            silence_start_timestamp = packet.timestamp
                        if is_speaking:
                            audio_buffer.append(packet.payload)
                        # else:
                        # last_silent_chunk = packet.payload
                        silence_time = packet.timestamp - silence_start_timestamp
                        if is_speaking and silence_time > PHRASE_CHUNK_TIMEOUT_MS:
                            full_audio_np = np.concatenate(audio_buffer, axis=0)
                            audio_queue.put(full_audio_np)
                            # audio_buffer.clear()
                            is_speaking = False
                    packet.payload = ring_modulate(
                        packet.payload, packet.sample_rate, carrier_freq=60.0
                    )

                # boombox2.write(packet)
                audio_read_start_time = time.time()
                # print(
                # f"audio processing: {(audio_read_start_time - audio_read_end_time) * 1000:.2f}ms"
                # )

            if isinstance(packet, VideoPacket):
                video_read_end_time = time.time()
                if video_read_start_time is not None:
                    video_read_time = video_read_end_time - video_read_start_time
                frame = packet.payload.astype(np.uint8)
                # print(f"video reading: {video_read_time * 1000:.2f}ms")
                if video_read_time > MIN_PACKET_READ_TIME:
                    resized_frame = resize_frame(frame, SCALE_FACTOR)

                    scaled_keypoints, should_anonymise = detect_pose(
                        pose_model, resized_frame
                    )
                    if should_anonymise:
                        scaled_boxes = detect_face(face_model, resized_frame)

                # if not should_anonymise:
                # audio_buffer.clear()
                # is_speaking = False
                # silence_start_timestamp = None
                # live_subtitle_text = ""

                draw_joints((scaled_keypoints / SCALE_FACTOR).int(), frame)
                if should_anonymise:
                    blurr_face((scaled_boxes / SCALE_FACTOR).int(), frame)

                try:
                    transcription = transcript_queue.get(block=False)
                    transcription_lines = split_transcription(transcription, frame)
                except queue.Empty:
                    pass

                if len(transcription_lines) > 0:
                    # if live_subtitle_text and should_anonymise:
                    render_transcription(transcription_lines, frame)

                processed_packet = VideoPacket(
                    payload=frame, timestamp=packet.timestamp
                )
                # boombox2.write(processed_packet)
                video_read_start_time = time.time()
                # print(
                # f"video processing: {(video_read_start_time - video_read_end_time) * 1000:.2f}ms"
                # )

    except KeyboardInterrupt:
        print("\nStream processing stopped by user.")
    finally:
        # boombox2.close(wait=True)
        print("Cleanup complete.")


if __name__ == "__main__":
    process_stream()
