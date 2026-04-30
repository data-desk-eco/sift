"""Encrypted-sparseimage vault. AES-256 sparseimage created and mounted
via hdiutil; passphrase generated at init and stored mode-0600 outside
the project dir; Touch ID gates unlock. Mirrors AilephCore/VaultService.
swift."""

from __future__ import annotations

import base64
import hashlib
import json
import plistlib
import secrets as _secrets
import subprocess
import sys
from pathlib import Path

from .errors import CommandError


class Vault:
    SPARSEIMAGE_NAME = ".vault.sparseimage"
    DEFAULT_SIZE = "20g"

    def __init__(self, project_dir: Path, share_dir: Path) -> None:
        # Project dir = where .vault.sparseimage lives (project-specific data).
        self.project_dir = project_dir
        self.sparseimage = project_dir / self.SPARSEIMAGE_NAME
        # Share dir = where touchid.swift ships. Stable across projects;
        # the same package serves any number of vaults.
        self.touchid_src = share_dir / "touchid.swift"
        self.touchid_bin = share_dir / "touchid"
        # Project hash disambiguates multiple vaults on /Volumes and lets the
        # passphrase file live outside the project dir (where it'd be a real
        # security regression to colocate with the sparseimage).
        self._hash = hashlib.sha256(
            str(project_dir).encode("utf-8")
        ).hexdigest()[:8]
        self.passphrase_file = Path.home() / ".aleph" / f"{self._hash}.passphrase"
        self.volume_name = f"vault-{self._hash}"
        self.default_mountpoint = Path("/Volumes") / self.volume_name

    # ----- mount detection ----------------------------------------------

    def find_mount(self) -> Path | None:
        if not self.sparseimage.exists():
            return None
        try:
            out = subprocess.run(
                ["/usr/bin/hdiutil", "info", "-plist"],
                capture_output=True, check=True,
            )
            plist = plistlib.loads(out.stdout)
        except (subprocess.CalledProcessError, plistlib.InvalidFileException):
            return None
        target = self.sparseimage.resolve()
        for image in plist.get("images", []):
            try:
                if Path(image.get("image-path", "")).resolve() != target:
                    continue
            except OSError:
                continue
            for ent in image.get("system-entities", []):
                mp = ent.get("mount-point")
                if mp:
                    return Path(mp)
        return None

    # ----- passphrase ---------------------------------------------------

    @staticmethod
    def _random_passphrase() -> str:
        return _secrets.token_hex(32)

    def _save_passphrase(self, passphrase: str) -> None:
        d = self.passphrase_file.parent
        d.mkdir(parents=True, exist_ok=True)
        d.chmod(0o700)
        # Base64-obfuscated. Same threat model as Aileph: the file mode is
        # the real protection; obfuscation just blocks shoulder-surfing.
        self.passphrase_file.write_bytes(
            base64.b64encode(passphrase.encode("utf-8"))
        )
        self.passphrase_file.chmod(0o600)

    def _load_passphrase(self) -> str:
        if not self.passphrase_file.exists():
            raise CommandError(
                f"vault passphrase not found at {self.passphrase_file}",
                "run 'sift vault init' first",
            )
        raw = self.passphrase_file.read_bytes().strip()
        return base64.b64decode(raw).decode("utf-8")

    # ----- touchid helper ----------------------------------------------

    def _ensure_touchid_built(self) -> None:
        if not self.touchid_src.exists():
            raise CommandError(
                f"missing touchid source at {self.touchid_src}",
                "expected at <package>/share/touchid.swift",
            )
        needs_build = (
            not self.touchid_bin.exists()
            or self.touchid_src.stat().st_mtime > self.touchid_bin.stat().st_mtime
        )
        if needs_build:
            print("sift: compiling touchid helper...", file=sys.stderr)
            if subprocess.run(["which", "swiftc"], capture_output=True).returncode != 0:
                raise CommandError(
                    "swiftc not found",
                    "install Xcode Command Line Tools: xcode-select --install",
                )
            subprocess.run(
                ["swiftc", "-O", "-o", str(self.touchid_bin), str(self.touchid_src)],
                check=True,
            )

    def _confirm_touchid(self, reason: str = "Unlock the vault") -> None:
        self._ensure_touchid_built()
        result = subprocess.run([str(self.touchid_bin), reason])
        if result.returncode != 0:
            raise CommandError("Touch ID cancelled or failed")

    # ----- lifecycle ---------------------------------------------------

    def init(self, size: str = DEFAULT_SIZE) -> Path:
        if self.sparseimage.exists():
            raise CommandError(
                f"vault already exists at {self.sparseimage}",
                "use 'sift vault unlock' to mount",
            )
        passphrase = self._random_passphrase()
        self._save_passphrase(passphrase)

        print(f"sift: creating {size} encrypted sparseimage at {self.sparseimage}...",
              file=sys.stderr)
        # hdiutil appends ".sparseimage" itself; pass the stem.
        subprocess.run(
            ["/usr/bin/hdiutil", "create",
             "-size", size, "-encryption", "AES-256",
             "-type", "SPARSE", "-fs", "APFS",
             "-volname", self.volume_name,
             "-stdinpass", str(self.sparseimage.with_suffix(""))],
            input=passphrase.encode("utf-8"),
            capture_output=True, check=True,
        )

        print(f"sift: mounting at {self.default_mountpoint}...", file=sys.stderr)
        subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-stdinpass",
             "-mountpoint", str(self.default_mountpoint), str(self.sparseimage)],
            input=passphrase.encode("utf-8"),
            capture_output=True, check=True,
        )

        (self.default_mountpoint / "research").mkdir(exist_ok=True)
        secrets_path = self.default_mountpoint / "secrets.json"
        secrets_path.write_text("{}")
        secrets_path.chmod(0o600)
        return self.default_mountpoint

    def unlock(self) -> Path:
        existing = self.find_mount()
        if existing:
            return existing
        if not self.sparseimage.exists():
            raise CommandError(
                "vault not initialised",
                "run 'sift vault init' first",
            )
        self._confirm_touchid()
        passphrase = self._load_passphrase()
        subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-stdinpass",
             "-mountpoint", str(self.default_mountpoint), str(self.sparseimage)],
            input=passphrase.encode("utf-8"),
            capture_output=True, check=True,
        )
        return self.default_mountpoint

    def lock(self) -> bool:
        mp = self.find_mount()
        if not mp:
            return False
        subprocess.run(
            ["/usr/bin/hdiutil", "detach", str(mp)],
            capture_output=True, check=True,
        )
        return True

    # ----- secrets.json --------------------------------------------------

    def secrets_path(self, mp: Path) -> Path:
        return mp / "secrets.json"

    def read_secrets(self, mp: Path | None = None) -> dict:
        mp = mp or self.find_mount()
        if not mp:
            return {}
        path = self.secrets_path(mp)
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            return {}

    def write_secret(self, mp: Path, key: str, value: str) -> None:
        path = self.secrets_path(mp)
        data = self.read_secrets(mp)
        data[key] = value
        path.write_text(json.dumps(data, indent=2, sort_keys=True))
        path.chmod(0o600)

    def list_secrets(self, mp: Path) -> list[str]:
        return sorted(self.read_secrets(mp).keys())

    # ----- env injection ------------------------------------------------

    def env_dict(self, mp: Path) -> dict[str, str]:
        secrets = self.read_secrets(mp)
        env = {
            "VAULT_MOUNT": str(mp),
            "ALEPH_SESSION_DIR": str(mp / "research"),
        }
        if "ALEPH_URL" in secrets:
            env["ALEPH_URL"] = secrets["ALEPH_URL"]
        if "ALEPH_API_KEY" in secrets:
            env["ALEPH_API_KEY"] = secrets["ALEPH_API_KEY"]
        return env
