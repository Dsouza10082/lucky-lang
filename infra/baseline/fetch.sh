#!/usr/bin/env bash
# Fetch the upstream sources pinned in upstreams.lock and verify commits and licenses.
#
# Git entries whose role is not "reference" are cloned with depth 1 into
# $WORK/src/<name>. "reference" entries only have their tag checked on the remote
# and their licenses downloaded from the commit. Fails if a tag points to another
# commit, if a license text differs from licenses.lock, or if an existing tree has
# local changes: $WORK/src is disposable and holds no project work.

. "$(dirname "$0")/lib.sh"

mkdir -p "$SRC" "$EVIDENCE"
report="$EVIDENCE/upstreams.tsv"
licenses="$EVIDENCE/licenses.tsv"
printf 'name\trole\tsource\tversion\tcommit\tverification\tlocal_patches\n' > "$report"
printf 'name\tfile\tsha256\tlicense\tverification\n' > "$licenses"

clone_names=""
for name in $(lock_names); do
  case $(lock_get "$name" role) in reference | bootstrap) ;; *) clone_names="$clone_names $name" ;; esac
done

# Refuse to delete local work; then remove every tree, so that a failure halfway
# does not leave sources from an earlier run for the later stages.
for name in $clone_names; do
  dir="$SRC/$name"
  if git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 &&
    [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    die "$name: $dir has local changes; move them before fetching the sources again"
  fi
done
for name in $clone_names; do remove_tree "$SRC/$name"; done

# check_licenses NAME DIR|-: check every licenses.lock file of the entry.
check_licenses() {
  local name=$1 dir=$2 file want spdx got commit url
  while IFS="$(printf '\t')" read -r n file want spdx; do
    [ "$n" = "$name" ] || continue
    if [ "$dir" = - ]; then
      commit=$(lock_get "$name" id)
      url="$(lock_get "$name" source | sed 's#^https://github.com/#https://raw.githubusercontent.com/#')/$commit/$file"
      command -v curl >/dev/null 2>&1 || die "$name: curl missing; needed to check $file at $url"
      got=$(curl -sfL "$url" | sha256 | cut -d' ' -f1) || die "$name: could not download $url"
    else
      [ -f "$dir/$file" ] || die "$name: license $file missing in $dir"
      got=$(sha256 "$dir/$file" | cut -d' ' -f1)
    fi
    [ "$got" = "$want" ] || die "$name: $file has sha256 $got; licenses.lock records $want (review the license)"
    printf '%s\t%s\t%s\t%s\tsha256 checked\n' "$name" "$file" "$got" "$spdx" >> "$licenses"
  done < <(grep -v -E '^[[:space:]]*(#|$)' "$BASELINE_DIR/licenses.lock")
  grep -q "^$name	" "$licenses" || die "$name: no license listed in licenses.lock"
}

for name in $(lock_names); do
  role=$(lock_get "$name" role)
  url=$(lock_get "$name" source)
  tag=$(lock_get "$name" version)
  commit=$(lock_get "$name" id)
  [ "$role" = bootstrap ] && continue

  if [ "$role" = reference ]; then
    got=$(git ls-remote "$url" "refs/tags/$tag" "refs/tags/$tag^{}" | awk '{ c = $1 } END { print c }')
    [ "$got" = "$commit" ] || die "$name: tag $tag resolves to '$got'; the lock requires $commit"
    check_licenses "$name" -
    echo "$name: $tag = $commit (reference, not cloned)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$role" "$url" "$tag" "$commit" "ls-remote" "-" >> "$report"
    continue
  fi

  dir="$SRC/$name"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$url" "refs/tags/$tag"
  got=$(git -C "$dir" rev-parse 'FETCH_HEAD^{commit}')
  [ "$got" = "$commit" ] || die "$name: tag $tag resolves to $got; the lock requires $commit"
  git -C "$dir" -c core.autocrlf=false -c advice.detachedHead=false checkout -q "$commit"
  git -C "$dir" tag "$tag" "$commit"
  check_licenses "$name" "$dir"
  # The baseline is unmodified upstream: any difference here is an error.
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$name: checkout differs from $commit"
  echo "$name: $tag = $commit -> $dir"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$role" "$url" "$tag" "$commit" "clone+rev-parse" "none" >> "$report"
done

# Modules that Go vendors into std and cmd (src/vendor and src/cmd/vendor).
vendor="$EVIDENCE/go-vendor-licenses.tsv"
printf 'module\tfile\tsha256\tfirst_line\n' > "$vendor"
for root in src/vendor src/cmd/vendor; do
  awk '/^# / { print $2 "@" $3 }' "$SRC/go/$root/modules.txt" | while read -r mod; do
    license_rows "$mod" "$SRC/go/$root/${mod%@*}" >> "$vendor"
  done
done
echo "modules vendored into Go: $(tail -n +2 "$vendor" | cut -f1 | LC_ALL=C sort -u | wc -l | tr -d ' ')"
