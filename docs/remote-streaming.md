# Remote stream acknowledgments

This note describes current source builds. It does not announce a published release.

For an active `capture.stream.start` session, the viewer sends
`capture.stream.ack {streamId, seq}` on the connection that started the stream.
Each acknowledgment covers all frames through `seq`. Send an acknowledgment
when each frame arrives.

Linux hosts allow `max(4, ceil(fps × 0.2))` frames to remain unacknowledged:
six at 30 fps and twelve at 60 fps. This capacity lets a 60 fps stream continue
when acknowledgment round trips exceed the 67 ms ceiling of a four-frame window.
The pending queue remains bounded by 200 ms of age, 200 ms of frames, and 4 MiB.
These are queue limits, not a guarantee of end-to-end latency.

Mac hosts retain a four-frame window and pause input to the encoder at that
limit. Both hosts end the stream after roughly three seconds without
acknowledgment progress while frames remain outstanding.
