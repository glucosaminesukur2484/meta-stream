# Privacy blur forces a transcode, and wins over every other codec input

The glasses hand us encoded HEVC that we normally pass through untouched, but blurring a frame
means decoding, modifying and re-encoding it — so enabling privacy blur forces a transcode on
every destination, costs latency, heat and battery, and re-imposes the Picture-in-Picture
requirement for background streaming. We accept that cost for blur and reject it for decorative
overlays, because privacy is worth a transcode and a scoreboard widget is not.

Where inputs conflict, the codec is decided in this order:

> **blur > explicit codec > protocol capability > destination table**

## Consequences

The conflict case is a user who explicitly selects HEVC and then enables blur. These are
physically incompatible — you cannot blur a frame you never decode — and **blur wins, visibly**:
the heads-up display states its reason ("H.264 · blur" rather than "HEVC · passthrough") and the
settings toggle spells out the cost where the user makes the choice.

Silently disabling blur to honour the codec selection was rejected outright. It fails *open* on
a privacy feature, which is the exact failure the rest of the blur design exists to prevent —
the streamer is trusting it, so it must fail closed and loudly or not ship.

This also means blur cancels the payoff of SRT output. Sending HEVC over SRT to a relay is what
removes the transcode and lets a stream survive backgrounding without the PiP window; turning
blur on takes that back. The two are mutually exclusive wins and the user should choose
knowingly rather than discover it when the stream freezes in their pocket.

Blur is per-stream, never per-destination: one encoder and one outgoing stream mean a
per-destination variant would require encoding every frame twice, and through a relay it is
impossible anyway, since one ingest feeds every destination.
