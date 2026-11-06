#!/usr/bin/env zsh
# sdk-java-upgrade: move each installed SDKMAN Java to the newest build of the
# same feature release and vendor (e.g. 17.0.12-tem -> 17.0.14-tem). It never
# jumps feature releases (17 -> 21). Shows the plan and asks before acting.
#
# Usage: sdk-java-upgrade.sh [-k] [-n]
#   -k  keep old versions (install new ones and move the default, uninstall nothing)
#   -n  dry run: print the plan and exit

keep_old=0 dry_run=0
while getopts "knh" opt; do
  case $opt in
    k) keep_old=1 ;;
    n) dry_run=1 ;;
    *) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 2 ;;
  esac
done

SDKMAN_DIR=${SDKMAN_DIR:-$HOME/.sdkman}
init="$SDKMAN_DIR/bin/sdkman-init.sh"
[[ -s $init ]] || { print -u2 "SDKMAN not found at $SDKMAN_DIR"; exit 1 }
source "$init"
java_dir="$SDKMAN_DIR/candidates/java"

print ">> sdk update"
sdk update

# For each identifier on stdin print: <id> <group> <sortkey>
#   group   = feature version | flavour | vendor   e.g. "17||tem", "21|fx|zulu"
#   sortkey = zero-padded numeric parts, prefixed with "v" so awk compares
#             it as a string, not as a (lossy) 64-digit number.
describe_all() {
  awk 'NF {
    id = $0; v = id; sub(/-[^-]*$/, "", v)
    if (v == id) next                       # no vendor suffix; ignore
    vendor = substr(id, length(v) + 2)
    match(v, /^[0-9.+]*/); num = substr(v, 1, RLENGTH); flav = substr(v, RLENGTH + 1)
    sub(/[.+]$/, "", num); sub(/^[.+]/, "", flav)
    n = split(num, a, /[.+]/); key = "v"
    for (i = 1; i <= 8; i++) key = key sprintf("%08d", (i <= n ? a[i] : 0))
    print id, a[1] "|" flav "|" vendor, key
  }'
}

# Installed: real directories only (symlinks are "local" installs SDKMAN doesn't manage).
installed=( $java_dir/*(N/^@:t) )
installed=( ${installed:#current} )
(( $#installed )) || { print "No SDKMAN-managed Java installations found."; exit 0 }

default=""
[[ -L $java_dir/current ]] && default=${$(readlink "$java_dir/current"):t}

print "\nFetching available Java versions..."
available=$(PAGER=cat sdk list java 2>/dev/null | awk -F'|' '
  { gsub(/\033\[[0-9;]*m/, "") }
  NF >= 4 && !/local only/ && $NF !~ /Identifier/ { gsub(/[[:space:]]/, "", $NF); if ($NF != "") print $NF }')
[[ -n $available ]] || { print -u2 "Could not read 'sdk list java' (offline?)"; exit 1 }

print "\nInstalled:"
for id in $installed; do
  if [[ $id == $default ]]; then print "  $id  (default)"; else print "  $id"; fi
done

# Plan lines: "1 install <new>", "2 default <new>", "3 uninstall <old> <new>"
plan=( ${(f)"$( { print -l $installed | describe_all | sed 's/^/I /'
                 describe_all <<<"$available" | sed 's/^/A /' } |
  awk -v def="$default" -v keep="$keep_old" '
    { src = $1; id = $2; g = $3; k = $4
      if (src == "I") { inst[id] = 1; ig[id] = g; ik[id] = k }
      if (!(g in bestk) || k > bestk[g]) { best[g] = id; bestk[g] = k } }
    END {
      for (id in inst) {
        g = ig[id]; if (ik[id] >= bestk[g]) continue
        tgt = best[g]
        if (!(tgt in inst) && !(tgt in queued)) { print "1 install", tgt; queued[tgt] = 1 }
        if (id == def) print "2 default", tgt
        if (!keep) print "3 uninstall", id, tgt
      }
    }' | sort)"} )

if (( ! $#plan )); then
  print "\nEverything is on the latest build of its release line."; exit 0
fi

print "\nPlanned commands:"
for line in $plan; do
  read -r _ action id _ <<<"$line"; print "  sdk $action java $id"
done
print "  sdk flush tmp"

# Warn about hard-coded paths/pins that would break when old versions go away.
if (( ! keep_old )); then
  removals=( ${${(M)plan:#3 uninstall *}[@]} )
  removals=( ${${removals#3 uninstall }%% *} )
  for f in ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.profile \
           ~/.gradle/gradle.properties ~/.mavenrc ./.sdkmanrc; do
    [[ -f $f ]] || continue
    for id in $removals; do
      grep -n -F -- "$id" "$f" 2>/dev/null | sed "s|^|  warning: $f:|; s|\$|   <- references $id|"
    done
  done
fi

(( dry_run )) && { print "\nDry run; nothing changed."; exit 0 }

print
read -r "ans?Proceed? [y/N] " </dev/tty
[[ $ans == [yY]* ]] || { print "Aborted."; exit 1 }

failed=() errors=0
for line in $plan; do
  read -r _ action id target <<<"$line"
  target=${target:-$id}
  if (( ${failed[(Ie)$target]} )); then
    print ">> skipping 'sdk $action java $id': $target did not install"; continue
  fi
  print "\n>> sdk $action java $id"
  case $action in
    install)
      # Answer "n" to "set as default?". sdkman_auto_answer can't be overridden
      # here because every `sdk` call re-sources etc/config, and SDKMAN skips
      # the question (treating it as yes) when no version is in use. So also
      # check the `current` link afterwards and put the default back.
      before=${$(readlink "$java_dir/current" 2>/dev/null):t}
      print n | sdk install java "$id"
      if [[ ! -d $java_dir/$id ]]; then
        print -u2 "!! install of $id failed; leaving its old versions in place"
        failed+=$id; errors=1
      fi
      after=${$(readlink "$java_dir/current" 2>/dev/null):t}
      if [[ -n $before && $after != $before ]]; then
        print ">> install changed the default to $after; restoring $before"
        sdk default java "$before" || errors=1
      fi ;;
    default)   sdk default java "$id"   || errors=1 ;;
    uninstall) sdk uninstall java "$id" || errors=1 ;;
  esac
done

print "\n>> sdk flush tmp"
sdk flush tmp

print
if (( errors )); then print "Finished with errors (see above)."; else print "Done."; fi
print "Shells already open keep using the 'current' symlink, so they pick up the new"
print "default. Any shell where you ran 'sdk use java <old>' needs a new 'sdk use'."
exit $errors
