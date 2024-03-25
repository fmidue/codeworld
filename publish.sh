#!/usr/bin/env zsh

USER=
GROUP=${USER}
SSH_USER=${USER}
SERVER=
JUMP_HOST=
PORT=22

KET=codeworld.keter
TARGET_FOLDER=/opt/codeworld

TIME=`date +"%Y-%m-%d-%H.%M.%S"`
if ! [[ -v REMOTE_DIR ]]
then
  REMOTE_DIR=${TARGET_FOLDER}${TIME}
fi


scp ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "$KET" "${USER}@${SERVER}:${REMOTE_DIR}"

ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "${USER}@${SERVER}" -C "mkdir -p ${REMOTE_DIR}/codeworld\
  && cd ${REMOTE_DIR}/codeworld\
  && tar xf ../$KET\
  && rm ${REMOTE_DIR}/$KET\
  && ln -sf ${REMOTE_DIR}/codeworld ${TARGET_FOLDER} \
  && tar czf ${REMOTE_DIR}/$KET -C ${REMOTE_DIR}/codeworld config/ codeworld-base/ web/ \
  && mv ${REMOTE_DIR}/$KET /opt/keter/incoming"