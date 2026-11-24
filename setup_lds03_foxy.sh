#!/usr/bin/env bash
# =============================================================================
#  setup_lds03_foxy.sh
#  Add ROBOTIS LDS-03 (COIN-D4) LiDAR support to a TurtleBot3 running ROS 2 Foxy
#  (works for plain TurtleBot3 and TurtleBot3 + OpenMANIPULATOR-X).
#
#  Run ON THE ROBOT (SBC, e.g. Jetson Xavier NX / Raspberry Pi), as your normal
#  user (not with sudo; the script asks for sudo only where it needs it):
#
#      chmod +x setup_lds03_foxy.sh
#      ./setup_lds03_foxy.sh
#
#  Options:
#      --ws <path>          colcon workspace (default: ~/turtlebot3_ws)
#      --lds <model>        default LDS model written to ~/.bashrc
#                           LDS-01 | LDS-02 | LDS-03 (default: LDS-03)
#      --no-manipulation    don't touch turtlebot3_manipulation_bringup
#      -h, --help           show this help
#
#  What it does (safe to run more than once):
#    1. Clones + builds ROBOTIS coin_d4_driver (LDS-03 driver, pinned commit)
#    2. Adds LDS-03 to turtlebot3_bringup/robot.launch.py
#       (patches your source copy, or overlays tag 2.1.5 if TB3 came from apt)
#    3. Adds LDS-03 to turtlebot3_manipulation_bringup/hardware.launch.py
#       (if the manipulation packages are present)
#    4. Installs a udev rule so the LiDAR appears as /dev/tb3_lidar
#    5. Sets `export LDS_MODEL=LDS-03` in ~/.bashrc and sources the workspace
#
#  The LDS-03 driver publishes /scan (frame: base_scan, sensor-data QoS), the
#  same as the LDS-01/02 drivers, so existing Cartographer / Nav2 / RViz configs
#  work unchanged.
# =============================================================================
set -eo pipefail

# ---------------------------------------------------------------- settings ---
WS="${HOME}/turtlebot3_ws"
LDS_DEFAULT="LDS-03"
DO_MANIP=1

COIN_D4_REPO="https://github.com/ROBOTIS-GIT/coin_d4_driver.git"
COIN_D4_BRANCH="humble"
COIN_D4_COMMIT="d660caef830e0fce32ce9b6908b7b839af6dbe4a"   # v1.0.1, verified to build on Foxy
TB3_REPO="https://github.com/ROBOTIS-GIT/turtlebot3.git"
TB3_TAG="2.1.5"                                             # last Foxy-era release
TB3M_REPO="https://github.com/ROBOTIS-GIT/turtlebot3_manipulation.git"
TB3M_BRANCH="foxy-devel"
UDEV_RULE_FILE="/etc/udev/rules.d/99-tb3-lds03.rules"
MARK="added by setup_lds03_foxy.sh"

# ----------------------------------------------------------------- helpers ---
info() { printf '\033[1;34m[LDS-03]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  OK  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ WARN ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ FAIL ]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ws)              WS="$2"; shift 2 ;;
    --lds)             LDS_DEFAULT="$2"; shift 2 ;;
    --no-manipulation) DO_MANIP=0; shift ;;
    -h|--help)         usage ;;
    *)                 die "Unknown option: $1 (see --help)" ;;
  esac
done
case "$LDS_DEFAULT" in LDS-01|LDS-02|LDS-03) ;; *) die "--lds must be LDS-01, LDS-02 or LDS-03" ;; esac
WS="${WS%/}"

# ---------------------------------------------------------- 0. preflight ---
[ "${EUID}" -ne 0 ] || die "Run as your normal user, not with sudo (it edits YOUR ~/.bashrc and workspace)."
[ -f /opt/ros/foxy/setup.bash ] || die "ROS 2 Foxy not found at /opt/ros/foxy."
# shellcheck disable=SC1091
source /opt/ros/foxy/setup.bash
command -v git >/dev/null      || die "git is not installed (sudo apt install git)."
command -v python3 >/dev/null  || die "python3 is not installed."
if ! command -v colcon >/dev/null; then
  info "colcon not found, installing python3-colcon-common-extensions..."
  sudo apt-get install -y python3-colcon-common-extensions \
    || die "Could not install colcon. If apt complains about the ROS GPG key, update the ROS apt key first."
fi
mkdir -p "${WS}/src"
info "Workspace: ${WS}"

# Did this workspace previously use --symlink-install? Mixing modes breaks colcon.
SYMLINK_FLAG="--symlink-install"
if [ -d "${WS}/install" ] && ls "${WS}"/install/*/share/*/package.xml >/dev/null 2>&1; then
  if ! find "${WS}/install" -path '*/share/*/package.xml' -type l 2>/dev/null | grep -q .; then
    SYMLINK_FLAG=""
    info "Existing workspace was built without --symlink-install; keeping that."
  fi
fi

BUILD_PKGS=(coin_d4_driver)

# ------------------------------------------------- 1. LDS-03 driver source ---
info "Step 1/5: coin_d4_driver (LDS-03 driver)"
if [ -d "${WS}/src/coin_d4_driver/.git" ]; then
  git -C "${WS}/src/coin_d4_driver" fetch -q origin "${COIN_D4_BRANCH}" || warn "fetch failed, using local copy"
else
  git clone -q -b "${COIN_D4_BRANCH}" "${COIN_D4_REPO}" "${WS}/src/coin_d4_driver"
fi
git -C "${WS}/src/coin_d4_driver" -c advice.detachedHead=false checkout -q "${COIN_D4_COMMIT}" \
  || warn "Could not check out pinned commit; using branch head."
ok "coin_d4_driver source ready"

# ---------------------------------------------------- launch-file patcher ---
# patch_launch <file> <robot|manip>
patch_launch() {
  python3 - "$1" "$2" "$MARK" <<'PYEOF'
import re, sys, shutil, os
path, kind, mark = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
orig = src

# (a) Default LDS_MODEL to LDS-03 when the env var is missing
src = src.replace("os.environ['LDS_MODEL']", "os.environ.get('LDS_MODEL', 'LDS-03')")

# (b) Add an LDS-03 branch (idempotent)
if not re.search(r"LDS_MODEL == 'LDS-03'", src):
    lines = src.split('\n')
    try:
        i = next(n for n, l in enumerate(lines) if re.match(r"\s*elif LDS_MODEL == 'LDS-02':", l))
    except StopIteration:
        sys.exit("ERROR: could not find the LDS-02 branch in %s; patch it by hand." % path)
    ind = re.match(r"\s*", lines[i]).group(0)
    j = i + 1                        # first line after the LDS-02 block
    while j < len(lines) and (not lines[j].strip() or
                              len(re.match(r"\s*", lines[j]).group(0)) > len(ind)):
        j += 1
    b = ind + "    "
    if kind == "robot":
        block = [
            f"{ind}elif LDS_MODEL == 'LDS-03':  # {mark}",
            f"{b}lidar_pkg_dir = LaunchConfiguration(",
            f"{b}    'lidar_pkg_dir',",
            f"{b}    default=os.path.join(get_package_share_directory('coin_d4_driver'), 'launch'))",
            f"{b}LDS_LAUNCH_FILE = '/single_lidar_node.launch.py'",
        ]
    else:  # manip: original file has no else-branch -> crash on unknown model
        coin = (f"{b}lidar_launch = PathJoinSubstitution(\n"
                f"{b}    [FindPackageShare('coin_d4_driver'), 'launch', 'single_lidar_node.launch.py'])")
        block = [f"{ind}elif LDS_MODEL == 'LDS-03':  # {mark}", coin]
        if j >= len(lines) or not lines[j].strip().startswith("else"):
            block += [f"{ind}else:  # unknown LDS_MODEL -> use LDS-03 ({mark})", coin]
    # keep blank lines that preceded the next statement after our block
    k = j
    while k > i + 1 and not lines[k - 1].strip():
        k -= 1
    lines[k:k] = block
    src = '\n'.join(lines)

if src != orig:
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    open(path, "w").write(src)
    print("patched")
else:
    print("already patched")
compile(src, path, "exec")   # syntax check
PYEOF
}

find_src_file() {  # find_src_file <package> <relative file>
  find "${WS}/src" -maxdepth 5 -path "*/$1/$2" -not -path '*/.git/*' 2>/dev/null | head -n1
}
pkg_prefix() { ros2 pkg prefix "$1" 2>/dev/null || true; }
# When overlaying an apt install, only build the one package we patch;
# everything else in the cloned repo keeps coming from /opt/ros/foxy.
ignore_siblings() {  # ignore_siblings <repo dir> <package to keep>
  local d
  for d in "$1"/*/; do
    [ -f "${d}package.xml" ] || continue
    [ "$(basename "$d")" = "$2" ] || touch "${d}COLCON_IGNORE"
  done
}

# ------------------------------------------------- 2. turtlebot3_bringup ---
info "Step 2/5: turtlebot3_bringup"
ROBOT_LAUNCH="$(find_src_file turtlebot3_bringup launch/robot.launch.py)"
if [ -z "${ROBOT_LAUNCH}" ]; then
  [ -n "$(pkg_prefix turtlebot3_bringup)" ] \
    || die "turtlebot3_bringup is neither in ${WS}/src nor installed (apt). Set up TurtleBot3 for Foxy first."
  info "TurtleBot3 is installed from apt; overlaying turtlebot3 ${TB3_TAG} in the workspace."
  if [ -e "${WS}/src/turtlebot3" ]; then
    die "${WS}/src/turtlebot3 exists but has no turtlebot3_bringup; please check it."
  fi
  git -c advice.detachedHead=false clone -q --depth 1 -b "${TB3_TAG}" "${TB3_REPO}" "${WS}/src/turtlebot3"
  ignore_siblings "${WS}/src/turtlebot3" turtlebot3_bringup
  ROBOT_LAUNCH="$(find_src_file turtlebot3_bringup launch/robot.launch.py)"
fi
echo "    ${ROBOT_LAUNCH}: $(patch_launch "${ROBOT_LAUNCH}" robot)"
BUILD_PKGS+=(turtlebot3_bringup)
ok "turtlebot3_bringup knows LDS-03"

# -------------------------------------- 3. turtlebot3_manipulation_bringup ---
info "Step 3/5: turtlebot3_manipulation_bringup"
if [ "${DO_MANIP}" -eq 1 ]; then
  HW_LAUNCH="$(find_src_file turtlebot3_manipulation_bringup launch/hardware.launch.py)"
  if [ -z "${HW_LAUNCH}" ] && [ -n "$(pkg_prefix turtlebot3_manipulation_bringup)" ]; then
    info "Manipulation installed from apt; overlaying ${TB3M_BRANCH} in the workspace."
    [ -e "${WS}/src/turtlebot3_manipulation" ] && die "${WS}/src/turtlebot3_manipulation exists but is incomplete."
    git clone -q --depth 1 -b "${TB3M_BRANCH}" "${TB3M_REPO}" "${WS}/src/turtlebot3_manipulation"
    ignore_siblings "${WS}/src/turtlebot3_manipulation" turtlebot3_manipulation_bringup
    HW_LAUNCH="$(find_src_file turtlebot3_manipulation_bringup launch/hardware.launch.py)"
  fi
  if [ -n "${HW_LAUNCH}" ]; then
    echo "    ${HW_LAUNCH}: $(patch_launch "${HW_LAUNCH}" manip)"
    BUILD_PKGS+=(turtlebot3_manipulation_bringup)
    ok "turtlebot3_manipulation_bringup knows LDS-03"
  else
    info "turtlebot3_manipulation not found; skipping."
  fi
else
  info "Skipped (--no-manipulation)."
fi

# ------------------------------------------------------------- 4. udev ---
info "Step 4/5: udev rule -> /dev/tb3_lidar (sudo needed)"
RULE='ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ENV{ID_MM_DEVICE_IGNORE}="1", MODE:="0666", SYMLINK+="tb3_lidar"'
if [ -f "${UDEV_RULE_FILE}" ] && grep -qF 'SYMLINK+="tb3_lidar"' "${UDEV_RULE_FILE}"; then
  ok "udev rule already installed"
else
  sudo mkdir -p "$(dirname "${UDEV_RULE_FILE}")"
  printf '# LDS-03 USB2LDS (CP210x) -> /dev/tb3_lidar (%s)\n%s\n' "${MARK}" "${RULE}" \
    | sudo tee "${UDEV_RULE_FILE}" >/dev/null
  ok "wrote ${UDEV_RULE_FILE}"
fi
if command -v udevadm >/dev/null; then
  sudo udevadm control --reload-rules && sudo udevadm trigger || warn "udevadm reload failed; reboot or re-plug the LiDAR."
fi
if ! id -nG "${USER}" | grep -qw dialout; then
  sudo usermod -aG dialout "${USER}" && warn "Added ${USER} to 'dialout' group (takes effect after re-login)."
fi

# ------------------------------------------------------------ 5. build ---
info "Step 5/5: colcon build (${BUILD_PKGS[*]})"
(
  cd "${WS}"
  # shellcheck disable=SC2086
  colcon build ${SYMLINK_FLAG} --packages-up-to "${BUILD_PKGS[@]}"
) || die "colcon build failed (see output above)."
ok "build finished"

# ---------------------------------------------------------- ~/.bashrc ---
BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"
if grep -qE '^[[:space:]]*export[[:space:]]+LDS_MODEL=' "${BASHRC}"; then
  sed -i -E "s|^[[:space:]]*export[[:space:]]+LDS_MODEL=.*|export LDS_MODEL=${LDS_DEFAULT}|" "${BASHRC}"
else
  printf '\nexport LDS_MODEL=%s  # %s\n' "${LDS_DEFAULT}" "${MARK}" >> "${BASHRC}"
fi
grep -q '/opt/ros/foxy/setup.bash' "${BASHRC}" || echo 'source /opt/ros/foxy/setup.bash' >> "${BASHRC}"
WS_REL="${WS#"${HOME}"}"
if ! grep -qF "${WS}/install/setup.bash" "${BASHRC}" \
   && ! grep -qF "~${WS_REL}/install/setup.bash" "${BASHRC}" \
   && ! grep -qF "\$HOME${WS_REL}/install/setup.bash" "${BASHRC}"; then
  echo "source ${WS}/install/setup.bash  # ${MARK}" >> "${BASHRC}"
fi
# shellcheck disable=SC2088
ok "~/.bashrc: LDS_MODEL=${LDS_DEFAULT}, workspace sourced"

# ---------------------------------------------------------- verification ---
set +e
# shellcheck disable=SC1091
source "${WS}/install/setup.bash"
echo
info "Verification"
FAIL=0
P="$(pkg_prefix coin_d4_driver)"
if [ -n "$P" ]; then ok "coin_d4_driver -> $P"; else warn "coin_d4_driver not found after build"; FAIL=1; fi
P="$(pkg_prefix turtlebot3_bringup)"
if grep -q "LDS_MODEL == 'LDS-03'" "$P/share/turtlebot3_bringup/launch/robot.launch.py" 2>/dev/null; then
  ok "turtlebot3_bringup in use: $P (LDS-03 aware)"
else
  warn "turtlebot3_bringup in use ($P) is NOT the patched one. Check your ~/.bashrc source order."; FAIL=1
fi
if [ -e /dev/tb3_lidar ]; then
  ok "/dev/tb3_lidar -> $(readlink -f /dev/tb3_lidar)"
else
  warn "/dev/tb3_lidar not present yet (LiDAR unplugged? re-plug it, or check 'lsusb' shows 10c4:ea60)."
fi

echo
if [ "$FAIL" -eq 0 ]; then ok "Done."; else warn "Done, with warnings above."; fi
cat <<EOF

Next steps:
  1. Open a NEW terminal (or run: source ~/.bashrc)
  2. ros2 launch turtlebot3_bringup robot.launch.py
       (manipulator: ros2 launch turtlebot3_manipulation_bringup hardware.launch.py)
  3. In another terminal:  ros2 topic hz /scan     -> ~10 Hz after ~5 s warm-up
  SLAM / Nav2 on the remote PC are unchanged (same /scan topic, base_scan frame).

To go back to an older LiDAR:  ./$(basename "$0") --lds LDS-02   (or edit LDS_MODEL in ~/.bashrc)
Original launch files are kept as *.orig next to the patched ones.
EOF
