# Makarov Pulse for macOS

A native SwiftUI system monitor by **Mykhailo Makarov**. The live resource graphs stay above the process list while you search, sort, or inspect a worker. The first release target is macOS 14 or later on Apple silicon and Intel.

## Why open Pulse alongside Activity Monitor?

| Question | Workflow in this foundation |
| --- | --- |
| What changed while I was looking at a process? | Keep the last minute of host CPU, wired memory, startup data-volume free space, and network activity in sight. Pause the display to read a row. |
| Which process instance am I inspecting? | Search by name or exact PID, then select a row. The inspector follows both PID and start time. When the executable is accessible, reveal it in Finder. |
| Is network activity on Wi-Fi, a tunnel, or another interface? | The Network card names the busiest measured interface. Switch to Network to compare receive and send rates for individual interface names. |

The Windows edition inspired the arrangement. On macOS, host CPU use, process CPU use, wired memory, resident memory and disk capacity answer different questions. The table below gives their units. Apple's Activity Monitor guide describes how macOS distinguishes memory categories and pressure. [Apple’s memory guide](https://support.apple.com/guide/activity-monitor/actmntr1004/mac)

## Build and run on a Mac

Install Xcode 15 or later with a macOS 14 or newer SDK. Open Terminal in the extracted directory and run the following commands.

```sh
swift test
sh scripts/build-app.sh
open "dist/Makarov Pulse.app"
```

The script builds for the current Mac’s architecture and ad-hoc signs the local development bundle. For development, open `Package.swift` in Xcode and select the **MakarovPulse** executable scheme and **My Mac**. You can also run `swift run MakarovPulse`. The package has no external Swift dependencies. A GitHub Actions workflow runs the tests and builds the bundle on a macOS runner when placed in its own repository.

## Use the monitor

- Choose **Processes** for CPU load and resident memory. Choose **Details** for parent PID, numeric user ID and threads. Click a column heading to sort or reverse it.
- Press **⌘F** to focus the current table’s filter. Enter a name fragment, a PID, or an expression such as `pid: 1234`. Select a process for its inspector.
- Choose **Tree** for the parent/child view. Collapse a branch with its chevron. A filter keeps every ancestor of a matching process visible.
- Pick a 1-, 5- or 15-minute history in the toolbar. Drag across the CPU graph to rank the processes that were busiest in that interval, including ones that have already exited. The ranking shows PID, start time, average CPU and CPU time. It is built from the eight busiest processes of each sample.
- Select a process and choose **Pin timeline** to keep that instance's CPU graph above the table. The series is keyed by PID and start time, so a reused PID never continues it.
- Column widths, order and visibility, and the sort order, are stored separately for Processes and Details.
- Choose **Cores** for one graph per logical core.
- Choose **Disks** for cumulative bytes and read/write rates per storage device. Select a device to graph both directions. A device whose driver publishes no statistics shows —. These are transfer rates. The Disk space card stays a capacity reading.
- Choose **Network** to see measured interfaces that are up and non-loopback. The filter accepts interface names such as `en0`. Select an interface to graph its receive and send rates. A VPN tunnel and its underlying interface can both carry the same traffic.
- Choose a one-, two- or five-second refresh interval. **⇧⌘P** pauses or resumes updates. After resuming, the first sample establishes a new baseline.
- Choose **Makarov Pulse → About Makarov Pulse** for the version and developer credit. The English interface follows the system appearance and accent.

## Reading the numbers

| Reading | Meaning |
| --- | --- |
| CPU card | Busy CPU ticks as a percentage of total host ticks, from 0% to 100%. |
| Process CPU | CPU time consumed between observations. One fully occupied logical core gives about 100%. A multithreaded process can exceed it. |
| Wired memory | Wired pages multiplied by the system page size. The denominator is installed physical RAM. |
| Resident memory | Resident bytes reported for the task. Pages can be shared. Adding every row would count some pages more than once. |
| Disk space | Available capacity on the startup **data** volume. This card measures bytes of available space. Disk throughput and folder scanning are planned separately. |
| Network | Change in cumulative 64-bit interface byte counters divided by elapsed time. The card uses the busiest readable interface’s combined rate. Its graph breaks when the selected interface changes. |
| — | A baseline is still forming, a counter reset, or the OS withheld a reading. The status line shows how many listed processes could be identified. |

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/PulseCore/` | Process identity, sample deltas, search, and bounded history. The core also builds on other Swift platforms. |
| `Sources/PulseMac/` | macOS collectors and executable identity checks. One actor serializes OS reads away from the UI. |
| `Sources/DarwinHeaders/` | A module map and include-only header expose the installed SDK declarations to Swift. |
| `Sources/MakarovPulse/` | SwiftUI window, live charts, sortable tables, AppKit About panel, and Finder integration. |
| `Tests/` | Deterministic model tests and a macOS smoke test that inspects its own test process. |
| `Packaging/`, `scripts/` | Bundle metadata and local app packaging. |

Swift 5.9.2 parsed all ten Swift files. The portable core compiled on Windows and all five model tests passed there. Building the native window, running the Darwin sampler smoke test, and checking both Mac architectures still require macOS. The platform capability matrix and milestone acceptance criteria are in [ROADMAP.md](ROADMAP.md).
