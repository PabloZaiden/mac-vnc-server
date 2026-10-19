# Apple Screen Sharing idle keepalive investigation

Investigated on 2026-10-17. Apple's native TCP server sends an application-level
**MiscStatus command 4**, called a **“tickle packet”** in both the server and
client implementation. It maintains receive activity independently of framebuffer
updates. This is the missing behavior most strongly indicated by the supplied
Screen Sharing 3.0 minimize/reconnect logs.

The server implementation and current client handler were verified by binary
inspection on macOS **26.6.2 (25G83)**. The supplied Screen Sharing **3.0 (585.1)**
app was inspected, but its macOS 13.1 ScreenSharing framework was not available.
Consequently, the exact Ventura handler and timeout were not directly verified;
the user's Ventura logs provide the behavioral evidence described below.

**Native TCP server behavior.** The installed
`/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/MacOS/AppleVNCServer`
is version **3.9.8 (744.4)**. Its embedded source labels identify
`RFBServer/TicklePacketTimer.c`, `TickleTimer_CreateIfNecessary`, and
`TickleTimer_Cleanup`.

The timer checks viewers every **2.1 seconds**. For an established TCP viewer
that advertises support for server message `0x14`, is not stopped, has no pending
outgoing bytes, and has had no write activity for **more than 2 seconds**, it
queues this eight-byte RFB message:

```text
14 00 00 04 00 01 00 04
```

| Bytes | Meaning |
| --- | --- |
| `14` | Server message type 20: MiscStatus |
| `00` | Padding |
| `00 04` | Big-endian body length: 4 bytes |
| `00 01` | Big-endian version: 1 |
| `00 04` | Big-endian command: 4, tickle |

The timer's conditions do not depend on an outstanding framebuffer request or
automatic updates being enabled. Thus a viewer can pause screen updates while
continuing to receive tickles. Ordinary outgoing traffic postpones the tickle;
2.1 seconds is the timer cadence, not a fixed interval after every last frame.
The packet goes through Apple's normal output queue. There is no application
reply required from the viewer.

The interval constant is a decoded IEEE-754 double, not a guessed unit. The idle
threshold is `2,000,001` microseconds. Apple's clock helper converts
`mach_absolute_time()` using `mach_timebase_info().numer / denom / 1000`.

**Client behavior.** In the installed ScreenSharing framework,
`HandleServerMessage` dispatches MiscStatus command 4 to a branch that logs
`tickle packet` and returns success. That branch makes no socket write and invokes
no session/UI callback. `ServerListenerThread` then reads the next message.
The packet therefore creates receive activity without changing the desktop,
clipboard, control permission, or window state.

The framework's `-[SSSession stConfigureSession]` calls
`RFBSetReceiveTimeout(connection, 13)` on its native-server path. The latter uses
`setsockopt(SOL_SOCKET, SO_RCVTIMEO, timeval{13, 0})`. This path is conditional on
connection state and capabilities, rather than a timeout applied to every RFB
connection: the examined implementation checks server capability bits `0x22`
and `0x15`, as well as internal state flags. The current server advertises those
capabilities when its file-transfer profile is enabled.

Kernel TCP keepalive probes cannot satisfy this receive timeout: their ACKs do
not deliver application bytes to `read`/`recv`. The existing `Socket.configureTCP`
settings detect an unreachable peer, but cannot replace Apple's RFB tickles.

**Evidence from the reported failure.** The current server treats
`AutoFrameBufferUpdate interval_us=4294967295` as disabling automatic screen
updates. The supplied trace repeatedly becomes silent and then loses the viewer
approximately 13 seconds later:

| Last pause or frame, UTC 2026-10-16 | Reader disconnect, UTC | Gap |
| --- | --- | --- |
| Pause 16:39:49.787 | 16:40:02.789 | 13.002 s |
| Pause 16:41:45.335 | 16:41:58.342 | 13.007 s |
| Last frame 16:41:58.704 | 16:42:11.751 | 13.047 s |
| Last frame 16:42:12.110 | 16:42:25.174 | 13.064 s |
| Last frame 16:42:25.570 | 16:42:38.616 | 13.046 s |

The last three connections send only their two initial framebuffer updates,
remain paused, and disconnect again. The worker PID stays 27721; new connection
UUIDs and source ports show successive connections from the one viewer, not
multiple simultaneously running clients or worker restarts. Disconnect reports
show `source=reader`, last client message `0x09`, and `network_stalls=0`.

The supplied client log independently records the following sequence, in
Asia/Shanghai local time on 2026-10-17:

```text
00:40:02.678  readsocket error -1
00:40:02.689  setting state: reconnecting
00:40:02.956  set receive time
00:40:02.982  setting state: connected
00:40:03.608  windowDidDeminiaturize
00:40:04.388  windowDidBecomeKey
```

That sequence supports a receive-idle disconnect followed by automatic reconnect
and window restoration. `readsocket error -1` does not include errno, so the
remote client's precise socket error remains unproven. The repeated 13-second
gaps and directly verified Apple implementation make a missing tickle the leading
explanation. No idle A/B test against the actual macOS 13.1 client has yet been
performed.

**Implementation in release 1.6.** Before this change, at source revision
`56cff5f3fc5c0e47602c5d8de3d4ccaf905f5078`, `AppleRFB.status(4)` already constructs
the correct bytes, but there is no caller sending periodic command-4 tickles.
`handleAppleViewerInfo` retains the viewer capability bitmap and already logs
whether `0x14` is supported. The user's trace says `status=true`.

Release 1.6 checks idle time in the existing per-connection writer every 2.1
seconds, requires Apple extensions and negotiated `0x14` support, and sends
`AppleRFB.status(4)` through the normal serialized/encrypted write path after
more than two seconds without outgoing traffic. It continues while automatic
framebuffer updates are paused and clipboard synchronization is disabled.
`ClientSocket` tracks successful scalar and vectored writes with a monotonic
clock, including encrypted records and previous tickles. Queued writer commands
take priority, and the existing writer error/cleanup path handles failures.
Verbose logs report `Apple MiscStatus: tickle sent command=4`, idle duration, and
count; disconnect summaries retain the original failure and add `apple_tickles`.

The socket integration regressions passed for paused viewers for longer than 13
seconds with and without server clipboard support, unsupported viewers, outgoing
frame/clipboard activity postponing tickles, and encrypted records across rekeys.
An opt-in probe using the actual macOS 26.6.2 ScreenSharing framework also passed
in both plaintext and encrypted sessions: it sent the same automatic-update
pause request as minimization, retained the same connection for 16 seconds with
pixels frozen, received seven tickles, then resumed rendering. It uses synthetic
pixels and mock input on an isolated loopback server. The probe is in
`scripts/probe-native-screen-sharing.m`; results are retained in
`.build/release-1.6/native-idle-tests.log`.

The remaining validation on the actual 3.0 client is to keep its window minimized
across several 13-second intervals while confirming the same connection UUID and
no restore/focus event. Building the release does not restart the running server.

**Other Apple timers.** A separate `KeepAliveTimer_Init` associated with
`ScreenTracker.m` uses a 10-second timer and marks a 1×1 rectangle dirty. Its
setup is gated on an alternate-transport field. It is distinct from the TCP
`TicklePacketTimer.c` mechanism above and should not be used as the model for
paused TCP sessions.

**Reproducibility and provenance.** Local analysis artifacts are in
`.build/apple-idle-keepalive-20261017/`. The native server addresses below are
unslid arm64e addresses; framework addresses are process addresses from this
boot and may change. Field names inferred from disassembly are not public ABI.

| Evidence | Location |
| --- | --- |
| Tickle timer creation | `AppleVNCServer.asm`, `0x10006e62c` |
| Timer constant 2.1 | Native server `0x1000b3678`; `decoded-constants.json` |
| Tickle callback, eligibility, wire construction | Native server `0x10006e798`–`0x10006e8f8` |
| Viewer capability check | Native server `0x100048288` |
| Last-write clock update | Native server `0x100008198`, viewer offset `0xdf8` |
| Microsecond clock conversion | Native server `0x100059d7c`, initialization `0x10005a440`, divisor at `0x1000b2f88` |
| Client timeout argument 13 | `client-timeout.asm`, `0x1c9aa2570` |
| Client `SO_RCVTIMEO` setup | `client-receive.asm`, `0x1c9b8156c`–`0x1c9b81588` |
| Command 4 dispatch | `client-tickle-switch.asm`: entry 3 at table `0x1c9aa69d4` is `0xd74`; `0x1c9aa4b28 + 0xd74 = 0x1c9aa589c` |
| Tickle branch and successful return | `client-handler.asm`: `0x1c9aa589c` → `0x1c9aa4de4` → `0x1c9aa5060` → `0x1c9aa5e58` → return 0 |
| Read next message on success | `client-dispatch.asm`, `ServerListenerThread`, `0x1c9aa22d0` |

Native AppleVNCServer universal executable SHA-256:
`04e1d46d42fb145b62ba2c50e0bc5873cf7b0fb9a455349f7438d93f53e53234`.

The copied `/Users/revin/code/Screen Sharing.app` is genuinely version 3.0
(585.1), but dynamically links the OS's
`/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing`.
Copying the app does not copy Ventura's implementation. Running it on this Mac
uses the macOS 26 framework and encounters a removed private selector, as already
documented in `docs/apple-file-transfer.md`. Neither that run nor the current
framework disassembly is presented here as direct verification of Ventura's
framework.

The client trace is preserved at
`/Users/revin/.codex/attachments/102265c0-e75f-4387-a764-09a64222eb95/Pasted text.txt`;
the quoted client events are on lines 191, 209, 267, 364, 3999, and 10329.
