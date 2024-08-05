url =
  "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s.mp4"

# Boombox.run(
# input: url,
# output: [:file, :mp4, "output2.mp4"]
# )

# Boombox.run(input: [:webrtc, "ws://localhost:8829"], output: [:file, :mp4, "output.mp4"])
# Bandit.start_link(plug: HTTPServer.Router)

Boombox.run(
  input: [:file, :mp4, "test/fixtures/bun10s.mp4"],
  output: [:file, :mp4, "tmp/dupa2.mp4"]
  # output: "http://0.0.0.0:4000/tmp/dupa.mp4"
)

# Boombox.run(input: [:webrtc, "ws://localhost:8829"], output: [:webrtc, "ws://localhost:8830"])
# Boombox.run(input: [:rtmp, "rtmp://localhost:5000"], output: [:file, :mp4, "output2.mp4"])
# Boombox.run(input: [:rtmp, "rtmp://locaalhost:5000"], output: [:webrtc, "ws://localhost:8830"])
