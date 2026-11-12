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
import tempfile
from dataclasses import dataclass
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import quote


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg"}
DISPLAY_WIDTH = 700
MAX_SLICE_HEIGHT = 900
CONFIG_NAME = "edm.config.json"


@dataclass(frozen=True)
class Link:
    url: str
    alt: str
    x: int
    y: int
    width: int
    height: int


@dataclass(frozen=True)
class Cell:
    path: Path
    width: int
    height: int
    url: str
    link: Link | None = None


@dataclass(frozen=True)
class Layout:
    rows: list[list[Cell]]
    background: str

    @property
    def cells(self) -> list[Cell]:
        return [cell for row in self.rows for cell in row]


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


def load_config(path: Path) -> dict:
    """Optional per-image settings: title, lang and clickable link regions."""
    if not path.exists():
        return {}

    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"Expected object in {path}")
    return data


def parse_links(source_name: str, settings: dict) -> list[Link]:
    links = []
    for index, item in enumerate(settings.get("links", []), start=1):
        try:
            url = str(item["url"]).strip()
            link = Link(
                url=url,
                alt=str(item.get("alt", "")),
                x=int(item["x"]),
                y=int(item["y"]),
                width=int(item["width"]),
                height=int(item["height"]),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(
                f"{CONFIG_NAME}: link {index} of {source_name} needs url, x, y, width and height ({error})"
            ) from error
        if not re.match(r"^(https?://|mailto:)", url):
            raise ValueError(f"{CONFIG_NAME}: link {index} of {source_name} must start with https://, http:// or mailto:")
        links.append(link)
    return links


def source_images(repository_root: Path, processed: dict, force: bool, only: list[str]) -> list[Path]:
    processed_names = set(processed.get("images", {}).keys())
    wanted = {Path(name).name for name in only}
    images = []
    for path in sorted(repository_root.iterdir(), key=lambda item: item.name.lower()):
        if not path.is_file():
            continue
        if path.name.startswith("."):
            continue
        if path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        if wanted and path.name not in wanted:
            continue
        if not force and path.name in processed_names:
            continue
        images.append(path)

    missing = wanted - {path.name for path in images} - (set() if force else processed_names)
    if missing:
        raise ValueError(f"Source image not found in the repository root: {', '.join(sorted(missing))}")
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
    links: list[Link],
    image_format: str,
) -> Layout:
    images_dir = output_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    for stale in images_dir.glob("slice_*"):
        if stale.suffix.lower() in IMAGE_EXTENSIONS:
            stale.unlink()

    slicer = repository_root / "scripts" / "slice-image.swift"
    regions = [{"x": link.x, "y": link.y, "width": link.width, "height": link.height} for link in links]
    with tempfile.TemporaryDirectory() as temp_dir:
        regions_path = Path(temp_dir) / "regions.json"
        regions_path.write_text(json.dumps(regions), encoding="utf-8")
        output = run(
            [
                swift,
                str(slicer),
                str(source),
                str(images_dir),
                str(DISPLAY_WIDTH),
                str(MAX_SLICE_HEIGHT),
                str(regions_path),
                image_format,
            ]
        )
    manifest = json.loads(output)

    rows: list[list[Cell]] = []
    for row in manifest["rows"]:
        cells = []
        for item in row["cells"]:
            cell_path = images_dir / item["file"]
            relative_path = repo_relative(repository_root, cell_path)
            region = item.get("region")
            cells.append(
                Cell(
                    path=cell_path,
                    width=item["width"],
                    height=item["height"],
                    url=raw_github_url(repository, branch, relative_path),
                    link=links[region] if region is not None else None,
                )
            )
        rows.append(cells)

    return Layout(rows=rows, background=manifest["background"])


def image_tag(cell: Cell, src: str, alt: str) -> str:
    return (
        f"<img class=\"edm-image\" src=\"{html.escape(src, quote=True)}\" "
        f"width=\"{cell.width}\" height=\"{cell.height}\" border=\"0\" alt=\"{html.escape(alt, quote=True)}\" "
        f"style=\"display:block; width:{cell.width}px; height:{cell.height}px; "
        "border:0; outline:none; text-decoration:none; line-height:0;\">"
    )


def build_html_document(title: str, lang: str, layout: Layout, output_dir: Path, local: bool = False) -> str:
    """Build the email HTML. local=True uses relative image paths for previewing before a push."""
    cell_style = "padding:0; margin:0; font-size:0; line-height:0;"
    background = html.escape(layout.background, quote=True)
    rows = []
    mobile_rules = []
    first_image = True

    def source_of(cell: Cell) -> str:
        return cell.path.relative_to(output_dir).as_posix() if local else cell.url

    def cell_markup(cell: Cell) -> str:
        nonlocal first_image
        if cell.link:
            tag = image_tag(cell, source_of(cell), cell.link.alt)
            markup = (
                f"<a href=\"{html.escape(cell.link.url, quote=True)}\" target=\"_blank\" "
                f"style=\"display:block; margin:0; padding:0; border:0; line-height:0; font-size:0; text-decoration:none;\">"
                f"{tag}</a>"
            )
        else:
            markup = image_tag(cell, source_of(cell), title if first_image else "")
        first_image = False
        return markup

    for row_index, row in enumerate(layout.rows, start=1):
        if len(row) == 1:
            rows.append(
                "            <tr>\n"
                f"              <td style=\"{cell_style}\">\n"
                f"                {cell_markup(row[0])}\n"
                "              </td>\n"
                "            </tr>"
            )
            continue

        # A row that contains a link: side images stay unlinked, only the link cell is clickable.
        cells = []
        for cell_index, cell in enumerate(row, start=1):
            class_name = f"edm-r{row_index}c{cell_index}"
            percent = cell.width * 100 / DISPLAY_WIDTH
            mobile_rules.append(f"        .{class_name} {{ width:{percent:.4f}% !important; }}")
            cells.append(
                f"                    <td class=\"{class_name}\" width=\"{cell.width}\" valign=\"top\" "
                f"style=\"width:{cell.width}px; {cell_style}\">\n"
                f"                      {cell_markup(cell)}\n"
                "                    </td>"
            )
        rows.append(
            "            <tr>\n"
            f"              <td bgcolor=\"{background}\" style=\"{cell_style} background:{background};\">\n"
            f"                <table role=\"presentation\" class=\"edm-wrapper\" width=\"{DISPLAY_WIDTH}\" cellpadding=\"0\" "
            f"cellspacing=\"0\" border=\"0\" style=\"width:{DISPLAY_WIDTH}px; border-collapse:collapse; "
            "mso-table-lspace:0pt; mso-table-rspace:0pt;\">\n"
            "                  <tr>\n"
            + "\n".join(cells)
            + "\n"
            "                  </tr>\n"
            "                </table>\n"
            "              </td>\n"
            "            </tr>"
        )

    escaped_title = html.escape(title)
    escaped_lang = html.escape(lang, quote=True)
    body = "\n".join(rows)
    mobile_css = ("\n" + "\n".join(mobile_rules)) if mobile_rules else ""
    return f"""<!doctype html>
<html lang="{escaped_lang}">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="x-apple-disable-message-reformatting">
    <meta name="format-detection" content="telephone=no,date=no,address=no,email=no,url=no">
    <title>{escaped_title}</title>
    <style>
      body {{ margin:0; padding:0; background:#f4f4f4; }}
      table {{ border-collapse:collapse; border-spacing:0; }}
      img {{ -ms-interpolation-mode:bicubic; }}
      @media screen and (max-width: 720px) {{
        .edm-wrapper {{ width:100% !important; }}
        .edm-image {{ width:100% !important; height:auto !important; }}{mobile_css}
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


def write_eml(path: Path, title: str, html_body: str, links: list[Link]) -> None:
    message = EmailMessage(policy=SMTP)
    message["Subject"] = title
    message["From"] = "eDM <no-reply@example.com>"
    message["Date"] = format_datetime(dt.datetime.now(dt.timezone.utc))
    message["X-Unsent"] = "1"
    text_lines = [title, ""]
    text_lines += [f"{link.alt}: {link.url}" if link.alt else link.url for link in links]
    message.set_content("\n".join(text_lines).rstrip() + "\n")
    message.add_alternative(html_body, subtype="html")
    path.write_bytes(bytes(message))


def process_image(
    source: Path,
    repository_root: Path,
    repository: str,
    branch: str,
    processed: dict,
    swift: str,
    settings: dict,
    image_format: str,
) -> dict:
    stem = safe_stem(source)
    output_dir = repository_root / stem
    output_dir.mkdir(parents=True, exist_ok=True)

    links = parse_links(source.name, settings)
    if image_format == "auto":
        image_format = "jpg" if source.suffix.lower() in {".jpg", ".jpeg"} else "png"

    layout = slice_image(source, output_dir, repository_root, repository, branch, swift, links, image_format)
    title = str(settings.get("title") or stem)
    lang = str(settings.get("lang") or "ko")
    html_body = build_html_document(title, lang, layout, output_dir)
    html_path = output_dir / f"{stem}.html"
    local_html_path = output_dir / f"{stem}_local.html"
    eml_path = output_dir / f"{stem}.eml"
    html_path.write_text(html_body, encoding="utf-8")
    local_html_path.write_text(build_html_document(title, lang, layout, output_dir, local=True), encoding="utf-8")
    write_eml(eml_path, title, html_body, links)

    record = {
        "source": repo_relative(repository_root, source),
        "source_sha256": sha256_file(source),
        "output_dir": repo_relative(repository_root, output_dir),
        "html": repo_relative(repository_root, html_path),
        "local_preview": repo_relative(repository_root, local_html_path),
        "eml": repo_relative(repository_root, eml_path),
        "title": title,
        "display_width": DISPLAY_WIDTH,
        "max_slice_height": MAX_SLICE_HEIGHT,
        "repository": repository,
        "branch": branch,
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "slices": [
            {
                "file": repo_relative(repository_root, cell.path),
                "width": cell.width,
                "height": cell.height,
                "url": cell.url,
                **({"link": cell.link.url} if cell.link else {}),
            }
            for cell in layout.cells
        ],
    }
    processed["images"][source.name] = record
    return record


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate eDM slices, HTML, and EML from unprocessed root images.")
    parser.add_argument("--repository-root", default=".", help="Repository root. Defaults to the current directory.")
    parser.add_argument("--branch", help="Target branch for raw GitHub image URLs.")
    parser.add_argument("--force", action="store_true", help="Regenerate source images even if processed.json already contains them.")
    parser.add_argument(
        "--format",
        choices=("auto", "png", "jpg"),
        default="auto",
        help="Slice image format. auto keeps the source format (jpg source -> jpg slices).",
    )
    parser.add_argument("images", nargs="*", help="Only process these root image file names.")
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
    config = load_config(repository_root / CONFIG_NAME)
    targets = source_images(repository_root, processed, args.force, args.images)

    if not targets:
        print("No unprocessed source images found.")
        return 0

    # Two different file names can collapse to the same folder once non-ASCII characters are removed.
    stems: dict[str, str] = {}
    for name in [*processed["images"].keys(), *(source.name for source in targets)]:
        stem = safe_stem(Path(name))
        if stems.setdefault(stem, name) != name:
            raise ValueError(
                f"{stems[stem]} and {name} would both be written to the folder '{stem}'. "
                "Rename one of them using English letters, numbers, '-' or '_'."
            )

    for source in targets:
        settings = config.get(source.name, {})
        if not isinstance(settings, dict):
            raise ValueError(f"{CONFIG_NAME}: settings for {source.name} must be an object")
        record = process_image(source, repository_root, repository, branch, processed, swift, settings, args.format)
        print(f"Generated {record['html']} and {record['eml']}")

    save_processed(processed_path, processed)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
