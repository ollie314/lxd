#!/bin/sh

create_vg() {
  vgname=${1}
  pvfile=${LOOP_IMG_DIR}/lvm-pv-${vgname}.img
  truncate -s 10G "${pvfile}"
  chattr +C "${pvfile}" >/dev/null 2>&1 || true
  pvloopdev=$(losetup -f)
  losetup "${pvloopdev}" "${pvfile}"

  pvcreate "${pvloopdev}"
  VGDEBUG=""
  if [ -n "${LXD_DEBUG:-}" ]; then
    VGDEBUG="-vv"
  fi
  vgcreate "${VGDEBUG}" "${vgname}" "${pvloopdev}"
  pvloopdevs_to_delete="${pvloopdevs_to_delete:-} ${pvloopdev}"
}

cleanup_vg_and_shutdown() {
  cleanup_vg "${VGNAME}" || true

  losetup -d "${pvloopdevs_to_delete}" || echo "Couldn't delete loop devices ${pvloopdevs_to_delete}"
  wipe "${LOOP_IMG_DIR}" || echo "Couldn't remove ${pvfile}"
  cleanup
}

cleanup_vg() {
  vgname=${1}

  if [ -n "${LXD_INSPECT_LVM:-}" ]; then
    # shellcheck disable=SC2086
    printf "To poke around, use:\n LXD_DIR=%s LXD_CONF=%s sudo -E %s/bin/lxc COMMAND\n" "${LXD5_DIR}" "${LXD_CONF}" ${GOPATH:-}
    echo "Pausing to inspect LVM state. Hit Enter to continue cleanup."
    read
  fi

  if [ -d "${LXD5_DIR}"/containers/testcontainer ]; then
    echo "unmounting testcontainer LV"
    umount "${LXD5_DIR}"/containers/testcontainer || echo "Couldn't unmount testcontainer, skipping"
  fi

  # -f removes any LVs in the VG
  vgremove -f "${vgname}" || echo "Couldn't remove ${vgname}, skipping"
}

die() {
  set +x
  echo ""
  echo "\033[1;31m###### Test Failed : ${1:-'unknown'}\033[0m"
  exit 1
}

test_lvm() {
  if ! which vgcreate >/dev/null; then
    echo "===> SKIPPING lvm backing: vgcreate not found"
    return
  fi

  if ! which thin_check >/dev/null; then
    echo "===> SKIPPING lvm backing: thin_check not found"
    return
  fi

  LOOP_IMG_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)

  VGNAME=$(uuidgen)
  create_vg "${VGNAME}"

  trap cleanup_vg_and_shutdown EXIT HUP INT TERM

  test_mixing_storage
  lvremove -f "${VGNAME}/LXDPool"

  test_lvm_withpool
  lvremove -f "${VGNAME}/LXDPool"

  lvcreate -l 100%FREE --poolmetadatasize 500M --thinpool "${VGNAME}/test_user_thinpool"
  test_lvm_withpool test_user_thinpool

  lvremove -f "${VGNAME}/test_user_thinpool"
  test_remote_launch_imports_lvm

  test_init_with_missing_vg
}


test_mixing_storage() {
  LXD5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD5_DIR}"
  spawn_lxd "${LXD5_DIR}"

  (
    set -e
    # shellcheck disable=SC2030
    LXD_DIR=${LXD5_DIR}
    ../scripts/lxd-images import busybox --alias testimage || die "couldn't import image"
    lxc launch testimage reg-container || die "couldn't launch regular container"
    lxc copy reg-container reg-container-sticks-around || die "Couldn't copy reg"
    lxc config set storage.lvm_vg_name "${VGNAME}" || die "error setting storage.lvm_vg_name config"
    lxc config show | grep "${VGNAME}" || die "test_vg not in config show output"
    lxc stop reg-container --force || die "couldn't stop reg-container"
    lxc start reg-container || die "couldn't start reg-container"
    lxc stop reg-container --force || die "couldn't stop reg-container"
    lxc delete reg-container || die "couldn't delete reg-container"
    lxc image delete testimage || die "couldn't delete regular image"

    ../scripts/lxd-images import busybox --alias testimage || die "couldn't import image"

    check_image_exists_in_pool testimage LXDPool

    lxc launch testimage lvm-container || die "couldn't launch lvm container"
    lxc copy reg-container-sticks-around lvm-from-reg || die "can't copy reg->lvm"
    lvs "${VGNAME}/lvm--from--reg" || die "snapshot LV lvm--from--reg couldn't be found"
    lxc snapshot reg-container-sticks-around regsnap || die "Couldn't snapshot"
    lvs "${VGNAME}/reg--container--sticks--around-regsnap" && die "we should NOT have a snap lv for a reg container"

    lxc config unset storage.lvm_vg_name && die "shouldn't be able to unset config with existing lv containers"
    lxc delete lvm-container || die "couldn't delete container"
    lxc image delete testimage || die "couldn't delete lvm-backed image"

    lxc delete lvm-from-reg || die "couldn't delete lvm-from-reg"
    lxc config unset storage.lvm_vg_name || die "should be able to unset config after delete all"

    exit 0
  )
  # shellcheck disable=SC2031
  LXD_DIR=${LXD_DIR}

  kill_lxd "${LXD5_DIR}"
}

check_image_exists_in_pool() {
  imagename=${1}
  poolname=${2}
  # get sha of image
  lxc image info "${imagename}" || die "Couldn't find ${imagename} in lxc image info"
  testimage_sha=$(lxc image info "${imagename}" | grep Fingerprint | cut -d' ' -f 2)

  imagelvname=${testimage_sha}

  lvs --noheadings -o lv_attr "${VGNAME}/${poolname}" | grep "^  t" || die "${poolname} not found or not a thin pool"

  lvs --noheadings -o lv_attr "${VGNAME}/${imagelvname}" | grep "^  V" || die "no lv named ${imagelvname} found or not a thin Vol."

  lvs --noheadings -o pool_lv "${VGNAME}/${imagelvname}" | grep "${poolname}" || die "new LV not member of ${poolname}"
  [ -L "${LXD_DIR}/images/${imagelvname}.lv" ] || die "image symlink doesn't exist"
}

do_image_import_subtest() {
  poolname=${1}
  ../scripts/lxd-images import busybox --alias testimage
  check_image_exists_in_pool testimage "${poolname}"
}

test_lvm_withpool() {
  poolname=${1:-}
  LXD5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD5_DIR}"
  spawn_lxd "${LXD5_DIR}"

  (
    set -e
    # shellcheck disable=SC2030
    LXD_DIR=${LXD5_DIR}
    lxc config set storage.lvm_vg_name "zambonirodeo" && die "Shouldn't be able to set nonexistent LVM VG"
    lxc config show | grep "storage.lvm_vg_name" && die "vg_name should not be set after invalid attempt"

    lxc config set storage.lvm_vg_name "${VGNAME}" || die "error setting storage.lvm_vg_name config"
    lxc config show | grep "${VGNAME}" || die "test_vg not in config show output"

    if [ -n "${poolname}" ]; then
      echo " --> Testing with user-supplied thin pool name '${poolname}'"
      lxc config set storage.lvm_thinpool_name "${poolname}" || die "error setting storage.lvm_thinpool_name config"
      lxc config show | grep "${poolname}" || die "thin pool name not in config show output."
      echo " --> only doing minimal image import subtest with user pool name"
      do_image_import_subtest "${poolname}"

      lxc config unset storage.lvm_vg_name && die "should not be allowed to unset without deleting"
      lxc image delete testimage

      # check that we can unset configs in this order
      lxc config unset storage.lvm_vg_name
      lxc config unset storage.lvm_thinpool_name

      return
    else
      echo " --> Testing with default thin pool name 'LXDPool'"
      poolname=LXDPool
    fi

    do_image_import_subtest "${poolname}"

    # launch a container using that image
    lxc init testimage test-container || die "Couldn't init test container"

    # check that we now have a new volume in the pool
    lvs --noheadings -o pool_lv "${VGNAME}/test--container" | grep "${poolname}" || die "LV for new container not found or not in ${poolname}"
    [ -L "${LXD_DIR}/containers/test-container.lv" ] || die "test-container lv symlink should exist!"
    mountpoint -q "${LXD_DIR}/containers/testcontainer" && die "LV for new container should not be mounted until container start"

    lxc start test-container || die "Couldn't start test-container"
    mountpoint -q "${LXD_DIR}/containers/test-container" || die "test-container LV is not mounted?"
    lxc list test-container | grep RUNNING || die "test-container doesn't seem to be running"

    lxc stop test-container --force || die "Couldn't stop test-container"
    mountpoint -q "${LXD_DIR}/containers/test-container" && die "LV for new container should be umounted after stop"

    lxc snapshot test-container chillbro || die "Couldn't snapshot"
    lvs "${VGNAME}/test--container-chillbro" || die "snapshot LV test--container-chillbro  couldn't be found"
    lxc start test-container
    lxc exec test-container -- touch /tmp/unchill
    lxc snapshot test-container unchillbro
    lxc restore test-container chillbro

    lxc exec test-container -- ls /tmp/unchill && die "Should not find unchill in chillbro"
    lxc stop test-container --force
    lxc restore test-container unchillbro
    lxc start test-container
    lxc exec test-container -- ls /tmp/unchill || die "should find unchill in unchillbro"

    lxc copy test-container test-container-copy
    lxc start test-container-copy
    lxc stop test-container --force
    lxc exec test-container-copy -- ls /tmp/unchill || die "should find unchill in copy of unchillbro"
    lxc stop test-container-copy --force

    lxc move test-container-copy test-cc
    lvs "${VGNAME}/test--container--copy" && die "test-container-copy should not exist"
    lvs "${VGNAME}/test--cc" || die "test--cc should exist"

    lxc move test-container/chillbro test-container/superchill
    lvs "${VGNAME}/test--container-superchill" || die "superchill should exist"
    lvs "${VGNAME}/test--container-chillbro" && die "chillbro should not exist"

    lxc publish test-container || die "Couldn't publish test-container"
    lxc publish test-container/unchillbro || die "Couldn't publish snapshot"

    # TODO busybox ignores SIGPWR, breaking restart:
    # check that 'shutdown' also unmounts:
    # lxc start test-container || die "Couldn't re-start test-container"
    # lxc stop test-container --timeout 1 || die "Couldn't shutdown test-container"
    # lxc list test-container | grep STOPPED || die "test-container is still running"
    # mountpoint -q ${LXD_DIR}/containers/test-container && die "LV for new container should be umounted after shutdown"

    lxc delete test-container || die "Couldn't delete test-container"
    lvs "${VGNAME}/test--container" && die "test-container LV is still there, should've been destroyed"
    [ -L "${LXD_DIR}/containers/test-container.lv" ] && die "test-container lv symlink should be deleted"
    lvs "${VGNAME}/test--container-chillbro" && die "chillbro is still there, should have been deleted"
    [ -L "${LXD_DIR}/snapshots/test-container/chillbro.lv" ] && die "chillbro snapshot lv symlink should be deleted"

    lxc image delete testimage || die "Couldn't delete testimage"
    lvs "${VGNAME}/${imagelvname}" && die "lv ${imagelvname} is still there, should be gone"
    [ -L "${LXD_DIR}/images/${imagelvname}.lv" ] && die "image symlink is still there, should be gone."
    exit 0
  )
  # shellcheck disable=SC2031
  LXD_DIR=${LXD_DIR}

  kill_lxd "${LXD5_DIR}"
}

test_remote_launch_imports_lvm() {
  LXD5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD5_DIR}"
  spawn_lxd "${LXD5_DIR}"
  LXD5_ADDR=$(cat "${LXD5_DIR}/lxd.addr")

  LXD6_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD6_DIR}"

  spawn_lxd "${LXD6_DIR}"

  (
    set -e
    # shellcheck disable=SC2030
    LXD_DIR=${LXD5_DIR}
    # import busybox as a regular file-backed image
    ../scripts/lxd-images import busybox --alias testimage

    LXD_DIR=${LXD6_DIR}

    lxc config set storage.lvm_vg_name "${VGNAME}" || die "couldn't set vg_name"
    lxc remote add testremote "${LXD5_ADDR}" --accept-certificate --password foo

    testimage_sha=$(lxc image info testremote:testimage | grep Fingerprint | cut -d' ' -f 2)
    lxc launch testremote:testimage remote-test || die "Couldn't launch from remote"

    lxc image show "${testimage_sha}" || die "Didn't import image from remote"
    lvs --noheadings -o lv_attr "${VGNAME}/${testimage_sha}" | grep "^  V" || die "no lv named ${testimage_sha} or not a thin Vol."

    lxc list | grep remote-test | grep RUNNING || die "remote-test is not running"
    lvs --noheadings -o pool_lv "${VGNAME}/remote--test" | grep LXDPool || die "LV for remote-test not found or not in LXDPool"
    lxc stop remote-test --force || die "Couldn't stop remote-test"
    lxc delete remote-test

    lvs "${VGNAME}/remote--test" && die "remote--test LV is still there, should have been removed."
    lxc image delete "${testimage_sha}"
    lvs "${VGNAME}/${testimage_sha}" && die "LV ${testimage_sha} is still there, should have been removed."
    exit 0
  )
  # shellcheck disable=SC2031
  LXD_DIR=${LXD_DIR}

  kill_lxd "${LXD5_DIR}"
  kill_lxd "${LXD6_DIR}"
}

test_init_with_missing_vg() {
  LXD5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${LXD5_DIR}"
  spawn_lxd "${LXD5_DIR}"

  VGNAME1=$(uuidgen)
  create_vg "${VGNAME1}"

  (
    set -e
    # shellcheck disable=SC2030
    LXD_DIR=${LXD5_DIR}
    lxc config set storage.lvm_vg_name "${VGNAME1}" || die "error setting storage.lvm_vg_name config"
    exit 0
  )
  # shellcheck disable=SC2031
  LXD_DIR=${LXD_DIR}

  kill -9 "$(cat "${LXD5_DIR}/lxd.pid")"
  cleanup_vg "${VGNAME1}"

  spawn_lxd "${LXD5_DIR}"

  (
    set -e
    # shellcheck disable=SC2030
    LXD_DIR=${LXD5_DIR}
    lxc config show | grep "${VGNAME1}" || die "should show config even if it is broken"
    lxc config unset storage.lvm_vg_name || die "should be able to un set config to un break"
    exit 0
  )
  # shellcheck disable=SC2031
  LXD_DIR=${LXD_DIR}

  kill_lxd "${LXD5_DIR}"
}
