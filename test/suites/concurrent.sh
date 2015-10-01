test_concurrent() {
  ensure_import_testimage

  spawn_container() {
    set -e

    name=concurrent-${1}

    lxc launch testimage ${name}
    lxc list ${name} | grep RUNNING
    echo abc | lxc exec ${name} -- cat | grep abc
    lxc stop ${name} --force
    lxc delete ${name}
  }

  if [ -n "${TRAVIS_PULL_REQUEST:-}" ]; then
    return
  fi

  PIDS=""

  for id in $(seq 50); do
    spawn_container ${id} 2>&1 | tee ${LXD_DIR}/lxc-${id}.out &
    PIDS="${PIDS} $!"
  done

  for pid in ${PIDS}; do
    wait ${pid}
  done

  ! lxc list | grep -q concurrent
}
