import http.server
import os
import threading

from boombox import Boombox, WebRTC, HLS

SERVER_ADDRESS = "localhost"
SERVER_PORT = 8000


def run_server(address: str, port: int) -> None:
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            directory = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "assets"
            )

            super().__init__(*args, **kwargs, directory=directory)

    httpd = http.server.HTTPServer((address, port), Handler)
    print(f"Sender page available at http://{address}:{port}/sender.html")
    print(f"HLS stream available at http://{address}:{port}/hls.html")
    httpd.serve_forever()


if __name__ == "__main__":
    threading.Thread(
        target=run_server, args=(SERVER_ADDRESS, SERVER_PORT), daemon=True
    ).start()

    Boombox(
        input=WebRTC("ws://localhost:8829"),
        output=HLS("../assets/hls_output/index.m3u8", mode="live"),
    )
