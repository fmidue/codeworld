#!/usr/bin/env zsh

USER=niklas
GROUP=${USER}
SSH_USER=${USER}
SERVER=192.168.178.68
JUMP_HOST=
PORT=22

KET=codeworld.keter
REMOTE_DIR="$(ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"} -p "${PORT}" "${USER}@${SERVER}" -C mktemp -d)"

scp ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "$KET" "${USER}@${SERVER}:${REMOTE_DIR}"

ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "${USER}@${SERVER}" -C "mkdir -p ${REMOTE_DIR}/codeworld\
  && cd ${REMOTE_DIR}/codeworld\
  && tar xf ../$KET\
  && rm ${REMOTE_DIR}/$KET\
  && ln -sf ${REMOTE_DIR}/codeworld /opt/codeworld \
  && tar czf ${REMOTE_DIR}/$KET -C ${REMOTE_DIR}/codeworld config/ codeworld-base/ web/ \
  && mv ${REMOTE_DIR}/$KET /opt/keter/incoming"