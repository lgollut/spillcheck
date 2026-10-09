# Core fixtures

These values are synthetic and cannot authenticate. The extraction fixtures represent canonical,
transport-decoded UTF-8 text. Tests locate each exact byte range and verify extraction against that
text; raw JSON byte offsets are deliberately not treated as message offsets.

The core contract tests supply different opaque 32-byte fingerprints as stand-ins for a caller's
dedicated keyed digest. They do not implement or validate cryptography, installed agent adapters,
database durability, OS notification delivery, or authenticated revelation.
