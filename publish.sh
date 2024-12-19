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

cp codeworld.tar codeworld-tmp.tar

tar -rf codeworld-tmp.tar config/keter.yaml extensions.yaml

gzip codeworld-tmp.tar

rm -f codeworld.keter
mv codeworld-tmp.tar.gz codeworld.keter


ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -p "${PORT}" "${SSH_USER}@${SERVER}" -C "mkdir -p ${REMOTE_DIR}"

scp ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" "$KET" "${SSH_USER}@${SERVER}:${REMOTE_DIR}/$KET"

ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -p "${PORT}" "${SSH_USER}@${SERVER}" -C "set -x trace && mkdir -p ${REMOTE_DIR}/codeworld\
  && cd ${REMOTE_DIR}/codeworld\
  && tar xf ../$KET\
  && rm ${REMOTE_DIR}/$KET\
  && rm -f ${TARGET_FOLDER}\
  && chown -R ${USER}:${GROUP} ${REMOTE_DIR}\
  && ln -sf ${REMOTE_DIR}/codeworld ${TARGET_FOLDER} \
  && tar czf ${REMOTE_DIR}/$KET -C ${REMOTE_DIR}/codeworld config/ codeworld-base/ web/ \
  && chown ${USER}:${GROUP} ${REMOTE_DIR}/${KET}\
  && mv ${REMOTE_DIR}/${KET} /opt/keter/incoming\
  && service keter restart"
