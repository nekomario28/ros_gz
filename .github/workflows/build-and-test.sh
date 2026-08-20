#!/bin/bash
set -ev

# Configuration.
export COLCON_WS=~/ws
export COLCON_WS_SRC=${COLCON_WS}/src
export DEBIAN_FRONTEND=noninteractive
export ROS_PYTHON_VERSION=3

apt update -qq
apt install -qq -y lsb-release wget curl gnupg build-essential ca-certificates

# Use signed-by keyring files. `apt-key add` is removed on Ubuntu 24.04
# (noble), so the previous form silently produced untrusted apt sources
# and `ros-rolling-*` was never installable.
install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://packages.osrfoundation.org/gazebo.gpg \
  -o /etc/apt/keyrings/pkgs-osrf-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/gazebo-stable.list

curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /etc/apt/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2-testing/ubuntu $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/ros2-testing.list

apt-get update -qq
# Bootstrap: tools rosdep itself needs, plus `ros-base` so /opt/ros/$ROS_DISTRO
# exists to source. Every workspace dependency is then resolved by rosdep
# against the rolling distribution.yaml.
apt-get install -y python3-colcon-common-extensions \
                   python3-rosdep \
                   libcli11-dev \
                   ros-$ROS_DISTRO-ros-base

rosdep init
rosdep update --rosdistro $ROS_DISTRO
rosdep install --from-paths ./ -i -y --rosdistro $ROS_DISTRO $ROSDEP_ARGS

# Build. Capture output so the first concrete failure can be surfaced outside
# the Actions log on the fork-only diagnostic PR.
source /opt/ros/$ROS_DISTRO/setup.bash
mkdir -p $COLCON_WS_SRC
cp -r $GITHUB_WORKSPACE $COLCON_WS_SRC
cd $COLCON_WS
set +e
printf '\n::group::colcon build\n'
colcon build --event-handlers console_direct+ 2>&1 | tee /tmp/ros_gz-colcon-build.log
build_status=${PIPESTATUS[0]}
printf '::endgroup::\n'
if [ $build_status -ne 0 ]; then
  first_failure=$(grep -m1 -E 'fatal error:|(^|[[:space:]])error:|CMake Error|FAILED:|Failed[[:space:]]+<<<|ninja: (error|build stopped)|make(\[[0-9]+\])?: \*\*\*' /tmp/ros_gz-colcon-build.log || true)
  if [ -z "$first_failure" ]; then
    first_failure=$(tail -n 1 /tmp/ros_gz-colcon-build.log)
  fi
  {
    printf '### ros_gz CI diagnostic: build failure\n\n'
    printf 'Exit status: `%s`\n\n' "$build_status"
    printf 'First matched failure:\n\n```text\n%s\n```\n\n' "$first_failure"
    printf 'Last 80 build-output lines:\n\n```text\n'
    tail -n 80 /tmp/ros_gz-colcon-build.log
    printf '\n```\n'
  } > /tmp/ros_gz-ci-diagnostic.md
  echo "::error title=ros_gz build failure::${first_failure//$'\n'/' '}"
  exit $build_status
fi

# Tests. `colcon test` and `colcon test-result` are tracked separately so a
# failing test is distinguishable from a test runner failure.
printf '\n::group::colcon test\n'
colcon test --event-handlers console_direct+ 2>&1 | tee /tmp/ros_gz-colcon-test.log
test_status=${PIPESTATUS[0]}
printf '::endgroup::\n'
printf '\n::group::colcon test-result --verbose\n'
colcon test-result --verbose 2>&1 | tee /tmp/ros_gz-test-result.log
test_result_status=${PIPESTATUS[0]}
printf '::endgroup::\n'

if [ $test_status -ne 0 ] || [ $test_result_status -ne 0 ]; then
  first_failure=$(grep -m1 -E '(^|[[:space:]])(ERROR|FAILED|Failure|Errors|error:)|Failed[[:space:]]+<<<' /tmp/ros_gz-test-result.log /tmp/ros_gz-colcon-test.log || true)
  if [ -z "$first_failure" ]; then
    first_failure=$(tail -n 1 /tmp/ros_gz-test-result.log)
  fi
  {
    printf '### ros_gz CI diagnostic: test failure\n\n'
    printf 'colcon test: `%s`; test-result: `%s`\n\n' "$test_status" "$test_result_status"
    printf 'First matched failure:\n\n```text\n%s\n```\n\n' "$first_failure"
    printf 'Verbose test-result output:\n\n```text\n'
    tail -n 120 /tmp/ros_gz-test-result.log
    printf '\n```\n'
  } > /tmp/ros_gz-ci-diagnostic.md
  echo "::error title=ros_gz test failure::${first_failure//$'\n'/' '}"
  exit 1
fi
