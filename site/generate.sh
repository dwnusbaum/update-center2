#!/usr/bin/env bash

# Usage: SECRET=dirname ./site/generate.sh "./www2" "./download"
[[ $# -eq 2 ]] || { echo "Usage: $0 <www root dir> <download root dir>" >&2 ; exit 1 ; }
[[ -n "$1" ]] || { echo "Non-empty www root dir required" >&2 ; exit 1 ; }
[[ -n "$2" ]] || { echo "Non-empty download root dir required" >&2 ; exit 1 ; }

[[ -n "$SECRET" ]] || { echo "SECRET env var not defined" >&2 ; exit 1 ; }
[[ -d "$SECRET" ]] || { echo "SECRET env var not a directory" >&2 ; exit 1 ; }
[[ -f "$SECRET/update-center.key" ]] || { echo "update-center.key does not exist in SECRET dir" >&2 ; exit 1 ; }
[[ -f "$SECRET/update-center.cert" ]] || { echo "update-center.cert does not exist in SECRET dir" >&2 ; exit 1 ; }

WWW_ROOT_DIR="$1"
DOWNLOAD_ROOT_DIR="$2"

set -o nounset
set -o pipefail
set -o errexit

# platform specific behavior
UNAME="$( uname )"
if [[ $UNAME == Linux ]] ; then
  SORT=sort
elif [[ $UNAME == Darwin ]] ; then
  SORT=gsort
else
  echo "Unknown platform: $UNAME" >&2
  exit 1
fi

function test_which() {
  which "$1" >/dev/null || { echo "Not on PATH: $1" >&2 ; exit 1 ; }
}

test_which curl
test_which wget
test_which $SORT
test_which jq
test_which mvn

set -x

RELEASES=$( curl 'https://repo.jenkins-ci.org/api/search/versions?g=org.jenkins-ci.main&a=jenkins-core&repos=releases&v=?.*.1' | jq --raw-output '.results[].version' | head -n 5 | $SORT --version-sort ) || { echo "Failed to retrieve list of releases" >&2 ; exit 1 ; }

# prepare the www workspace for execution
rm -rf "$WWW_ROOT_DIR"
mkdir -p "$WWW_ROOT_DIR"

# Generate htaccess file
$( dirname "$0" )/generate-htaccess.sh "${RELEASES[@]}" > "$WWW_ROOT_DIR/.htaccess"

# build update center generator
mvn -e clean install


# Reset arguments file
echo "# one update site per line" > args.lst

function generate() {
    echo "-connectionCheckUrl http://www.google.com/ -key $SECRET/update-center.key -certificate $SECRET/update-center.cert $@" >> args.lst
}

function sanity-check() {
    dir="$1"
    file="$dir/update-center.json"
    if [[ 700000 -ge $(cat  "$file" | wc -c ) ]] ; then
        echo "$file looks too small" >&2
        exit 1
    fi
}

# generate several update centers for different segments
# so that plugins can aggressively update baseline requirements
# without strnding earlier users.
#
# we use LTS as a boundary of different segments, to create
# a reasonable number of segments with reasonable sizes. Plugins
# tend to pick LTS baseline as the required version, so this works well.
#
# Looking at statistics like http://stats.jenkins-ci.org/jenkins-stats/svg/201409-jenkins.svg,
# I think three or four should be sufficient
#
# make sure the latest baseline version here is available as LTS and in the Maven index of the repo,
# otherwise it'll offer the weekly as update to a running LTS version


for ltsv in ${RELEASES[@]}; do
    v="${ltsv/%.1/}"
    # for mainline up to $v, which advertises the latest core
    generate -no-experimental -skip-release-history -skip-plugin-versions -www "$WWW_ROOT_DIR/$v" -cap $v.999 -capCore 2.999

    # for LTS
    generate -no-experimental -skip-release-history -skip-plugin-versions -www "$WWW_ROOT_DIR/stable-$v" -cap $v.999 -capCore 2.999 -stableCore
done


# On generating http://mirrors.jenkins-ci.org/plugins layout
#     this directory that hosts actual bits need to be generated by combining both experimental content and current content,
#     with symlinks pointing to the 'latest' current versions. So we generate exprimental first, then overwrite current to produce proper symlinks

# experimental update center. this is not a part of the version-based redirection rules
generate -skip-release-history -skip-plugin-versions -www "$WWW_ROOT_DIR/experimental" -download "$DOWNLOAD_ROOT_DIR"

# for the latest without any cap
# also use this to generae https://updates.jenkins-ci.org/download layout, since this generator run
# will capture every plugin and every core
generate -no-experimental -www "$WWW_ROOT_DIR/current" -www-download "$WWW_ROOT_DIR/download" -download "$DOWNLOAD_ROOT_DIR" -pluginCount.txt "$WWW_ROOT_DIR/pluginCount.txt"

# actually run the update center build
java -jar target/update-center2-*-bin*/update-center2-*.jar -id default -arguments-file args.lst

# generate symlinks to global /updates directory (created by crawler)
for ltsv in ${RELEASES[@]}; do
    v="${ltsv/%.1/}"

    sanity-check "$WWW_ROOT_DIR/$v"
    sanity-check "$WWW_ROOT_DIR/stable-$v"
    ln -sf ../updates "$WWW_ROOT_DIR/$v/updates"
    ln -sf ../updates "$WWW_ROOT_DIR/stable-$v/updates"

    # needed for the stable/ directory (below)
    lastLTS=$v
done

sanity-check "$WWW_ROOT_DIR/experimental"
sanity-check "$WWW_ROOT_DIR/current"
ln -sf ../updates "$WWW_ROOT_DIR/experimental/updates"
ln -sf ../updates $WWW_ROOT_DIR/current/updates



# generate symlinks to retain compatibility with past layout and make Apache index useful
pushd "$WWW_ROOT_DIR"
    ln -s stable-$lastLTS stable
    for f in latest latestCore.txt plugin-documentation-urls.json release-history.json update-center.*; do
        ln -s current/$f .
    done
popd

# copy other static resource files
cp -av "$( dirname "$0" )/static/readme.html" "$WWW_ROOT_DIR"
