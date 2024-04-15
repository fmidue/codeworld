#!/usr/bin/env zsh

USER=
GROUP=${USER}
SSH_USER=${USER}
SERVER=
JUMP_HOST=
PORT=22

KET=codeworld.keter
TARGET_FOLDER=/opt/codeworld

LC_ALL=C

TIME=`date +"%Y-%m-%d-%H.%M.%S"`
if ! [[ -v REMOTE_DIR ]]
then
  REMOTE_DIR=${TARGET_FOLDER}${TIME}
fi

ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -p "${PORT}" "${USER}@${SERVER}" -C "mkdir -p ${REMOTE_DIR}"

scp ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "$KET" "${USER}@${SERVER}:${REMOTE_DIR}/$KET"

ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -p "${PORT}" "${USER}@${SERVER}" -C "mkdir -p ${REMOTE_DIR}/codeworld\
  && cd ${REMOTE_DIR}/codeworld\
  && tar xf ../$KET\
  && rm ${REMOTE_DIR}/$KET\
  && rm -f ${TARGET_FOLDER}\
  && ln -sf ${REMOTE_DIR}/codeworld ${TARGET_FOLDER} \
  && tar czf ${REMOTE_DIR}/$KET -C ${REMOTE_DIR}/codeworld config/ codeworld-base/ web/ \
  && mv ${REMOTE_DIR}/$KET /opt/keter/incoming"
