#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 'usage: package-toolchain.sh OUTPUT_RESOURCES_DIRECTORY'
  exit 64
fi

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
REPOSITORY_ROOT=${APP_DIR:h:h}
OUTPUT_ROOT=${1:A}/SiloToolchain
PAYLOAD_ROOT=$OUTPUT_ROOT/payload
MANIFEST=$OUTPUT_ROOT/manifest.json

typeset -a artifacts=(
  VERSION
  MANIFEST.txt
  config.sh
  bin/silo
  bin/silo-git-askpass
  bin/silo-github-host-token
  bin/silo-github-proxy
  bin/silo-keychain-bridge
  bin/silo-ssh-proxy
  launchd/org.silo.Silo.github-proxy.plist
  lib/bootstrap-base.sh
  lib/silo-github-relay.py
  lib/silo-github-shuttle.py
  lib/silo-port-forwarder.py
  lib/proxy-upstream.py
  lib/proxycore.py
  lib/vendor/h11/LICENSE.txt
  lib/vendor/h11/__init__.py
  lib/vendor/h11/_abnf.py
  lib/vendor/h11/_connection.py
  lib/vendor/h11/_events.py
  lib/vendor/h11/_headers.py
  lib/vendor/h11/_readers.py
  lib/vendor/h11/_receivebuffer.py
  lib/vendor/h11/_state.py
  lib/vendor/h11/_util.py
  lib/vendor/h11/_version.py
  lib/vendor/h11/_writers.py
  lib/vendor/h11/py.typed
)

for relative in $artifacts; do
  source=$REPOSITORY_ROOT/$relative
  if [[ ! -f $source || -L $source ]]; then
    print -u2 "required bundled Silo artifact is absent or unsafe: $relative"
    exit 1
  fi
  if [[ $relative != MANIFEST.txt ]]; then
    expected=$(/usr/bin/awk -v path="$relative" '$2 == path {print $1}' $REPOSITORY_ROOT/MANIFEST.txt)
    actual=$(/usr/bin/shasum -a 256 $source | /usr/bin/awk '{print $1}')
    if [[ ! $expected =~ '^[0-9a-f]{64}$' || $actual != $expected ]]; then
      print -u2 "repository manifest integrity failed for bundled artifact: $relative"
      exit 1
    fi
  fi
done

version=$(/bin/cat $REPOSITORY_ROOT/VERSION)
if [[ $version != <->.<->.<-> ]]; then
  print -u2 'VERSION must contain one semantic version'
  exit 1
fi
if ! /usr/bin/grep -Fqx "SILO_CLI_VERSION=\"$version\"" $REPOSITORY_ROOT/bin/silo; then
  print -u2 'bin/silo identity does not match VERSION'
  exit 1
fi

/bin/rm -rf -- $OUTPUT_ROOT
/bin/mkdir -p -- $PAYLOAD_ROOT

typeset entries=''
for relative in $artifacts; do
  source=$REPOSITORY_ROOT/$relative
  destination=$PAYLOAD_ROOT/$relative
  /bin/mkdir -p -- ${destination:h}
  /bin/cp -p -- $source $destination
  if [[ -x $source ]]; then
    /bin/chmod 0755 $destination
    executable=true
  else
    /bin/chmod 0644 $destination
    executable=false
  fi
  digest=$(/usr/bin/shasum -a 256 $destination | /usr/bin/awk '{print $1}')
  [[ $digest =~ '^[0-9a-f]{64}$' ]] || exit 1
  [[ -n $entries ]] && entries+=','
  entries+="{\"path\":\"$relative\",\"sha256\":\"$digest\",\"executable\":$executable}"
done

print -r -- "{\"schemaVersion\":1,\"version\":\"$version\",\"artifacts\":[$entries]}" >$MANIFEST
/bin/chmod 0644 $MANIFEST
/usr/bin/find $OUTPUT_ROOT -type d -exec /bin/chmod 0755 {} +

# Verify the serialized manifest and every copied hash before Xcode signs the
# completed app. Missing inputs and packaging drift fail the build phase.
/usr/bin/plutil -p $MANIFEST >/dev/null
for relative in $artifacts; do
  actual=$(/usr/bin/shasum -a 256 $PAYLOAD_ROOT/$relative | /usr/bin/awk '{print $1}')
  if [[ -x $REPOSITORY_ROOT/$relative ]]; then executable=true; else executable=false; fi
  entry="{\"path\":\"$relative\",\"sha256\":\"$actual\",\"executable\":$executable}"
  /usr/bin/grep -Fq -- $entry $MANIFEST || {
    print -u2 "bundled Silo hash verification failed: $relative"
    exit 1
  }
done
