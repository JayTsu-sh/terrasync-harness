"""Push local SSH public key to remote hosts' authorized_keys via password auth.

One-shot bootstrap utility: given hosts and a password, copies your local public
key to each remote ~/.ssh/authorized_keys so subsequent SSH can use key-based
auth. Idempotent: re-running on a host that already has the key is a no-op.

Usage:
    push_pubkey.py [-h] [-u USER] [-i IDENTITY] [--password-env VAR]
                   [--timeout SECS] HOST [HOST ...]

Examples:
    # Interactive password prompt (recommended for one-off use)
    python scripts/push_pubkey.py 192.168.1.10 192.168.1.11

    # Password from environment variable (useful in scripts)
    SSH_BOOTSTRAP_PASSWORD=secret python scripts/push_pubkey.py \\
        --password-env SSH_BOOTSTRAP_PASSWORD 192.168.1.10

    # Custom user and key
    python scripts/push_pubkey.py -u admin -i ~/.ssh/id_ed25519.pub host1 host2

Requirements: paramiko (pip install paramiko)

Exits 0 if every host succeeded, 1 if any failed, 2 on usage errors.
"""

from __future__ import annotations

import argparse
import getpass
import os
import sys
from pathlib import Path

import paramiko


def push(host: str, user: str, password: str, pubkey_line: str, timeout: float) -> bool:
    print(f"[{host}] connecting as {user}...", flush=True)
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(
            host,
            username=user,
            password=password,
            timeout=timeout,
            allow_agent=False,
            look_for_keys=False,
        )
        cmd = (
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
            f"grep -qxF {pubkey_line!r} ~/.ssh/authorized_keys || "
            f"echo {pubkey_line!r} >> ~/.ssh/authorized_keys"
        )
        _stdin, stdout, stderr = cli.exec_command(cmd)
        rc = stdout.channel.recv_exit_status()
        if rc != 0:
            err = stderr.read().decode(errors="replace").strip()
            print(f"[{host}] FAILED rc={rc} err={err}", flush=True)
            return False
        print(f"[{host}] OK", flush=True)
        return True
    except Exception as e:  # noqa: BLE001 - paramiko throws a variety of types
        print(f"[{host}] FAILED: {e}", flush=True)
        return False
    finally:
        cli.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Push local SSH public key to remote hosts' authorized_keys.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("hosts", nargs="+", metavar="HOST", help="Remote host(s)")
    p.add_argument(
        "-u", "--user", default="root", help="SSH user (default: root)",
    )
    p.add_argument(
        "-i", "--identity",
        default=str(Path.home() / ".ssh" / "id_rsa.pub"),
        help="Path to local public key (default: ~/.ssh/id_rsa.pub)",
    )
    p.add_argument(
        "--password-env", metavar="VAR",
        help="Read password from this env var instead of prompting interactively",
    )
    p.add_argument(
        "--timeout", type=float, default=10.0,
        help="SSH connect timeout in seconds (default: 10)",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    pubkey_path = Path(args.identity).expanduser()
    if not pubkey_path.is_file():
        print(f"public key not found: {pubkey_path}", file=sys.stderr)
        return 2
    pubkey_line = pubkey_path.read_text().strip()
    if not pubkey_line:
        print(f"public key is empty: {pubkey_path}", file=sys.stderr)
        return 2

    if args.password_env:
        password = os.environ.get(args.password_env, "")
        if not password:
            print(f"env var {args.password_env} is empty or unset", file=sys.stderr)
            return 2
    else:
        password = getpass.getpass(f"SSH password for {args.user}@<each host>: ")

    failures = 0
    for h in args.hosts:
        if not push(h, args.user, password, pubkey_line, args.timeout):
            failures += 1
    total = len(args.hosts)
    print(f"done. {total - failures}/{total} succeeded.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
