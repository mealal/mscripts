#!/bin/bash
#
# This script deploys a replica set to OPS Manager
# example ./deploy_rs.sh --hosts=amz-play-0:27020,amz-play-1:27021,amz-play-2:27022 --replicaSet=rs_new --dbpath="/db"
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

# Defailt MongoDB port
port=27017

# Default replica set name
replica_set_name=rs0

# Default data folder path
dbpath="/data"


allhosts=notset # set by default
hosts=notset
ports=()

function exit_if_error() {
  if [ $1 -ne 0 ]
  then
    exit 1
  fi
}

function check_status() {
  if [ $1 -ne 0 ]
  then
    printf "Operation was not completed. Error code: %d. Error message: %s\n" $1 "${2}" >&2
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
    --url=*)
      url="${1#*=}"
      ;;
    --replicaSet=*)
      replica_set_name="${1#*=}"
      ;;
    --dbpath=*)
      dbpath="${1#*=}"
      ;;
    --hosts=*)
      hosts="${1#*=}"
      ;;
    --allhosts)
      allhosts="Y"
      ;;
    --port=*)
      port="${1#*=}"
      ;;
    *)
      printf "Invalid argument: %s\n" ${1}
      exit 1
  esac
  shift
done

if [ "$allhosts" = "notset" ] && [ "$hosts" = "notset" ]
then
  printf "%s\n" "--hosts=... or --allhosts parameters must be used"
  exit 1
fi  

if [ "$allhosts" != "notset" ] && [ "$hosts" != "notset" ]
then
  printf "%s\n" "--hosts=... and --allhosts parameters cannot be used together"
  exit 1
fi 

if [ "$allhosts" = "Y" ] 
then
  printf "Discovering all automated hosts...\n"
  response=$(curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" "${url}/api/public/v1.0/groups/${group_id}/agents/AUTOMATION/" --digest 2>&1)
  check_status $? "${response}"
  body=$(check_http_status "${response}")
  exit_if_error $?

  body=$(echo ${body} | jq -r '.results[] | select(.typeName=="AUTOMATION") | .hostname' 2>&1)
  check_status $? "${body}"

  hosts=( ${body} )
  for host in "${hosts[@]}"
  do
    ports+=($port)
  done
else
  temp1=$hosts
  hosts=()
  IFS=',' read -ra temp <<< "$temp1" 
  for t in ${temp[@]}
  do
    IFS=':' read -ra temp2 <<< "$t"
    hosts+=(${temp2[0]})
    if [ -z ${temp2[1]} ]
    then 
      ports+=($port)
    else
      ports+=(${temp2[1]})
    fi
  done
fi

printf "Receiving current group configuration for the group id %s...\n" ${group_id}
response=$(curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" "${url}/api/public/v1.0/groups/${group_id}/automationConfig" --digest 2>&1)
check_status $? "${response}"
config=$(check_http_status "${response}")
exit_if_error $?

version=$(echo ${config} | jq -r '.mongoDbVersions | last | .name' 2>&1)
check_status $? "${version}"
printf "Latest available version: %s\n" ${version}

cnt=$(echo ${config} | jq -r '.monitoringVersions | length' 2>&1) 
check_status $? "${cnt}"
if [ "$cnt" -eq 0 ]
then
  printf "Adding new monitoring agent to host %s\n" ${hosts[0]}
  config=$(echo ${config} | jq '.monitoringVersions=[{"hostname":"'${hosts[0]}'", "logPath": "/var/log/mongodb-mms-automation/monitoring-agent.log", "logRotate": {"sizeThresholdMB": 1000, "timeThresholdHrs": 24}}]' 2>&1)
  check_status $? "${config}"
fi

config=$(echo ${config} | jq '.replicaSets[.replicaSets | length] |= .+ {"_id":"'$replica_set_name'", "members": [], "protocolVersion" : 1}'  2>&1)
check_status $? "${config}"

printf "\nThe follwoing configuration is going to be deployed for the replica set %s:\n" $replica_set_name
j=0
for host in "${hosts[@]}"
do
  port=${ports[$j]}
  printf "%s_%d on %s:%d\n" $replica_set_name $j $host $port
  config=$(echo ${config} |  jq '.processes[.processes | length] |= .+ {
        "version": "'$version'",
        "name": "'$replica_set_name'_'$j'",
        "hostname": "'$host'",
        "logRotate": {
            "sizeThresholdMB": 1000,
            "timeThresholdHrs": 24
        },
        "authSchemaVersion": 5,
        "featureCompatibilityVersion": "'$(echo $version| cut -c1-3)'",
        "processType": "mongod",
        "args2_6": {
            "net": {
                "port": '$port'
            },
            "storage": {
                "dbPath": "'$dbpath'"
            },
            "systemLog": {
                "path": "'$dbpath'/mongodb.log",
                "destination": "file"
            },
            "replication": {
                "replSetName": "'$replica_set_name'"
            }
        }
    }' 2>&1)
  check_status $? "${config}"

  config=$(echo ${config} |  jq '(.replicaSets[] | select(._id=="'$replica_set_name'") | .members[.members | length]) |= .+ {"_id":"'$j'", 
                "host": "'$replica_set_name'_'$j'",
                "priority": 1,
                "votes": 1,
                "slaveDelay": 0,
                "hidden": false,
                "arbiterOnly": false}' 2>&1)
  check_status $? "${config}"
  
  let "j++"
done

printf "\nDeploying the replica set...\n"
response=$(echo ${config} | curl -s -S --write-out "HTTPSTATUS:%{http_code}" -u "${user}:${apikey}" -H "Content-Type: application/json" "${url}/api/public/v1.0/groups/${group_id}/automationConfig" --digest -i -X PUT --data @- 2>&1)
check_status $? "${response}"
body=$(check_http_status "${response}")
exit_if_error $?

for i in {1..30}
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
