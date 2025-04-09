#!/usr/bin/env bash

# This script is used to migrate from one cluster to another.
# It assumes that we are migrating from the same namespace.
#
# This script was tested using the following dependency versions
# GNU bash, version 5.2.37
# velero, version v1.15.2
# jq, version jq-1.7.1

set -e
: "${DEBUG:=false}"

if [ $DEBUG = "true" ]; then
	set -x
fi

: "${CLUSTER_NAME:=dev-library}"
: "${FROM_CLUSTER_ID:=0}"
: "${TO_CLUSTER_ID:=1}"
: "${NAMESPACE:=$1}"
: "${EXCLUDE_RESOURCES:='certificaterequests.cert-manager.io,orders.acme.cert-manager.io,certificates.cert-manager.io,apps.catalog.cattle.io,configauditreports.aquasecurity.github.io,exposedsecretreports.aquasecurity.github.io,sbomreports.aquasecurity.github.io,vulnerabilityreports.aquasecurity.github.io'}"
# If BACKUP_NAME is not given, a new backup will be generated.
: "${BACKUP_NAME:=}"

# Switch context to cluster and namespace we are migrating from.
kubectl config use ${CLUSTER_NAME}${FROM_CLUSTER_ID}-fqdn
kubectl get namespace ${NAMESPACE}
kubectl config set-context --current --namespace $NAMESPACE

# We will be relaxing the namespace privilages,
# but we want to keep the original value to reset it later.
echo
echo "Save the original pod security settings..."
ORIG_PRIVILAGES=$(kubectl get namespace $NAMESPACE -o jsonpath="{.metadata.labels.pod-security\.kubernetes\.io/enforce}")

# Process for creating a new backup of given NAMESPACE in the current context.
create_backup() {
	echo
	echo "Backing up $NAMESPACE from $CLUSTER_NAME-$FROM_CLUSTER_ID"
	BACKUP_CMD="velero backup create $NAMESPACE-$FROM_CLUSTER_ID-$(date +'%Y%m%d%S') \
	  --include-namespaces=$NAMESPACE \
	  --exclude-resources=$EXCLUDE_RESOURCES"

	export BACKUP_JSON=$($BACKUP_CMD --output=json | jq '.')


	if [ -z "$BACKUP_JSON" ]; then
	  echo 
	  echo "Backup creation failed!"
	  exit 1
	fi

	BACKUP_NAME=$(echo "$BACKUP_JSON" | jq -r '.metadata.name')
	eval "$BACKUP_CMD"

	echo
	echo "Getting status for backup $BACKUP_NAME"
	BACKUP_STATUS=$(velero describe backups $BACKUP_NAME --output json | jq -r '.phase')
	echo Backup status is: $BACKUP_STATUS

	while [ "$BACKUP_STATUS" != "Completed" ];
	do
	  sleep 5
	  BACKUP_JSON=$(velero describe backups $BACKUP_NAME --output json)
	  BACKUP_STATUS=$(echo $BACKUP_JSON | jq -r '.phase')
	  echo Backup status is: $BACKUP_STATUS
	done
}

# Only create a backup if we don't provide one.
if [ -z "${BACKUP_NAME:-}" ]; then
	create_backup
else
	# Make sure that given BACKUP_NAME exists.
	BACKUP_NAME=$(velero backup describe $BACKUP_NAME --output json | jq -r '.metadata.name')
fi

# Switch context to cluster we are migrating to.
kubectl config use ${CLUSTER_NAME}${TO_CLUSTER_ID}-fqdn
kubectl get namespace ${NAMESPACE}
kubectl config set-context --current --namespace $NAMESPACE

# Relax the namspace privileges so that velero can successfully backup persistent volumes.
kubectl label namespace $NAMESPACE pod-security.kubernetes.io/enforce=privileged --overwrite

# For some reason velero describe can see a backup before velero restore, or velero get.
while ! velero get backups | grep -q "$BACKUP_NAME"; do
  echo "Waiting for backup $BACKUP_NAME..."
  sleep 5 
done

echo
echo Restoring backup $BACKUP_NAME
RESTORE_CMD="velero create restore --from-backup=$BACKUP_NAME \
  --include-namespaces=$NAMESPACE \
  --exclude-resources=$EXCLUDE_RESOURCES"

export RESTORE_NAME=$($RESTORE_CMD --output=json | jq -r '.metadata.name')
eval "$RESTORE_CMD $RESTORE_NAME"

echo
echo Getting status for restoration $RESTORE_NAME
RESTORE_STATUS='InProgress'
while [ "$RESTORE_STATUS" != "Completed" ];
do
  echo Restoration status is: $RESTORE_STATUS
  sleep 5
  RESTORE_STATUS=$(velero restore describe $RESTORE_NAME \
	  | sed -r "s/\x1B\[[0-9;]*[mK]//g" \
	  | awk '/Phase:/ {print $2}')
done
echo Restoration status is: $RESTORE_STATUS

echo
echo "Resetting the pod security levels back to original settings."
kubectl label namespace $NAMESPACE  pod-security.kubernetes.io/enforce=$ORIG_PRIVILAGES --overwrite

SCHEDULE_NAME=$NAMESPACE-$TO_CLUSTER_ID
export GET_SCHEDULE=$(velero schedule get --output json | jq -r '.items[].metadata.name' | grep $SCHEDULE_NAME)

if [ "$GET_SCHEDULE" = "" ]; then
  velero create schedule $SCHEDULE_NAME --schedule="0 0 * * *" \
    --include-namespaces=$NAMESPACE --ttl 336h0m0s \
    --exclude-resources=$EXCLUDE_RESOURCES
fi
