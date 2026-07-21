#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import quote


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg"}
DISPLAY_WIDTH = 700
MAX_SLICE_HEIGHT = 900


@dataclass(frozen=True)
class Slice:
    path: Path
    width: int
    height: int
    url: str


def run(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{' '.join(command)} failed: {details}")
    return result.stdout.strip()


def git_output(args: list[str], repository_root: Path) -> str:
    return run(["git", *args], cwd=repository_root)


def get_repository_slug(remote_url: str) -> str:
    remote_url = remote_url.strip()
    patterns = [
        r"^https://github\.com/(?P<slug>[^/]+/[^/]+?)(?:\.git)?/?$",
        r"^git@github\.com:(?P<slug>[^/]+/[^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/(?P<slug>[^/]+/[^/]+?)(?:\.git)?/?$",
    ]
    for pattern in patterns:
        match = re.match(pattern, remote_url)
        if match:
            return match.group("slug")
    raise ValueError(f"Unsupported GitHub origin URL: {remote_url}")


def get_target_branch(repository_root: Path, explicit_branch: str | None) -> str:
    if explicit_branch:
        return explicit_branch

    for env_name in ("TARGET_BRANCH", "GITHUB_REF_NAME"):
        value = os.environ.get(env_name)
        if value:
            return value

    branch = git_output(["branch", "--show-current"], repository_root)
    if branch:
        return branch

    return git_output(["rev-parse", "--abbrev-ref", "HEAD"], repository_root)


def encode_url_path(value: str) -> str:
    return "/".join(quote(segment, safe="") for segment in value.replace("\\", "/").split("/"))


def raw_github_url(repository: str, branch: str, repo_relative_path: str) -> str:
    encoded_branch = encode_url_path(branch)
    encoded_path = encode_url_path(repo_relative_path)
    return f"https://raw.githubusercontent.com/{repository}/{encoded_branch}/{encoded_path}"


def load_processed(path: Path) -> dict:
    if not path.exists():
        return {"images": {}}

    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"Expected object in {path}")
    images = data.setdefault("images", {})
    if not isinstance(images, dict):
        raise ValueError(f"Expected images object in {path}")
    return data


def save_processed(path: Path, data: dict) -> None:
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def source_images(repository_root: Path, processed: dict, force: bool) -> list[Path]:
    processed_names = set(processed.get("images", {}).keys())
    images = []
    for path in sorted(repository_root.iterdir(), key=lambda item: item.name.lower()):
        if not path.is_file():
            continue
        if path.name.startswith("."):
            continue
        if path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        if not force and path.name in processed_names:
            continue
        images.append(path)
    return images


def safe_stem(path: Path) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", path.stem).strip("._")
    return value or "edm"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_relative(repository_root: Path, path: Path) -> str:
    return path.relative_to(repository_root).as_posix()


def slice_image(
    source: Path,
    output_dir: Path,
    repository_root: Path,
    repository: str,
    branch: str,
    swift: str,
) -> list[Slice]:
    images_dir = output_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    slicer = repository_root / "scripts" / "slice-image.swift"
    output = run(
        [
            swift,
            str(slicer),
            str(source),
            str(images_dir),
            str(DISPLAY_WIDTH),
            str(MAX_SLICE_HEIGHT),
        ]
    )
    manifest = json.loads(output)

    slices: list[Slice] = []
    for item in manifest["slices"]:
        slice_path = images_dir / item["file"]
        relative_path = repo_relative(repository_root, slice_path)
        slices.append(
            Slice(
                path=slice_path,
                width=item["width"],
                height=item["height"],
                url=raw_github_url(repository, branch, relative_path),
            )
        )

    return slices


def build_html_document(title: str, slices: list[Slice]) -> str:
    rows = []
    for item in slices:
        rows.append(
            "            <tr>\n"
            "              <td style=\"padding:0; margin:0; font-size:0; line-height:0;\">\n"
            f"                <img class=\"edm-image\" src=\"{html.escape(item.url, quote=True)}\" "
            f"width=\"{item.width}\" height=\"{item.height}\" alt=\"\" "
            f"style=\"display:block; width:{item.width}px; height:{item.height}px; "
            "border:0; outline:none; text-decoration:none; line-height:0;\">\n"
            "              </td>\n"
            "            </tr>"
        )

    escaped_title = html.escape(title)
    body = "\n".join(rows)
    return f"""<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="x-apple-disable-message-reformatting">
    <title>{escaped_title}</title>
    <style>
      body {{ margin:0; padding:0; background:#f4f4f4; }}
      table {{ border-collapse:collapse; border-spacing:0; }}
      img {{ -ms-interpolation-mode:bicubic; }}
      @media screen and (max-width: 720px) {{
        .edm-wrapper {{ width:100% !important; }}
        .edm-image {{ width:100% !important; height:auto !important; }}
      }}
    </style>
  </head>
  <body style="margin:0; padding:0; background:#f4f4f4;">
    <center style="width:100%; background:#f4f4f4;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
        <tr>
          <td align="center" style="padding:0; margin:0;">
            <table role="presentation" class="edm-wrapper" width="{DISPLAY_WIDTH}" cellpadding="0" cellspacing="0" border="0" style="width:{DISPLAY_WIDTH}px; margin:0 auto;">
{body}
            </table>
          </td>
        </tr>
      </table>
    </center>
  </body>
</html>
"""


def write_eml(path: Path, title: str, html_body: str) -> None:
    message = EmailMessage(policy=SMTP)
    message["Subject"] = title
    message["From"] = "eDM <no-reply@example.com>"
    message["Date"] = format_datetime(dt.datetime.now(dt.timezone.utc))
    message["X-Unsent"] = "1"
    message.set_content(f"{title}\n")
    message.add_alternative(html_body, subtype="html")
    path.write_bytes(bytes(message))


def process_image(
    source: Path,
    repository_root: Path,
    repository: str,
    branch: str,
    processed: dict,
    swift: str,
) -> dict:
    stem = safe_stem(source)
    output_dir = repository_root / stem
    output_dir.mkdir(parents=True, exist_ok=True)

    slices = slice_image(source, output_dir, repository_root, repository, branch, swift)
    title = stem
    html_body = build_html_document(title, slices)
    html_path = output_dir / f"{stem}.html"
    eml_path = output_dir / f"{stem}.eml"
    html_path.write_text(html_body, encoding="utf-8")
    write_eml(eml_path, title, html_body)

    record = {
        "source": repo_relative(repository_root, source),
        "source_sha256": sha256_file(source),
        "output_dir": repo_relative(repository_root, output_dir),
        "html": repo_relative(repository_root, html_path),
        "eml": repo_relative(repository_root, eml_path),
        "display_width": DISPLAY_WIDTH,
        "max_slice_height": MAX_SLICE_HEIGHT,
        "repository": repository,
        "branch": branch,
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "slices": [
            {
                "file": repo_relative(repository_root, item.path),
                "width": item.width,
                "height": item.height,
                "url": item.url,
            }
            for item in slices
        ],
    }
    processed["images"][source.name] = record
    return record


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate eDM slices, HTML, and EML from unprocessed root images.")
    parser.add_argument("--repository-root", default=".", help="Repository root. Defaults to the current directory.")
    parser.add_argument("--branch", help="Target branch for raw GitHub image URLs.")
    parser.add_argument("--force", action="store_true", help="Regenerate source images even if processed.json already contains them.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repository_root = Path(args.repository_root).resolve()
    processed_path = repository_root / "processed.json"
    swift = shutil.which("swift")
    if not swift:
        raise RuntimeError("swift is required on this machine to slice images.")
    os.environ.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/edm-swift-module-cache")

    remote_url = git_output(["remote", "get-url", "origin"], repository_root)
    repository = get_repository_slug(remote_url)
    branch = get_target_branch(repository_root, args.branch)
    processed = load_processed(processed_path)
    targets = source_images(repository_root, processed, args.force)

    if not targets:
        print("No unprocessed source images found.")
        return 0

    for source in targets:
        record = process_image(source, repository_root, repository, branch, processed, swift)
        print(f"Generated {record['html']} and {record['eml']}")

    save_processed(processed_path, processed)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
