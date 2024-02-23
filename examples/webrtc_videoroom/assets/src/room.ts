import { MEDIA_CONSTRAINTS, LOCAL_ENDPOINT_ID } from "./consts";
import {
  addVideoElement,
  getRoomId,
  removeVideoElement,
  setErrorMessage,
  setParticipantsList,
  attachStream,
  setupDisconnectButton,
} from "./room_ui";
import {
  WebRTCEndpoint,
  Endpoint,
  TrackContext,
} from "@jellyfish-dev/membrane-webrtc-js";
import { Push, Socket } from "phoenix";
import { parse } from "query-string";

export class Room {
  private endpoints: Endpoint[] = [];
  private displayName: string;
  private localStream: MediaStream | undefined;
  private webrtc: WebRTCEndpoint;

  private socket;
  private webrtcSocketRefs: string[] = [];
  private webrtcChannel;

  constructor() {
    this.socket = new Socket("/socket");
    this.socket.connect();
    this.displayName = this.parseUrl();
    this.webrtcChannel = this.socket.channel(`room:${getRoomId()}`);

    this.webrtcChannel.onError(() => {
      this.socketOff();
      window.location.reload();
    });
    this.webrtcChannel.onClose(() => {
      this.socketOff();
      window.location.reload();
    });

    this.webrtcSocketRefs.push(this.socket.onError(this.leave));
    this.webrtcSocketRefs.push(this.socket.onClose(this.leave));

    this.webrtc = new WebRTCEndpoint();

    this.webrtc.on("sendMediaEvent", (mediaEvent: string) => {
      this.webrtcChannel.push("mediaEvent", { data: mediaEvent });
    })

    this.webrtc.on("connectionError", setErrorMessage);

    this.webrtc.on("connected", (endpointId: string, otherEndpoints: Endpoint[]) => {
      this.localStream!.getTracks().forEach((track) =>
        this.webrtc.addTrack(track, this.localStream!, {})
      );

      this.endpoints = otherEndpoints;
      this.endpoints.forEach((endpoint) => {
        addVideoElement(endpoint.id, endpoint.metadata?.displayName || "File video", false);
      });
      this.updateParticipantsList();
    });
    this.webrtc.on("connectionError", (message: string) => { throw `Endpoint denied.` });

    this.webrtc.on("trackReady", (ctx: TrackContext) => {
      attachStream(ctx.stream!, ctx.endpoint.id)
    });

    this.webrtc.on("endpointAdded", (endpoint: Endpoint) => {
      this.endpoints.push(endpoint);
      this.updateParticipantsList();
      addVideoElement(endpoint.id, endpoint.metadata?.display_name || "File video", false);
    });

    this.webrtc.on("endpointRemoved", (endpoint: Endpoint) => {
      this.endpoints = this.endpoints.filter((endpoint) => endpoint.id !== endpoint.id);
      removeVideoElement(endpoint.id);
      this.updateParticipantsList();
    });

    this.webrtcChannel.on("mediaEvent", (event: any) =>
      this.webrtc.receiveMediaEvent(event.data)
    );
  }

  public join = async () => {
    try {
      await this.init();
      setupDisconnectButton(() => {
        this.leave();
        window.location.replace("");
      });
      this.webrtc.connect({ displayName: this.displayName });
    } catch (error) {
      console.error("Error while joining to the room:", error);
    }
  };

  private init = async () => {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia(
        MEDIA_CONSTRAINTS
      );
    } catch (error) {
      console.error(error);
      setErrorMessage(
        "Failed to setup video room, make sure to grant camera and microphone permissions"
      );
      throw "error";
    }

    addVideoElement(LOCAL_ENDPOINT_ID, "Me", true);
    attachStream(this.localStream!, LOCAL_ENDPOINT_ID);

    await this.phoenixChannelPushResult(this.webrtcChannel.join());
  };

  private leave = () => {
    this.webrtc.disconnect();
    this.webrtcChannel.leave();
    this.socketOff();
  };

  private socketOff = () => {
    this.socket.off(this.webrtcSocketRefs);
    while (this.webrtcSocketRefs.length > 0) {
      this.webrtcSocketRefs.pop();
    }
  };

  private parseUrl = (): string => {
    const { display_name: displayName } = parse(document.location.search);

    // remove query params without reloading the page
    window.history.replaceState(null, "", window.location.pathname);

    return displayName as string;
  };

  private updateParticipantsList = (): void => {
    const participantsNames = this.endpoints.map((e) => e.metadata?.displayName || "File video");

    if (this.displayName) {
      participantsNames.push(this.displayName);
    }

    setParticipantsList(participantsNames);
  };

  private phoenixChannelPushResult = async (push: Push): Promise<any> => {
    return new Promise((resolve, reject) => {
      push
        .receive("ok", (response: any) => resolve(response))
        .receive("error", (response: any) => reject(response));
    });
  };
}
