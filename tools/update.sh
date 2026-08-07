#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

release_mode="latest"
release_selector=""

usage() {
	cat <<'EOF'
Uso: bash tools/update.sh [--latest-release] [--release <release>] [--choose-release]

	--latest-release  Actualiza a la release publicada más reciente (por defecto)
	--release <release>  Actualiza a una release publicada concreta
	--choose-release   Muestra una lista de releases publicadas y deja elegir una
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--latest-release)
			release_mode="latest"
			release_selector=""
			shift
			;;
		--release)
			if [[ $# -lt 2 ]]; then
				echo "error: falta la release para --release"
				usage
				exit 1
			fi
			release_mode="exact"
			release_selector="$2"
			shift 2
			;;
		--release=*)
			release_mode="exact"
			release_selector="${1#*=}"
			shift
			;;
		--choose-release)
			release_mode="choose"
			release_selector=""
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "error: argumento desconocido: $1"
			usage
			exit 1
			;;
	esac
done

echo "== Senderman FTP Admin update =="
echo "Repo: $repo_root"

if ! command -v python3 >/dev/null 2>&1; then
	echo "error: python3 no está instalado"
	exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
	echo "error: pip3 no está instalado"
	exit 1
fi

git fetch --tags origin >/dev/null 2>&1 || true

get_repo_slug() {
	local remote_url
	remote_url="$(git remote get-url origin 2>/dev/null || true)"

	case "$remote_url" in
		https://github.com/*)
			printf '%s' "${remote_url#https://github.com/}" | sed 's/\.git$//'
			;;
		http://github.com/*)
			printf '%s' "${remote_url#http://github.com/}" | sed 's/\.git$//'
			;;
		git@github.com:*)
			printf '%s' "${remote_url#git@github.com:}" | sed 's/\.git$//'
			;;
		*)
			echo "error: no se pudo resolver el repositorio GitHub desde origin: $remote_url"
			exit 1
			;;
	esac
}

resolve_release_info() {
	local mode="$1"
	local selector="$2"

	python3 - "$mode" "$selector" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
import urllib.error
import urllib.request

mode, selector = sys.argv[1:3]


def repo_slug() -> str:
	remote_url = subprocess.run(
		["git", "remote", "get-url", "origin"],
		check=True,
		text=True,
		capture_output=True,
	).stdout.strip()

	prefixes = {
		"https://github.com/": "",
		"http://github.com/": "",
		"git@github.com:": "",
	}
	for prefix, replacement in prefixes.items():
		if remote_url.startswith(prefix):
			slug = remote_url[len(prefix) :]
			return slug[:-4] if slug.endswith(".git") else slug
	raise SystemExit(f"error: no se pudo resolver el repositorio GitHub desde origin: {remote_url}")


def fetch_json(url: str):
	request = urllib.request.Request(
		url,
		headers={"Accept": "application/vnd.github+json", "User-Agent": "senderman-installer"},
	)
	with urllib.request.urlopen(request) as response:
		return json.load(response)


def git_tags() -> list[str]:
	result = subprocess.run(["git", "tag", "--sort=-creatordate"], check=True, text=True, capture_output=True)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def release_line(tag: str, tarball_url: str, name: str) -> str:
	return f"{tag}|{tarball_url}|{name}"


slug = repo_slug()

try:
	if mode == "latest":
		latest = fetch_json(f"https://api.github.com/repos/{slug}/releases/latest")
		print(release_line(latest["tag_name"], latest["tarball_url"], latest.get("name") or latest["tag_name"]))
		raise SystemExit(0)

	releases = [release for release in fetch_json(f"https://api.github.com/repos/{slug}/releases?per_page=100") if not release.get("draft") and not release.get("prerelease")]

	if mode == "exact":
		for release in releases:
			if release.get("tag_name") == selector:
				print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
				raise SystemExit(0)
		raise SystemExit(f"error: no se encontró una release publicada para {selector}")

	if mode == "choose":
		if releases:
			print("Releases publicadas disponibles:")
			for index, release in enumerate(releases, start=1):
				published_at = (release.get("published_at") or "")[:10]
				title = release.get("name") or release["tag_name"]
				print(f"{index}) {release['tag_name']} - {title} ({published_at})")

			if not sys.stdin.isatty():
				raise SystemExit("error: --choose-release requiere una terminal interactiva")

			while True:
				choice = input("Elige una release por número o tag: ").strip()
				if not choice:
					continue
				if choice.isdigit():
					selected_index = int(choice) - 1
					if 0 <= selected_index < len(releases):
						release = releases[selected_index]
						print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
						raise SystemExit(0)
					print("Opción fuera de rango. Intenta otra vez.")
					continue

				for release in releases:
					if release.get("tag_name") == choice:
						print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
						raise SystemExit(0)

				print("No encontré esa release. Intenta otra vez.")

		tags = git_tags()
		if not tags:
			raise SystemExit("error: no hay tags locales disponibles para compatibilidad")

		print("Tags locales disponibles:")
		for index, tag in enumerate(tags, start=1):
			print(f"{index}) {tag}")

		if not sys.stdin.isatty():
			raise SystemExit("error: --choose-release requiere una terminal interactiva")

		while True:
			choice = input("Elige un tag por número o nombre: ").strip()
			if not choice:
				continue
			if choice.isdigit():
				selected_index = int(choice) - 1
				if 0 <= selected_index < len(tags):
					tag = tags[selected_index]
					print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
					raise SystemExit(0)
				print("Opción fuera de rango. Intenta otra vez.")
				continue

			if choice in tags:
				print(release_line(choice, f"https://github.com/{slug}/archive/refs/tags/{choice}.tar.gz", choice))
				raise SystemExit(0)

			print("No encontré ese tag. Intenta otra vez.")

	raise SystemExit(f"error: modo de release desconocido: {mode}")

except urllib.error.HTTPError as exc:
	if exc.code != 404:
		raise SystemExit(f"error: no se pudo consultar GitHub Releases: {exc}")

	tags = git_tags()
	if not tags:
		raise SystemExit("error: no hay tags locales disponibles para compatibilidad")

	if mode == "latest":
		tag = tags[0]
		print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
	elif mode == "exact":
		if selector not in tags:
			raise SystemExit(f"error: no se encontró un tag local para {selector}")
		print(release_line(selector, f"https://github.com/{slug}/archive/refs/tags/{selector}.tar.gz", selector))
	elif mode == "choose":
		print("Tags locales disponibles:")
		for index, tag in enumerate(tags, start=1):
			print(f"{index}) {tag}")

		if not sys.stdin.isatty():
			raise SystemExit("error: --choose-release requiere una terminal interactiva")

		while True:
			choice = input("Elige un tag por número o nombre: ").strip()
			if not choice:
				continue
			if choice.isdigit():
				selected_index = int(choice) - 1
				if 0 <= selected_index < len(tags):
					tag = tags[selected_index]
					print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
					raise SystemExit(0)
				print("Opción fuera de rango. Intenta otra vez.")
				continue

			if choice in tags:
				print(release_line(choice, f"https://github.com/{slug}/archive/refs/tags/{choice}.tar.gz", choice))
				raise SystemExit(0)

			print("No encontré ese tag. Intenta otra vez.")
	else:
		raise SystemExit(f"error: modo de release desconocido: {mode}")

except urllib.error.URLError as exc:
	raise SystemExit(f"error: no se pudo consultar GitHub Releases: {exc}")
PY
}

	select_tag_info() {
	  local repo_slug="$1"
	  local mode="$2"
	  local selector="$3"

	  python3 - "$repo_slug" "$mode" "$selector" <<'PY'
	from __future__ import annotations

	import subprocess
	import sys

	repo_slug, mode, selector = sys.argv[1:4]


	def git_tags() -> list[str]:
		result = subprocess.run(["git", "tag", "--sort=-creatordate"], check=True, text=True, capture_output=True)
		return [line.strip() for line in result.stdout.splitlines() if line.strip()]


	def tag_line(tag: str) -> str:
		return f"{tag}|https://github.com/{repo_slug}/archive/refs/tags/{tag}.tar.gz|{tag}"


	tags = git_tags()
	if not tags:
		print("error: no hay tags locales disponibles para compatibilidad", file=sys.stderr)
		raise SystemExit(1)

	if mode == "latest":
		print(tag_line(tags[0]))
	elif mode == "exact":
		if selector not in tags:
			print(f"error: no se encontró un tag local para {selector}", file=sys.stderr)
			raise SystemExit(1)
		print(tag_line(selector))
	elif mode == "choose":
		print("Tags locales disponibles:")
		for index, tag in enumerate(tags, start=1):
			print(f"{index}) {tag}")

		if not sys.stdin.isatty():
			print("error: --choose-release requiere una terminal interactiva", file=sys.stderr)
			raise SystemExit(1)

		while True:
			choice = input("Elige un tag por número o nombre: ").strip()
			if not choice:
				continue
			if choice.isdigit():
				selected_index = int(choice) - 1
				if 0 <= selected_index < len(tags):
					print(tag_line(tags[selected_index]))
					break
				print("Opción fuera de rango. Intenta otra vez.")
				continue

			if choice in tags:
				print(tag_line(choice))
				break

			print("No encontré ese tag. Intenta otra vez.")
	else:
		print(f"error: modo de tag desconocido: {mode}", file=sys.stderr)
		raise SystemExit(1)
	PY
	}

select_release_info() {
	local repo_slug="$1"
	local mode="$2"
	local selector="$3"

	python3 - "$repo_slug" "$mode" "$selector" <<'PY'
from __future__ import annotations

import json
import sys
import urllib.request

repo_slug, mode, selector = sys.argv[1:4]
headers = {
		"Accept": "application/vnd.github+json",
		"User-Agent": "senderman-installer",
}


def fetch_json(url: str):
		request = urllib.request.Request(url, headers=headers)
		with urllib.request.urlopen(request) as response:
				return json.load(response)


def release_line(release: dict) -> str:
		return f"{release['tag_name']}|{release['tarball_url']}|{release.get('name') or release['tag_name']}"


try:
		if mode == "latest":
				print(release_line(fetch_json(f"https://api.github.com/repos/{repo_slug}/releases/latest")))
		elif mode == "exact":
				releases = fetch_json(f"https://api.github.com/repos/{repo_slug}/releases?per_page=100")
				for release in releases:
						if release.get("draft"):
								continue
						if release.get("tag_name") == selector:
								print(release_line(release))
								break
				else:
						print(f"error: no se encontró una release publicada para {selector}", file=sys.stderr)
						raise SystemExit(1)
		elif mode == "choose":
				releases = [release for release in fetch_json(f"https://api.github.com/repos/{repo_slug}/releases?per_page=100") if not release.get("draft") and not release.get("prerelease")]
				if not releases:
						print("error: no hay releases publicadas disponibles", file=sys.stderr)
						raise SystemExit(1)

				print("Releases publicadas disponibles:")
				for index, release in enumerate(releases, start=1):
						published_at = (release.get("published_at") or "")[:10]
						title = release.get("name") or release["tag_name"]
						print(f"{index}) {release['tag_name']} - {title} ({published_at})")

				if not sys.stdin.isatty():
						print("error: --choose-release requiere una terminal interactiva", file=sys.stderr)
						raise SystemExit(1)

				while True:
						choice = input("Elige una release por número o tag: ").strip()
						if not choice:
								continue
						if choice.isdigit():
								selected_index = int(choice) - 1
								if 0 <= selected_index < len(releases):
										print(release_line(releases[selected_index]))
										break
								print("Opción fuera de rango. Intenta otra vez.")
								continue

						for release in releases:
								if release.get("tag_name") == choice:
										print(release_line(release))
										raise SystemExit(0)

						print("No encontré esa release. Intenta otra vez.")
		else:
			print(f"error: modo de release desconocido: {mode}", file=sys.stderr)
			raise SystemExit(1)
	except urllib.error.HTTPError as exc:
		if exc.code == 404:
			print(f"__FALLBACK__|{mode}|{selector}")
		else:
			print(f"error: no se pudo consultar GitHub Releases: {exc}", file=sys.stderr)
			raise SystemExit(1)
	except urllib.error.URLError as exc:
		print(f"error: no se pudo consultar GitHub Releases: {exc}", file=sys.stderr)
		raise SystemExit(1)
PY
}

write_release_marker() {
	local release_tag="$1"
	printf '%s\n' "$release_tag" > .senderman-release
}

sync_release_tree() {
	local tarball_url="$1"

	python3 - "$tarball_url" "$repo_root" <<'PY'
from __future__ import annotations

import shutil
import subprocess
import sys
import tarfile
import tempfile
import re
import urllib.request
from pathlib import Path

tarball_url = sys.argv[1]
repo_root = Path(sys.argv[2]).resolve()
keep = {".git", ".venv", ".env", "panel.log", "users.json", "senderman_registry.sqlite3", "backups", "local-tools", ".senderman-release", "tools/update.sh"}

with tempfile.TemporaryDirectory() as temp_dir:
		temp_path = Path(temp_dir)
		archive_path = temp_path / "release.tar.gz"
		try:
			request = urllib.request.Request(tarball_url, headers={"User-Agent": "senderman-installer"})
			with urllib.request.urlopen(request) as response, open(archive_path, "wb") as archive_file:
				shutil.copyfileobj(response, archive_file)
		except Exception:
			match = (
				re.search(r"/tarball/([^/?#]+)$", tarball_url)
				or re.search(r"/archive/refs/tags/([^/]+)\.tar\.gz$", tarball_url)
				or re.search(r"/tags/([^/]+)\.tar\.gz$", tarball_url)
			)
			if not match:
				raise

			tag = match.group(1)
			subprocess.run(["git", "archive", "--format=tar.gz", f"--output={archive_path}", tag], check=True, cwd=repo_root)

		with tarfile.open(archive_path, "r:gz") as archive:
				archive.extractall(temp_path)

		extracted_roots = [entry for entry in temp_path.iterdir() if entry.name != archive_path.name]
		source_root = extracted_roots[0] if len(extracted_roots) == 1 and extracted_roots[0].is_dir() else temp_path

		for path in source_root.rglob("*"):
				relative_path = path.relative_to(source_root)
				if path == archive_path:
					continue
				if relative_path.as_posix() == "tools/update.sh":
					continue
				if relative_path.parts and relative_path.parts[0] in keep:
						continue

				destination = repo_root / relative_path
				if path.is_dir():
						destination.mkdir(parents=True, exist_ok=True)
				else:
						destination.parent.mkdir(parents=True, exist_ok=True)
						shutil.copy2(path, destination)

		for path in sorted(repo_root.rglob("*"), reverse=True):
				relative_path = path.relative_to(repo_root)
				if relative_path.parts and relative_path.parts[0] in keep:
						continue

				source_equivalent = source_root / relative_path
				if source_equivalent.exists():
						continue

				if path.is_dir():
						shutil.rmtree(path)
				else:
						path.unlink()
PY
}

repo_slug="$(get_repo_slug)"
if release_info="$(select_tag_info "$repo_slug" "$release_mode" "$release_selector" 2>/dev/null)"; then
	:
else
	release_info="$(resolve_release_info "$release_mode" "$release_selector")"
fi
IFS='|' read -r release_tag release_tarball_url release_name <<<"$release_info"
current_release_tag="$(cat .senderman-release 2>/dev/null || true)"

if [ "$current_release_tag" = "$release_tag" ]; then
	echo "Tu senderman está actualizado"
	exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "warning: el árbol tiene cambios locales; la actualización continuará con el estado actual"
fi

if [ ! -d .venv ]; then
	echo "error: no existe .venv. Ejecuta primero install.sh"
	exit 1
fi

echo "Actualizando a la release publicada: $release_tag"
if [ -n "$release_name" ]; then
	echo "Nombre: $release_name"
fi

sync_release_tree "$release_tarball_url"
write_release_marker "$release_tag"

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip >/dev/null
pip install -r requirements.txt

if systemctl list-unit-files | grep -q '^senderman-ftp-admin\.service'; then
	echo "Reiniciando servicio systemd..."
	sudo systemctl restart senderman-ftp-admin
else
	echo "Servicio systemd no detectado. Reinicia el panel manualmente si hace falta."
fi

echo
echo "Actualización completada."