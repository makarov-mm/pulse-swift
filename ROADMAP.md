# Makarov Pulse for macOS — roadmap

The goal is to follow a resource spike from a system graph to the process, interface, or folder that explains it. Keep the Windows edition’s always-visible overview, searchable tables, predictable sorting and side inspector. Use macOS conventions for menus, keyboard shortcuts, selection, window appearance, and Finder actions.

## Starting point

The **0.1 source foundation** includes native sampling, three sortable views, a read-only process inspector, Finder reveal, four one-minute graphs, pause and refresh controls, and an About panel crediting Mykhailo Makarov. CPU rate calculations, PID reuse, resets, sleep gaps, exact PID search and history retention have automated test cases. M0 is the first native acceptance gate. Later milestones describe proposed work.

## Status

| Milestone | State |
| --- | --- |
| M0 | Partly done: the package builds and `swift test` passes on Apple silicon with a current macOS. The window was exercised there: all views open, sorting, tree collapse and filter, interface and process selection, the inspector, and an interval ranking that lists an exited process. Open: a controlled one-core load, pause/resume, light appearance, narrow window, VoiceOver, sleep/wake, the Folder and Captures file dialogs, an Intel Mac, the minimum macOS 14 release, and the measurements. |
| M1 | Implemented in source: 1/5/15-minute history with per-sample CPU leaders, interval ranking, parent tree with collapsible branches, pinned instance timelines, stored sort order and column layout per view. Unit-tested where it has tests. Awaiting the M1 acceptance run. |
| M2 | Implemented in source: per-logical-core graphs, receive/send graph for a selected interface, per-device read/write throughput from IOBlockStorageDriver statistics with a registry-entry identity. Unit-tested where it has tests. Awaiting the M2 acceptance run. |
| M3 | Implemented in source: folder picker, cancellable background scan from file metadata, squarified treemap, sortable child list, drill-down, breadcrumb and parent navigation, Finder reveal, logical and allocated bytes, partial totals. Policy: links are not followed, packages are entered, other volumes and undownloaded cloud folders are listed and not entered, a hard link is counted once. APFS clones are counted in full at every path. Unit-tested where it has tests. Awaiting the M3 acceptance run. |
| M4 | Implemented in source: threads, descriptor counts and IPv4/IPv6 socket endpoints of the selected instance with an identity check before and after the read, user names beside UIDs, a confirmed Quit request for regular apps of the current user, and a read-only list of launchd job definitions with a link to Login Items settings. Unit-tested where it has tests. Awaiting the M4 acceptance run. |
| M5 | Implemented in source: versioned JSON capture with units, monotonic offsets, wall-clock times, cadence, OS/hardware metadata, coverage and gaps; offline replay with interval ranking; two-run comparison by process name with notes on differing core counts, architectures and intervals; opt-in executable paths. Endpoint addresses are never saved. Unit-tested where it has tests. Awaiting the M5 acceptance run. |
| M6 | Partly prepared: the build script can produce a universal binary and sign with a Developer ID and the hardened runtime, and the overview graphs have spoken descriptions. Open: bundle ID decision, notarization, a clean-Mac test, the string catalog, UI tests, the capability table. |

## What fits macOS

| Windows workflow | macOS approach | Boundary or release condition |
| --- | --- | --- |
| Task Manager CPU and per-core graphs | Read host and per-core Mach counters. Show host percentage on a 0–100 scale and process percentage per logical core. | Core counts and topology differ across machines. Expose efficiency/performance clusters only when a tested source identifies them. [Mach host processor information](https://developer.apple.com/documentation/kernel/1502854-host_processor_info) |
| Process table, tree, threads, and executable location | The foundation reads BSD identity and available task counters. Build trees from PPID and start time. Resolve paths only for the selected instance. | Access varies by process and OS version. Apple marks the libproc interfaces subject to change. Keep them behind the collector, test each supported SDK, and retain usable BSD rows when richer reads fail. Register a new PID generation when its start time changes. [Apple’s libproc header](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h) |
| Memory graph and working-set comparison | Expose wired, compressed, resident, and physical footprint as separately named metrics where available. Add reported pressure events with their source. | Shared pages affect totals. Pressure depends on several signals. A percentage of RAM in use cannot reproduce Activity Monitor’s pressure graph. [Activity Monitor memory metrics](https://support.apple.com/guide/activity-monitor/actmntr1004/mac) · [Memory pressure events](https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent) |
| Disk I/O and folder treemap | Keep volume capacity, per-device transfer rates, and a user-selected folder scan in separate views. Probe device counters across internal and external storage. | A logical APFS volume may share its container. Hard links, clones, sparse files and snapshots complicate any estimate of reclaimable space. Folder reads also follow file permissions and privacy choices. [Allocated size](https://developer.apple.com/documentation/foundation/urlresourcevalues/totalfileallocatedsize) · [APFS file system formats](https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/mac) |
| Network adapters, sockets, and per-process traffic | Ship interface counters first. Prototype on-demand socket endpoint snapshots for accessible processes. | Interface totals cannot identify an owning process. Polling can miss short-lived sockets. Process ownership and inspection rights limit coverage. A flow observer using Network Extension would be a separate product decision with its own entitlement, consent, and overhead. [Interface counters](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_mib.h) · [Network Extension entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) |
| End process, service control, and startup management | Offer graceful Quit for eligible applications, then consider a confirmed terminate action for owned processes. Treat launchd jobs and login items as distinct objects. Link to the system Login Items settings. | Recheck identity and ownership before acting. POSIX signaling leaves a small PID-reuse race even after a check. Prefer an app-instance API when available and reject ambiguous targets. SMAppService manages helpers associated with the calling app. A general toggle for arbitrary third-party jobs cannot use this API. SIP also protects system processes. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) · [Runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html) |
| Services, registry and cleanup tools | Expose readable launch agent/daemon metadata, domain and source. For storage triage, offer **Reveal in Finder** after a scan. | macOS has no Windows Registry. Preferences, managed profiles and launchd jobs have different owners and semantics. Leave automatic cache deletion, system job editing and a generic preferences editor outside the monitor. |
| GPU engines, energy and package sensors | Investigate supported system/device summaries. Show API and hardware coverage beside any experimental reading. | Metal counter sampling is scoped to supported devices and instrumented GPU work. It does not give this app a universal per-process GPU or power ledger. Avoid assigning invented watts or translating Activity Monitor’s Energy Impact into watts. [Metal GPU counters](https://developer.apple.com/documentation/metal/gpu-counters-and-counter-sample-buffers) |
| Continuous privileged event tracing | Build useful timelines from ordinary snapshots first. Consider Endpoint Security only for a separately justified event-monitoring feature. | Endpoint Security needs an Apple-granted entitlement. A privileged helper does not remove SIP or privacy protections. Keep the standard-user monitor independently usable. [Apple system extensions](https://developer.apple.com/system-extensions/) · [Endpoint Security](https://developer.apple.com/documentation/endpointsecurity) |

## Milestones

### M0 · Validate the foundation on a Mac

**First deliverable.** Run `swift test`, build the local app bundle, and launch as a standard user. Exercise Apple silicon first and repeat on an Intel Mac before claiming support for both. Cover the minimum macOS 14 release and a current macOS release.

**Acceptance.** Generate CPU load on one core using a disposable worker. The process should approach 100% while host utilization reflects the number of available cores. Compare the trend with Activity Monitor at a similar interval. Select the worker, reveal its executable, let it exit, and verify that selection clears. Exercise sorting, ⌘F, pause/resume, dark/light appearance, narrow-window resizing, and VoiceOver. Check permission-denied, disconnected-interface and sleep/wake behavior. Record OS, chip, interval, idle CPU, busy CPU, memory footprint and overrun frequency before setting performance budgets.

### M1 · Explain a spike after the worker exits

**Build after M0.** Retain 1, 5 and 15 minutes of host samples with their leading processes. Add a searchable parent tree, collapsible branches and pinned instance timelines. Keep process names readable while columns resize or reorder. Store table preferences separately for each view.

**Acceptance.** Run a named worker for 20 seconds. Five minutes after it exits, select its graph interval and identify its PID, start time and measured CPU contribution. Searching a child keeps its parent chain visible. A reused PID must never inherit the previous worker’s series. Save and restore independent table layouts at two window widths.

### M2 · Identify the busy device

**Build after M0.** Add per-logical-core graphs, receive/send overlays for a pinned interface, and per-device disk read/write throughput where drivers expose cumulative counters. Keep a device identity with each sample. Display unavailable fields for unsupported devices. Keep free-space and throughput units distinct.

**Acceptance.** During a controlled file copy, find the active device. During a transfer, identify the active interface and direction. Disconnect a test interface, then reconnect and verify a new baseline. Test a VPN alongside its underlying interface without presenting a double-counted machine total. Use the M0 measurements to profile one- and five-second updates.

### M3 · Find where a folder’s space went

**Build after M0, independently of M2.** Add a folder picker, cancellable background scan, treemap, sortable child list, drill-down, parent navigation and Finder reveal. Show logical and allocated bytes separately. Track unreadable locations and mark the result partial. Set an explicit policy for symbolic links, package directories, mount boundaries and hard links. Avoid hydrating cloud-only files during a size survey.

**Acceptance.** Scan a fixture with a known folder ranking, a symlink loop, a hard link, a sparse file and an unreadable subtree. Verify breadcrumb navigation, partial totals and responsiveness during cancellation. Repeat on APFS with a clone. Document which displayed totals can share underlying blocks. Reopening the folder after permission is declined must still leave the other views usable.

### M4 · Inspect and act within the current user’s session

**Build after M1.** Inspect readable threads and descriptors for one selected process. Group processes by UID and offer best-effort socket snapshots with protocol, address, state and owner when available. Keep network rates at interface level until attribution has an independently verified source. Add a separate, confirmed Quit action for eligible user apps. Introduce launchd/login-item discovery as read-only.

**Acceptance.** Inspect a test app, a child worker, a loopback connection and an inaccessible system process. Switch selection during a slow read and confirm stale details never appear. Quit only a disposable owned app and handle refusal or exit cleanly. Test both IPv4 and IPv6, and check that an endpoint disappearing between reads results in a partial snapshot.

### M5 · Save, replay and compare investigations

**Build after M1.** Export a versioned capture with units, monotonic offsets, wall-clock timestamps, sampling cadence, OS/hardware metadata, coverage and gaps. Replay a selected interval offline. Compare two runs and annotate different core counts, architectures and sample intervals. Give the user control over including executable paths and endpoint addresses.

**Acceptance.** Export two runs of the same workload, move the files to a different Mac, and reproduce interval rankings without live process access. Test truncated files, unsupported schema versions, sleep gaps and PID reuse. Explore Windows/macOS comparison only for metrics with documented matching semantics.

### M6 · Ship a distributable Mac application

**Release gates.** Build and run both target architectures for a universal release, or publish distinctly labeled per-architecture builds. Set the final bundle ID, sign with Developer ID and hardened runtime, notarize, staple and test a downloaded copy on a clean Mac. Treat a Mac App Store edition as a separate sandboxed capability profile and test the reduced coverage. Introduce a string catalog, system-language selection with English fallback, accessibility descriptions for historical charts, and UI tests with long translations. [Universal binaries](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary) · [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) · [Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

**Acceptance.** Launch from Finder on each supported machine without development tools. Check Gatekeeper assessment, sampling as a standard user, system appearance changes, keyboard-only navigation, and the About credit. Publish a capability table showing verified OS/chip combinations and observed restrictions.
