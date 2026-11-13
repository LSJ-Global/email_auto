#!/usr/bin/env python3
"""Run the repository's fixed eDM prompt with the locally authenticated Codex CLI."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple
from urllib.parse import urlparse


SUPPORTED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
INVALID_FOLDER_CHARS = re.compile(r"[\x00-\x1f/:\\]")
RESERVED_FOLDERS = {".git", ".github", "scripts", "tools"}


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def normalize_url(value: str) -> Optional[str]:
    candidate = value.strip()
    if not candidate:
        return None
    had_scheme = "://" in candidate
    if not had_scheme:
        candidate = f"https://{candidate}"
    parsed = urlparse(candidate)
    hostname = parsed.hostname or ""
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or any(character.isspace() for character in parsed.netloc)
    ):
        return None
    if not had_scheme and "." not in hostname and hostname != "localhost":
        try:
            ipaddress.ip_address(hostname)
        except ValueError:
            return None
    return candidate


def derive_image_name(stem: str) -> Tuple[str, Optional[str]]:
    name = stem
    filename_url = None
    if "_" in stem:
        possible_name, possible_url = stem.rsplit("_", 1)
        normalized = normalize_url(possible_url)
        if possible_name.strip() and normalized:
            name = possible_name
            filename_url = normalized

    safe_name = INVALID_FOLDER_CHARS.sub("-", name).strip().rstrip(".")
    if safe_name in {"", ".", ".."}:
        raise ValueError("이미지명으로 안전한 폴더 이름을 만들 수 없습니다.")
    if safe_name.casefold() in {folder.casefold() for folder in RESERVED_FOLDERS}:
        raise ValueError(f"예약된 폴더 이름은 이미지명으로 사용할 수 없습니다: {safe_name}")
    return safe_name, filename_url


def parse_landing_urls(raw: str) -> List[str]:
    if not raw.strip():
        return []
    values = re.split(r"[\r\n,]+", raw)
    urls: List[str] = []
    for value in values:
        if not value.strip():
            continue
        normalized = normalize_url(value)
        if not normalized:
            raise ValueError(f"유효하지 않은 landing URL입니다: {value.strip()}")
        urls.append(normalized)
    return urls


def write_github_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="Repository-relative source image path")
    parser.add_argument("--landing-urls", default="", help="Comma or newline separated CTA URLs")
    parser.add_argument(
        "--prompt",
        default=".github/codex/prompts/generate-edm.md",
        help="Repository-relative fixed prompt path",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repo = Path(run_git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
    image = (repo / args.image).resolve()
    try:
        image.relative_to(repo)
    except ValueError as exc:
        raise SystemExit("이미지는 저장소 내부 경로여야 합니다.") from exc
    if not image.is_file():
        raise SystemExit(f"이미지를 찾을 수 없습니다: {args.image}")
    if image.suffix.lower() not in SUPPORTED_EXTENSIONS:
        raise SystemExit(f"지원하지 않는 이미지 확장자입니다: {image.suffix}")

    prompt_path = (repo / args.prompt).resolve()
    if not prompt_path.is_file():
        raise SystemExit(f"고정 프롬프트를 찾을 수 없습니다: {args.prompt}")

    image_name, filename_url = derive_image_name(image.stem)
    target_folder = image_name
    landing_urls = parse_landing_urls(args.landing_urls)
    context = {
        "source_image": image.relative_to(repo).as_posix(),
        "source_extension": image.suffix.lower(),
        "image_name": image_name,
        "target_folder": target_folder,
        "filename_url": filename_url,
        "landing_urls": landing_urls,
        "target_branch": "main",
    }

    write_github_output("image_name", image_name)
    write_github_output("target_folder", target_folder)

    prompt = (
        prompt_path.read_text(encoding="utf-8")
        + "\n\n```json\n"
        + json.dumps(context, ensure_ascii=False, indent=2)
        + "\n```\n"
    )

    if args.dry_run:
        print(json.dumps(context, ensure_ascii=False, indent=2))
        return 0

    if run_git(repo, "branch", "--show-current") != "main":
        raise SystemExit("Codex 생성은 main 브랜치에서만 실행할 수 있습니다.")
    if run_git(repo, "status", "--porcelain"):
        raise SystemExit("작업 트리가 깨끗하지 않아 Codex 생성을 시작하지 않습니다.")

    login = subprocess.run(
        ["codex", "login", "status"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if login.returncode != 0 or "Logged in" not in (login.stdout + login.stderr):
        raise SystemExit("로컬 Codex CLI가 로그인되어 있지 않습니다.")

    command = [
        "codex",
        "exec",
        "--image",
        str(image),
        "--ephemeral",
        "--sandbox",
        "workspace-write",
        "--add-dir",
        str(repo / ".git"),
        "-c",
        'approval_policy="never"',
        "-c",
        "sandbox_workspace_write.network_access=true",
        "-C",
        str(repo),
        "-",
    ]
    result = subprocess.run(command, cwd=repo, input=prompt, text=True)
    if result.returncode != 0:
        return result.returncode

    required = [
        repo / target_folder / f"{image_name}.html",
        repo / target_folder / f"{image_name}.eml",
        repo / target_folder / "summary.json",
    ]
    missing = [path.relative_to(repo).as_posix() for path in required if not path.is_file()]
    if missing:
        raise SystemExit(f"Codex 실행 후 필수 산출물이 없습니다: {', '.join(missing)}")
    if run_git(repo, "status", "--porcelain"):
        raise SystemExit("Codex 실행 후 커밋되지 않은 변경사항이 남았습니다.")

    run_git(repo, "fetch", "origin", "main")
    local_head = run_git(repo, "rev-parse", "HEAD")
    remote_head = run_git(repo, "rev-parse", "origin/main")
    if local_head != remote_head:
        raise SystemExit("Codex 결과 커밋이 origin/main과 동기화되지 않았습니다.")

    print(f"Codex eDM 생성 완료: {target_folder}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (subprocess.CalledProcessError, ValueError) as error:
        print(f"오류: {error}", file=sys.stderr)
        raise SystemExit(1) from error
