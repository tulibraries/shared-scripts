#!/usr/bin/env bash
set -e
: "${DEBUG:=false}"

if [ $DEBUG = "true" ]; then
	set -x
fi

: "${CLUSTER_NAME:=prod-library}"
: "${FROM_CLUSTER_ID:=0}"
: "${TO_CLUSTER_ID:=1}"
: "${NAMESPACE:=$1}"
: "${EXCLUDE_RESOURCES:='certificaterequests.cert-manager.io,orders.acme.cert-manager.io,certificates.cert-manager.io,apps.catalog.cattle.io,configauditreports.aquasecurity.github.io,exposedsecretreports.aquasecurity.github.io,sbomreports.aquasecurity.github.io,vulnerabilityreports.aquasecurity.github.io'}"

# Switch context to cluster and namespace we are migrating from
kubectl config use ${CLUSTER_NAME}${FROM_CLUSTER_ID}-fqdn
kubectl get namespace ${NAMESPACE}
kubectl config set-context --current --namespace $NAMESPACE

# We will be relaxing the namespace privilages,
# but we want to keep original value so can reset it later.
echo
echo "Save the original pod security settings..."
ORIG_PRIVILAGES=$(kubectl get namespace $NAMESPACE -o jsonpath="{.metadata.labels.pod-security\.kubernetes\.io/enforce}")

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

# only create backup if we don't provide one.
if [ -z "${BACKUP_NAME:-}" ]; then
	create_backup
fi

kubectl config use ${CLUSTER_NAME}${TO_CLUSTER_ID}-fqdn
kubectl get namespace ${NAMESPACE}
kubectl config set-context --current --namespace $NAMESPACE

# Relax the namspace privileges so that velero can successfully backup persistent volumes.
kubectl label namespace $NAMESPACE pod-security.kubernetes.io/enforce=privileged --overwrite

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
echo "Reset the pod security levels back to original settings."
kubectl label namespace $NAMESPACE  pod-security.kubernetes.io/enforce=$ORIG_PRIVILAGES --overwrite

SCHEDULE_NAME=$NAMESPACE-$TO_CLUSTER_ID
export GET_SCHEDULE=$(velero schedule get --output json | jq -r '.items[].metadata.name' | grep $SCHEDULE_NAME)

if [ "$GET_SCHEDULE" = "" ]; then
  velero create schedule $SCHEDULE_NAME --schedule="0 0 * * *" \
    --include-namespaces=$NAMESPACE --ttl 336h0m0s \
    --exclude-resources=$EXCLUDE_RESOURCES
fi
