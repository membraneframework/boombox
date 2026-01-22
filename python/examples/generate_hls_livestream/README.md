# Generate a HLS livestream from WebRTC

This demo showcases usage of Boombox in receiving a WebRTC stream and converting
it to a live HLS playlist. The WebRTC stream will be coming from a browser
capturing feed from a webcam.

## Prerequisites

To run the demo you'll need `boomboxlib`, which can be installed like that:

```bash
pip install ../..
```

You'll also need a webcam and optionally a microphone.

## Usage

1. Run the python program

```bash
python main.py
```

2. Open `http://localhost:8000/sender.html` and click "Connect"
3. Open `http://localhost:8000/hls.html` and click "Play"

On the sender page you'll see the webcam feed, and on the page with HLS
stream you'll access the livestream.
