# Anonymization Demo

This demo showcases the possibilities of Boombox when it comes to interacting with media streams
inside Python. The original stream is captured from a webcam by a browser and then streamed with
WebRTC to Boombox. Boombox then outputs the stream to python, where the identity of the person
on stream is "anonymized" while their arm is raised:

- Their face is blurred.
- Their voice is distorted.
- Their speech is transcribed and displayed as subtitles.

The resulting stream is then passed to another Boombox, which then streams it to a browser.

## Prerequisites

To run the demo you'll need to install the required dependencies from `requirements.txt`:

```bash
pip install -r requirements.txt
```

You'll also need a webcam and a microphone.

## Usage

1. Run `anonymization_demo.py`:

  ```bash
  python anonymization_demo.py
  ```

2. Open `http://localhost:8000/receiver.html` and click "Connect"
3. Open `http://localhost:8000/sender.html` and click "Connect"

On the sender page you'll see the unmodified webcam feed, and on the receiver
page you'll see the resulting stream.
