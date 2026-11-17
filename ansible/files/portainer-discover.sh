#!/usr/bin/env bash
# Read-only inventory of Docker and Portainer on this host, used to plan the Portainer
# standardization from facts. It changes nothing and prints no secret values: environment variable
# NAMES only, and command-line flags without their values.
# Run as root by ansible/playbooks/portainer-discover.yml.

if ! command -v docker >/dev/null 2>&1; then
  echo "docker: not installed"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker: installed, but the daemon isn't answering"
  exit 0
fi

root_dir=$(docker info --format '{{.DockerRootDir}}')
echo "docker: $(docker version --format '{{.Server.Version}}')" \
  "| compose plugin: $(docker compose version --short 2>/dev/null || echo none)" \
  "| root dir: $root_dir"
echo "disk under $root_dir: $(df -h "$root_dir" 2>/dev/null | awk 'NR==2 {print $4 " free of " $2 " (" $5 " used)"}')"

# Ask a Portainer server for its version. Both endpoints are public (the login page uses them).
server_version() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, ssl, sys, urllib.request
ctx = ssl._create_unverified_context()
for path in ("/api/system/status", "/api/status"):
    try:
        with urllib.request.urlopen(sys.argv[1] + path, timeout=5, context=ctx) as r:
            print(json.load(r).get("Version", ""))
            break
    except Exception:
        pass
PY
}

# A standard agent answers /ping without authentication and names its version in a header.
agent_version() {
  python3 - "$1" <<'PY' 2>/dev/null
import ssl, sys, urllib.error, urllib.request
ctx = ssl._create_unverified_context()
try:
    with urllib.request.urlopen("https://127.0.0.1:%s/ping" % sys.argv[1], timeout=5, context=ctx) as r:
        print(r.headers.get("Portainer-Agent", ""))
except urllib.error.HTTPError as e:
    print(e.headers.get("Portainer-Agent", ""))
except Exception:
    pass
PY
}

label() { docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null; }

echo
echo "== Portainer containers"
found=0
for name in $(docker ps -a --format '{{.Names}}'); do
  image=$(docker inspect -f '{{.Config.Image}}' "$name")
  case "$image" in
    *portainer/portainer*|*portainer/agent*|*portainer-ce*|*portainer-ee*) ;;
    *) continue ;;
  esac
  found=1

  env_names=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" | cut -d= -f1 \
    | grep -vE '^(PATH|HOME|HOSTNAME|LANG|TERM|)$' | paste -sd, -)
  case "$image" in
    *agent*)
      if echo ",$env_names," | grep -q ',EDGE,'; then role="EDGE AGENT"; else role="AGENT (standard)"; fi ;;
    *) role="SERVER" ;;
  esac

  echo "- $name: $role"
  echo "    image: $image"
  echo "    image digest: $(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$image" 2>/dev/null)"
  echo "    state: $(docker inspect -f '{{.State.Status}}' "$name")" \
    "| restart: $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")" \
    "| created: $(docker inspect -f '{{.Created}}' "$name" | cut -c1-10)" \
    "| network: $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")"

  project=$(label "$name" com.docker.compose.project)
  if [ -n "$project" ]; then
    echo "    started by: docker compose, project '$project'"
    echo "      working dir: $(label "$name" com.docker.compose.project.working_dir)"
    echo "      compose file: $(label "$name" com.docker.compose.project.config_files)"
  else
    echo "    started by: docker run (no compose labels)"
  fi

  ports=$(docker port "$name" 2>/dev/null | paste -sd';' -)
  echo "    published ports: ${ports:-none}"
  echo "    environment variable names: ${env_names:-none}"
  flags=$(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$name" | grep '^-' | sed 's/=.*//' | paste -sd' ' -)
  echo "    command-line flags: ${flags:-none}"
  echo "    mounts:"
  docker inspect -f '{{range .Mounts}}{{println "      " .Type .Source "->" .Destination}}{{end}}' "$name" | grep -v '^ *$'

  if [ "$role" = "SERVER" ]; then
    version=""
    while read -r cport _ hostaddr; do
      hostport=${hostaddr##*:}
      case "$cport" in
        9443/tcp) url="https://127.0.0.1:$hostport" ;;
        9000/tcp) url="http://127.0.0.1:$hostport" ;;
        *) continue ;;
      esac
      version=$(server_version "$url")
      [ -n "$version" ] && break
    done < <(docker port "$name" 2>/dev/null)
    echo "    version (from its API): ${version:-not reported}"

    data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$name")
    if [ -n "$data" ] && [ -d "$data" ]; then
      echo "    data: $data ($(du -sh "$data" 2>/dev/null | cut -f1))"
      if [ -f "$data/portainer.db" ]; then
        echo "    database: $(stat -c '%s bytes, last written %y' "$data/portainer.db" | cut -d. -f1)"
      fi
      if [ -d "$data/compose" ]; then
        echo "    stack folders (IDs of stacks this server deployed): $(ls "$data/compose" | sort -n | paste -sd' ' -)"
      fi
    fi
  elif [ "$role" = "AGENT (standard)" ]; then
    version=""
    while read -r cport _ hostaddr; do
      [ "$cport" = "9001/tcp" ] || continue
      version=$(agent_version "${hostaddr##*:}")
      [ -n "$version" ] && break
    done < <(docker port "$name" 2>/dev/null)
    echo "    version (from its /ping): ${version:-not reported}"
  fi
done
[ "$found" = 0 ] && echo "(none)"

echo
echo "== Compose projects (a file under /data/compose/<id>/ means a Portainer server deployed it)"
docker compose ls -a 2>/dev/null || echo "(compose plugin not available)"

echo
echo "== All containers: name | image | compose project | status"
docker ps -a --format '{{.Names}} | {{.Image}} | {{.Label "com.docker.compose.project"}} | {{.Status}}' | sort

echo
listening=$( (ss -ltnH 2>/dev/null || true) | awk '{print $4}' | grep -E ':(8000|9000|9001|9443)$' | sort -u | paste -sd' ' -)
echo "== Listening on Portainer ports (8000 9000 9001 9443): ${listening:-none}"

echo
echo "== /root (non-hidden entries, where the Portainer configs live today)"
ls -l /root 2>/dev/null | awk 'NR>1 {print "  " $1, $9, $10, $11}'

exit 0
