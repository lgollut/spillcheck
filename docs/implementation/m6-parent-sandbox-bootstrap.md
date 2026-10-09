# Apple primary-source evidence for the M6 sandbox bootstrap

Research date: 2026-10-08. Local Apple sources were inspected on macOS 26.6.2, build 25G83. Apple source research and disposable fixtures are recorded separately below. The fixtures ran Python probes and the existing signed Betterleaks child; no GUI application, provider session, authentication prompt, production code change, app build, or host-network configuration change occurred.

## Finding

Apple's shipped profiles support the proposed syntax and the intended behavior of launching a selected executable without the parent's sandbox. The [disposable fixture report](m6-parent-sandbox-bootstrap.json) additionally verifies that the custom exception lets the signed installed scanner apply its unchanged production profile on this host.

```scheme
(version 1)
(allow default)
(deny network*)
(allow process-exec
    (literal "/usr/bin/sandbox-exec")
    (with no-sandbox))
```

## Direct evidence

- Apple's `sandbox(7)` says new processes inherit their parent's sandbox. It also explains that restrictions normally apply when acquiring resources, and already-open file descriptors remain usable. See `/usr/share/man/man7/sandbox.7`, lines 45-54.
- The Apple SDK header documents why ordinary reinitialization fails: if a process is already sandboxed, `sandbox_init` ignores the new profile and returns an error. See the macOS SDK's `usr/include/sandbox.h`, lines 24-27. This documents `sandbox_init`, rather than every private sandbox API or the current implementation of `sandbox-exec`.
- Apple's shipped `opendirectoryd` profile explicitly distinguishes `nsupdate`, which launches in the daemon's sandbox, from `kextcache` and `slapconfig`, which launch unsandboxed. Only the latter rule contains `(with no-sandbox)`. This is direct Apple evidence of the modifier's intended inheritance exception. See `/System/Library/Sandbox/Profiles/com.apple.opendirectoryd-deny-default.sb`, lines 151-160.
- The exact ordering proposed above, with `literal` before `with`, appears in a shipped version 1 profile: `(allow process-exec (literal "/usr/sbin/pppd") (with no-sandbox))`. See `/System/Library/Sandbox/Profiles/com.apple.nesessionmanager.sb`, lines 96-99; profile version is at line 1. Apple also places the modifier before the literal in another version 1 profile. See `/System/Library/Sandbox/Profiles/com.apple.SubmitDiagInfo.sb`, lines 64-66; profile version is at line 7.
- `sandbox-exec(1)` documents that the utility accepts a profile through `-p`, `-f`, or `-n`, enters that sandbox, and executes the supplied command and arguments. See `/usr/share/man/man1/sandbox-exec.1`, lines 24-45.

## Consequences for Spillcheck

The supported interpretation is a policy transition at execution: the parent process keeps its network-denying profile, an execution matching `/usr/bin/sandbox-exec` receives the inheritance exception, and that utility can then try to enter the scanner's own profile. The fixture confirms this transition with Spillcheck's production profile unchanged at [ScannerProcess.swift](../../Sources/SpillcheckCore/ScannerProcess.swift#L7). The existing argument construction passes that profile through `-p` at [ScannerProcess.swift](../../Sources/SpillcheckCore/ScannerProcess.swift#L48). The recorded controls verify ordinary nesting failure with exit 71, successful application of the production profile after the exception, parent IPv4/IPv6 denial before and after bootstrap, and production-profile leaf IPv4/IPv6 and fork denial. The signed scanner detects the exact synthetic value with no diagnostics.

The exception scopes an executable path, not its arguments or caller intent. `sandbox-exec` publicly accepts caller-selected profiles and commands. Therefore, if the exception works, a process allowed to execute this system binary can request a permissive profile and run a different command. It is a generic bootstrap escape from the parent profile, even though the executable is trusted and fixed. The proposed rule cannot by itself require the production scanner profile or guarantee network denial for every descendant. Those guarantees depend on the trusted caller's argument construction and the scanner's successful sandbox entry. The permissive-profile control demonstrates this consequence: the exempt bootstrap launches a leaf that can send harmless one-byte IPv4/IPv6 loopback datagrams. The parent remains denied.

## Restrictions and evidence limits

The cited examples attach `no-sandbox` to `allow process-exec`; other shipped profiles use `allow process-exec*`. The inspected Apple manuals and SDK header do not specify the modifier's complete validation rules, signature requirements, or interaction with every other sandbox mechanism. Some Apple examples add an `apple-internal` filter, such as `/System/Library/Sandbox/Profiles/com.apple.tccd.sb`, lines 67-70. The `pppd` and `system_profiler` examples above have no such filter on their execution rules. Neither observation establishes the full runtime permission requirements for a user-supplied profile.

Apple labels these shipped profile rules a System Private Interface that may change without notice. See `/System/Library/Sandbox/Profiles/com.apple.SubmitDiagInfo.sb`, lines 3-5. The utility is also deprecated in its `/usr/share/man/man1/sandbox-exec.1`, lines 18-23. Do not extend this finding to a guarantee that the modifier removes App Sandbox entitlements or every inherited security policy. Apple's public [App Sandbox inheritance documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) describes a separate entitlement-based contract for signed child targets.

The report's pass scope is feasibility of a cooperative test-only parent/scanner policy transition. It does not establish a secure production parent policy, all-descendant network denial, or a GUI workflow. The production-profile leaf probe tests the policy applied to the scanner; the scanner executable itself is exercised with the fixed production argument construction, without injecting a probe into it.


## Exact local IPC exception

The bare parent `deny network*` also rejects AF_UNIX bind with EPERM. Local capture needs its own socket. Apple ships Unix-path literal network permissions, for example `/System/Library/Sandbox/Profiles/com.apple.ScopedBookmarkAgent.sb` and `/System/Library/Sandbox/Profiles/lockdownmoded.sb`. The tested parent adds an exact path permission:

```scheme
(allow network* (literal "<resolved owned store-directory>/capture.sock"))
```

The recorded fixtures verify bind, listen, connect, send and receive on that one endpoint. A permission for the canonical `/private/tmp` endpoint also permits the same exchange through its `/tmp` alias. A sibling socket through either spelling remained denied, as did IPv4 and IPv6 loopback datagrams. This alias check added measurements without replacing the earlier controls. Quoted and backslash-containing path components were tested. The exploratory factory rejected relative paths, symlink endpoints, control characters, overly long Unix paths, and nonprivate or foreign-owned parent directories. It resolved the path before producing its quoted SBPL literal.

This is a test-only profile. The socket permission permits local IPC. The system bootstrap exception permits a brief unsandboxed bootstrap and remains a generic escape because it does not bind arguments. Fixed trusted arguments and synthetic content define the cooperative app test. Its results cannot claim denial for every descendant or every system-mediated networking path.

## Current signed acceptance

The separate exploratory probe and profile-factory script have been removed. The
[historical report](m6-parent-sandbox-bootstrap.json) retains its original 16
positive and negative feasibility checks and their scope. Its sanitized temporary-path placeholders identify removed fixtures; see the
[evidence notes](README.md).

The signed owner constructs the cooperative profile directly in
[VaultOwner.swift](../../Tests/ProtectionSignedProbe/VaultOwner.swift) for its
owned private store. Follow the [signed-owner instructions](../../Tests/ProtectionSignedProbe/VaultOwner.md)
to repeat the app's restart/offline acceptance sequence with fresh paths. The
bootstrap exception and the limits described above still apply.
