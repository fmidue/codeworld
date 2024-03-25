# #!/usr/bin/env zsh
# source env

USER=niklas
GROUP=${USER}
SSH_USER=${USER}
SERVER=192.168.178.68
JUMP_HOST=
PORT=22
FOLDER=$(dirname ${ROOT})/
#TARGET=
REMOTE_FILE=/opt/codeworld/codeworld.keter

LC_ALL=C
TIME=`date +"%Y-%m-%d-%H.%M.%S"`
if ! [[ -v TARGET ]]
then
  TARGET=${FOLDER}${TIME}
fi



scp ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"}\
  -P "${PORT}" codeworld.keter "${USER}@${SERVER}:${REMOTE_FILE}"


# PROGRESS=$(rsync --version | sed -n "1s/^.*version 3.[1-9].*$/--info=progress2/g;1p")
# rsync -a ${PROGRESS} --rsh="ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+\"${JUMP_HOST}\"} -p ${PORT}" ${PWD}/root/ ${SSH_USER}@${SERVER}:${TARGET}/ \
#     && ssh ${JUMP_HOST:+-J} ${JUMP_HOST:+"${JUMP_HOST}"} -p ${PORT} ${SSH_USER}@${SERVER} "chown -R ${USER}:${GROUP} ${TARGET}\
#  && rm ${ROOT}\
#  && ln -s ${FOLDER}${TIME} ${ROOT}"