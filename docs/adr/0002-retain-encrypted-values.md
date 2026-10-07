# Retain an encrypted copy of detected values

The user wants to reveal the exact secret in the inventory, even after its source conversation has been deleted. The application will therefore retain a local encrypted copy of that value, masked by default and revealed on request after macOS authentication, along with an encrypted context excerpt and the available conversation references. Secrets remain stored until the user explicitly deletes them. This retention responsibility is independent of the seven-day window chosen for source analysis.
