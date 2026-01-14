from boombox import Boombox, RawData, VideoPacket

big_buck_bunny_url = "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4"

bb1 = Boombox(big_buck_bunny_url, RawData(video=True, audio=True))

with Boombox(RawData(video=True, audio=True), "inverted.mp4") as bb2:
    for packet in bb1.read():
        if isinstance(packet, VideoPacket):
            packet.payload = 255 - packet.payload
        bb2.write(packet)
