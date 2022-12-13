# Media Events

This document described all messages exchanged between the RTC Engine and a client.
In general, each media event has to be sent in the form:

```json
{
  type: name,
  data: data
}
```

where the name of the event is the value of the `type` field, while `data` should carry the data shown below for every media event

## Table of contents

Below you can find a summary of all media events defined inside `membrane_rtc_engine`

### Generic RTC Engine messages

Messages used by any RTC Engine plugin

#### RTC Engine receives these types of `media_events` from client:
| Name                                        | Description                                                   |
| ------------------------------------------- | ------------------------------------------------------------- |



#### RTC Engine sends these types of messages to the client:

| Name                              | Description                                                                             |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| [tracksPriority](#trackspriority) | contains all tracks that will be forwarded to peer until next `tracks_priority` message |
| [peerDenied](#peerdenied)         | sent if peer was rejected by server when joining to server                              |
| [peerUpdated](#peerupdated)       | contains new metadata of a peer                                                         |
| [trackUpdated](#trackupdated)     | contains new metadata of a track                                                        |
| [tracksAdded](#tracksadded)       | sent when some tracks were added by some peer                                           |
| [tracksRemoved](#tracksremoved)   | sent when some tracks were removed by some peer                                         |
| [peerJoined](#peerjoined)         | sent after a new peer has joined the RTC Engine                                         |
| [peerAccepted](#peeraccepted)     | sent to a peer after he joins the RTC Engine                                            |
| [peerLeft](#peerleft)             | sent when some peer lefts the RTC Engine                                                |
| [peerRemoved](#peerremoved)       | sent when peer is forcibly removed by the server                                        |
| [error](#error)                   | Notifies about an error that occurred                                                   |
| [custom](#custom-1)               | custom message forwarded from endpoint to client                                        |

### WebRTC custom media events

#### WebRTC endpoint receives these types of custom `media_event`s from client:

| Name                                            | Description                                                             |
| ----------------------------------------------- | ----------------------------------------------------------------------- |
| [renegotiateTracks](#renegotiatetracks)         | A request from a peer to renegotiate tracks                             |
| [prioritizeTrack](#prioritizetrack)             | A request to prioritize the track                                       |
| [unprioritizeTrack](#unprioritizetrack)         | A request to unprioritize the track                                     |
| [preferedVideoSizes](#preferedvideosizes)       | informs of how many videos in different quality a peer wants to receive |
| [candidate](#candidate)                         | Contains client's ICE candidate                                         |
| [sdpOffer](#sdpoffer)                           | Contains an SDP offer from a client                                     |
| [setTargetTrackVariant](#setTargetTrackVariant) | A request from a peer to receive a specific track variant               |

#### WebRTC endpoint sends these type of custom messages to client
| Name                                    | Description                                                       |
| --------------------------------------- | ----------------------------------------------------------------- |
| [offerData](#offerdata)                 | Sends data needed by the client to create an offer                |
| [candidate](#candidate-1)               | Contains an ICE candidate                                         |
| [sdpAnswer](#sdpanswer)                 | Provides an SDP Answer to the client's offer                      |
| [encodingSwitched](#encodingswitched)   | An information that a track will be sent with a specific encoding |


## Client -> RTC Engine

### `join`

* Sent when peer want to join RTC Engine. It contains only peer's metadata

  ```json
  {
    "metadata": any
  }
  ```

### `leave`

* Sent when peer leaves RTC Engine. It contains no data

  ```json
  {}
  ```

### `updatePeerMetadata`

* Contains new metadata of some peer

  ```json
  {
    "metadata": any
  }
  ```

### `updateTrackMetadata`

* Contains new metadata of some track and an id of this track

  ```json
  {
    "trackId": track_id,
    "trackMetadata": any
  }
  ```

### `custom`

* A black-box for a message that RTC Engine will forward to the endpoint associated with the peer who sent the message.

  ```json
  any
  ```

## RTC Engine -> Client

### `tracksPriority`

* Contains all tracks that will be forwarded to peer until the next `tracks_priority` message.
  This type of messages is sent only if DisplayManager is spawned

  ```json
  {
    tracks: tracks
  }
  ```

### `peerDenied`

* Sent if peer was rejected by server when joining to server. It may contain a reason for rejection.

  ```json
  {
    data: text
  }
  ```

### `peerUpdated`

* Contains information about updated metadata of one of the peers

  ```json
  {
    peerId: peer_id,
    metadata: any
  }
  ```

### `trackUpdated`

* Contains information about new metadata of one of tracks

  ```json
  {
    peerId: peer_id,
    trackId: track_id,
    metadata: any
  }
  ```

### `tracksAdded`

* Informs that one of the peers has added one or more tracks.
  It contains an id of that peer and a map of all tracks with `track_id`s as keys and `track_metadata` as value.

  ```json
  {
    peerId: peer_id,
    trackIdToMetadata: {
      track_id: any
    }
  }
  ```

### `tracksRemoved`

* Contains a list of tracks which have been removed by some peer and id of that peer

  ```json
  {
    peerId: peer_id,
    trackIds: track_ids
  }
  ```

### `peerJoined`

* Message sent to all peers in the room after a new peer has joined RTC Engine.
  It contains id and metadata of the new peer.

  ```json
  {
    peer: {
      id: peer.id,
      metadata: peer.metadata
    }
  }
  ```

### `peerAccepted`

* Message sent to the peer after he's joined the RTC Engine. It contains his id and a list of information about peers in the Engine
  (id, metadata and a `trackIdToMetadata` like seen in `tracksAdded`)

  ```json
  {
    id: peer_id,
    peersInRoom: peers
  }
  ```

### `peerLeft`

* Sent to all remaining peers in the room after some peer has left. It contains an id of the peer who left.

  ```json
  {
    peerId: peer_id
  }
  ```

### `peerRemoved`

* Sent to the peer that has been forcibly removed by the server

  ```json
  {
    peerId: peer_id,
    reason: any
  }
  ```

### `error`

* Informs that an error occurred on the server providing a message to show

  ```json
  {
    message: any()
  }
  ```

### `custom`

* A black-box for a message that the RTC Engine will forward to the client.

  ```json
  any
  ```

## Client -> WebRTC Enpoint

### `renegotiateTracks`

* Informs that a peer wants to renegotiate connection due to adding a track or removing a track

  ```json
  {}
  ```

### `prioritizeTrack`

* Contains an id of the track that the peer wants to prioritize

  ```json
  {
    trackId: trackId
  }
  ```

### `unprioritizeTrack`

* Contains an id of the track that the peer want to unprioritize.

  ```json
  {
    trackId: trackId
  }
  ```

### `preferedVideoSizes`

* Contains information of how many videos in different quality (high, medium, small) the peer would like to receive.
  `allSameSize` flag which indicates that all videos should be in the same quality.

  ```json
  {
    bigScreens: Int,
    mediumScreens: Int,
    smallScreens: Int,
    allSameSize: boolean
  }
  ```

### `candidate`

* Contains an ICE candidate that is forwarded to the WebRTC Endpoint

  ```json
  {
    candidate: candidate,
    sdpMLineIndex: Int
  }
  ```

### `sdpOffer`

* Contains an SDP offer, a mapping between `track_id` and `track_metadata`, and a mapping between `mid` and `track_id`.
  Both maps contain only information about current peer `sendonly` tracks.

  ```json
  {
    sdpOffer: {
      type: "offer",
      sdp: sdp_offer
    },
    trackIdToTrackMetadata: {
      trackId: any
    }
    midToTrackId: mid_to_track_id
  }
  ```

### `setTargetTrackVariant`

* Informs that a peer wants to receive a specific track variant. 
  The track variant will be sent whenever it is available.
  If choosen variant is unavailable, some other variant will be
  sent until choosen variant becomes active again.

  ```json
  {
    trackId => track_id,
    variant => variant
  }
  ```

## WebRTC Enpoint -> Client

### `offerData`

* Contains information about the number  of audio and video tracks that will be sent from the engine
  to the peer and information regarding the integrated TURN server.

  ```json
  {
    tracksTypes: {
      audio: Int,
      video: Int
    },
    integratedTurnServers: [{
      serverAddr: addr,
      serverPort: Int,
      transport: string,
      password: string,
      username: string
    }]
  }
  ```

### `candidate`

* Contains information about an ICE candidate which will be sent to the client

  ```json
  {
    candidate: candidate,
    sdpMLineIndex: sdp_m_line_index,
    sdpMid: nil,
    usernameFragment: nil
  }
  ```

### `sdpAnswer`

* Contains an SDP answer and mapping between `mid` and `track_id` for all tracks (active, inactive, inbound and outbound)

  ```json
  {
    type: "answer",
    sdp: sdp_answer,
    midToTrackId: mid_to_track_id
  }
  ```

### `encodingSwitched`

* Informs that track with id `trackId` belonging to peer with id `peerId` will be sent in encoding `encoding` now.

  ```json
  {
    peerId: peer_id,
    trackId: track_id,
    encoding: encoding
  }
  ```
