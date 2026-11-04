#!/usr/bin/env python3
"""Generate the Feedback Desk keypair (issue #16).

The PUBLIC key is baked into the Feedback app build (the seal target).
The PRIVATE key is a Desk host secret: written to feedback_desk/secret.key (gitignored),
never committed. Rotation: re-run, ship a Feedback app update with the new public key.
"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "feedback_desk"))
import feedback_common as fc  # noqa: E402

pub, priv = fc.gen_keypair()
secret_path = os.path.join(os.path.dirname(__file__), "..", "feedback_desk", "secret.key")
if os.path.exists(secret_path):
    sys.exit(f"refusing to overwrite existing {secret_path} (rotate deliberately)")
with open(secret_path, "w") as f:
    f.write(priv + "\n")
os.chmod(secret_path, 0o600)

print("Feedback Desk keypair generated.")
print(f"  public key  (bake into the Feedback app): {pub}")
print(f"  private key written to: {secret_path} (chmod 600, gitignored)")
print("Next: set this public key as the seal target in the Feedback app build (#7).")
