# Anonymization Demo

This demo showcases the possibilities of Boombox when it comes to interacting with media streams
inside Python. The original stream is captured from a webcam by a browser and then streamed with
WebRTC to Boombox. Boombox then outputs the stream to python, where the identity of the person
on stream is "anonymized" while their arm is raised:
  - Their face is blurred.
  - Their voice is distorted.
  - Their speech is transcribed and displayed as subtitles.

The resulting stream is then passed to another Boombox, which then streams it to a browser.

### Prerequisites

To run the demo you'll need to install the required python dependencies and Erlang on your system.
For dependencies just install packages from `requirements.txt`:

```bash
pip install -r requirements.txt
```

For Erlang we recommend following these [instructions](https://elixir-lang.org/install.html#installing-erlang).

You'll also need a webcam and a microphone.

### Usage

1. Run `anonymization_demo.py`:

```bash
python anonymization_demo.py
```

2. Open `http://localhost:8000/receiver.py` and click "Connect"
3. Open `http://localhost:8000/sender.py` and click "Connect"

