const videoPlayer = document.getElementById("videoPlayer");
const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const proto = window.location.protocol === "https:" ? "wss:" : "ws:"
const ws = new WebSocket(`${proto}//localhost:8830`);
ws.onopen = () => start_connection(ws);
ws.onclose = event => console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  videoPlayer.srcObject = new MediaStream();

  const pc = new RTCPeerConnection(pcConfig);
  pc.ontrack = event => videoPlayer.srcObject.addTrack(event.track);
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice_candidate", data: event.candidate }));
  };

  ws.onmessage = async event => {
    const { type, data } = JSON.parse(event.data);

    switch (type) {
      case "sdp_offer":
        console.log("Received SDP offer:", data);
        await pc.setRemoteDescription(data);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        ws.send(JSON.stringify({ type: "sdp_answer", data: answer }));
        console.log("Sent SDP answer:", answer)
        break;
      case "ice_candidate":
        console.log("Recieved ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };
};