#!/bin/bash
#
# This script can start and stop all DB instances of some OPS manager project
#

# Parameters
# URL to OPS Manager
url=http://loclahost:8080

# Login to OPS Manager
user=admin@ops.app

# API key for OPS Manager
apikey=923d8e84-6fde-4644-8cc1-0b50c693d1a6

# Project group id
group_id=5bd86224e28a44291f72f418


operation=unknown 

function check_status() {
  if [ $1 -ne 0 ]
  then
    printf "Operation was not completed. Error code: %d. Error message: %s\n" $1 "${2}" >&2
    exit 1
  fi
}

function exit_if_error() {
  if [ $1 -ne 0 ]
  then
    exit 1
  fi
}

function check_http_status() {
  local response="${1}"
  local body=$(echo $response | sed -e 's/HTTPSTATUS\:.*//g')
  local code=$(echo $response | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  if [ "$code" -ne 200 ]
  then
    printf "HTTP error %d:%s\n" $code "${body}" >&2
    exit 1
  fi
  echo $body
}

function exec_cmd() {
  response=$(curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" "${url}/api/public/v1.0/groups/${group_id}/automationConfig" --digest 2>&1) 
  check_status $? "${response}"
  body=$(check_http_status "${response}")
  exit_if_error $?

  body=$(echo ${body} | jq "(.processes[] | .disabled) = $1" 2>&1)
  check_status $? "${body}"

  response=$(echo ${body} | curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" -H "Content-Type: application/json" "${url}/api/public/v1.0/groups/${group_id}/automationConfig" --digest -i -X PUT --data @-) 2>&1
  check_status $? "${response}"
  body=$(check_http_status "${response}")
  exit_if_error $?

  for i in {1..6}
  do
    sleep 10s
    response=$(curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" "${url}/api/public/v1.0/groups/${group_id}/automationStatus/" --digest 2>&1)
    check_status $? "${response}"
    body=$(check_http_status "${response}")
    exit_if_error $?

    body=$(echo ${body} | jq '(.processes[] | .goalVersion) = .goalVersion | .processes[] | select(.goalVersion != .lastGoalVersionAchieved) | .hostname +":"+ .name'  2>&1)
    check_status $? "${body}"
    res=( $body )

    if [ ${#res[@]} -eq 0 ]
    then
      printf "Successfully completed\n"
      exit
    fi
  done
  printf "The following hosts are not in the goal state:\n"
  for v in ${res[@]}
  do
    printf "%s\n" $v
  done
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user=*)
      user="${1#*=}"
      ;;
    --apikey=*)
      apikey="${1#*=}"
      ;;
    --group_id=*)
      group_id="${1#*=}"
      ;;
    --oper=*)
      operation="${1#*=}"
      ;;
    --url=*)
      url="${1#*=}"
      ;;
    *)
      printf "Invalid argument: %s\n" ${1}
      exit 1
  esac
  shift
done

case $operation in
   start)
      printf "Startting everything for the group id %s\n" ${group_id}
      exec_cmd false
      ;;
    stop)
      printf "Stopping everything for the group id %s\n" ${group_id}
      exec_cmd true
      ;;
    unknown)
      printf '%s\n' '--oper=start/stop must be specified'
      ;;
    *)
      printf "Invalid operation: %s\n" ${operation}
      exit 1
esac
exit
