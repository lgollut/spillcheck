# Production scanner fixtures

Run from the repository root:

```sh
python3 scripts/prepare-scanner.py
swift test --filter DetectorTests
```

The preparation script verifies and copies the already downloaded Betterleaks 1.9.0 executable, configuration and MIT license into `.build/scanner`. It uses no network and does not select a moving release. Missing or mismatched cached artifacts fail explicitly. The app must bundle the selected executable, configuration and license. Signing the nested executable changes its bytes; the app-controlled bundle configuration must record that signed hash after verifying the pinned original before signing.

`corpus.json` contains the 47 synthetic annotated events measured in the scanner feasibility experiment, with 36 expected confidential-value ranges. Repeated chunks compact the fixture to approximately 24 KiB while reconstructing the same 11,940,008 UTF-8 input bytes. Expected ranges are half-open UTF-8 offsets. Percent-encoded URI passwords additionally declare the exact decoded value. These fixtures do not establish provider credential validity or real-world precision.

The recorded production run passed all 19 detector tests. The annotated-corpus test recovered every expected exact range/value, with no additional or unlocated corpus findings, in 11.035 seconds for the complete sequential 47-event workload in the validation environment. That elapsed time includes the production pipe/process path and debug Swift mapping/native rules. It is not end-to-end monitoring latency.

Production calls use Betterleaks stdin with explicit configuration/ignore paths, disabled validation/decoding/archive traversal, low-confidence retention, a sanitized environment and anonymous pipes. The sandbox denies networking and process forking. Independent test processes verified that outbound connection, listening and fork operations receive denial. The actual Go scanner succeeds under the same profile.

Limits are 8 MiB of aggregate canonical input, 8 MiB of report output, 64 KiB of discarded diagnostics, 4,096 findings, and a 30-second invocation budget. Tests exercise hanging input, output/diagnostic limits and cancellation. Scanner failure returns the three measured native rules with explicit reduced coverage; it cannot silently claim complete service-format detection. Unknown/malformed or ambiguous source mappings retain controlled unlocated evidence without a revealable value.

The mapping tests cover exact full-context recovery, benign duplicate words, equal URI username/password bytes, keyword/value equality, strict scoped percent decoding, literal plus signs, invalid UTF-8, merged same-range evidence, multiline matching PEM headers/footers, public AWS identifier exclusion and the measured confidential AWS component. Missing confidential AWS components produce an unlocated report mismatch and a coverage gap. An actual production scanner regression confirms that a mismatched PEM footer remains ambiguous with unsupported-content coverage rather than strong complete-block evidence. Low/medium/missing/custom confidence remains ambiguous. Scanner confidence does not change user review or prove credential usability.

The runtime creates no input or report files. Its private working directory contains an explicit empty ignore file and the scanner's compiled rule cache. The corpus test places malformed auto-discovery configurations there to verify that explicit configuration wins and checks cache files for the synthetic token marker. Signed application bundling and the deferred minimum-OS runtime checks are separate gates.
