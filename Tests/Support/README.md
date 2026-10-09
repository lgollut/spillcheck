Shared Python helpers for the app's acceptance tests live here. `processes.py` stops disposable process groups with a bounded grace period, then kills any surviving descendants and reaps the group leader. `Tests/ClaudeLive/run.py` uses it to clean up its provider and acceptance-driver processes.

`acceptance_artifacts.py` retains each failed run's disposable vault and manifest for diagnosis. It removes the owned directory only after the app confirms vault cleanup and the test passes. Signed-app acceptance and resource measurements share this helper.
