#!/usr/bin/env bash
if [ ! -f /opt/konveyor/backup-bucket ]; then
    echo "backup bucket is not present"
    exit 1
fi
export AWS_DEFAULT_REGION=$(curl http://169.254.169.254/latest/meta-data/placement/region)
BACKUP_BUCKET=$(cat /opt/konveyor/backup-bucket)
mkdir -p "/tmp/backup/"

FILENAME_PREFIX=$(date +"%Y-%m-%dT%H%M%SZ")
KEYCLOAK_SECRET=$(kubectl get secret -n konveyor-tackle tackle-keycloak-postgresql -o json | jq '.data')
KEYCLOAK_DBNAME=$(echo $KEYCLOAK_SECRET | jq -r '."database-name"' | base64 -d)
KEYCLOAK_DBUSER=$(echo $KEYCLOAK_SECRET | jq -r '."database-user"' | base64 -d)
KEYCLOAK_DBPASS=$(echo $KEYCLOAK_SECRET | jq -r '."database-password"' | base64 -d)
KEYCLOAK_DBSERVICE=$(kubectl describe deployment -n konveyor-tackle tackle-keycloak-sso | grep DB_ADDR | awk '{print $2}')
KEYCLOAK_DBHOST="${KEYCLOAK_DBSERVICE}.konveyor-tackle.svc.cluster.local"
KEYCLOAK_POD_NAME=$(kubectl get po -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-keycloak-postgresql | grep postgresql | awk '{print $1}')

kubectl exec $KEYCLOAK_POD_NAME -n konveyor-tackle -- /bin/bash -c "/usr/bin/pg_dump --no-privileges --no-owner $KEYCLOAK_DBNAME" | cat | gzip > "/tmp/backup/${FILENAME_PREFIX}-keycloak.sql.gz"

filesize=$(stat -c%s "/tmp/backup/${FILENAME_PREFIX}-keycloak.sql.gz")
if (( filesize < 100 )); then
    echo "Keycloak DB is not ready yet"
    exit 1
fi
aws s3 cp "/tmp/backup/${FILENAME_PREFIX}-keycloak.sql.gz" "s3://${BACKUP_BUCKET}/keycloak/${FILENAME_PREFIX}.sql.gz"

PATHFINDER_SECRET=$(kubectl get secret -n konveyor-tackle tackle-pathfinder-postgresql -o json | jq '.data')
PATHFINDER_DBNAME=$(echo $PATHFINDER_SECRET | jq -r '."database-name"' | base64 -d)
PATHFINDER_DBUSER=$(echo $PATHFINDER_SECRET | jq -r '."database-user"' | base64 -d)
PATHFINDER_DBPASS=$(echo $PATHFINDER_SECRET | jq -r '."database-password"' | base64 -d)
PATHFINDER_DBHOST="tackle-pathfinder-postgresql.konveyor-tackle.svc.cluster.local"
PATHFINDER_POD_NAME=$(kubectl get po -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-pathfinder-postgresql | grep postgresql | awk '{print $1}')

kubectl exec $PATHFINDER_POD_NAME -n konveyor-tackle -- /bin/bash -c "/usr/bin/pg_dump --no-privileges --no-owner $PATHFINDER_DBNAME" | cat | gzip > "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz"
filesize=$(stat -c%s "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz")

if (( filesize < 100 )); then
    echo "Pathfinder DB is not ready yet"
    exit 1
fi

aws s3 cp "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz" "s3://${BACKUP_BUCKET}/pathfinder/${FILENAME_PREFIX}.sql.gz"

HUB_POD=$(kubectl get pods -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-hub --output=jsonpath={.items..metadata.name})

kubectl exec -ti $HUB_POD -n konveyor-tackle -- bash -c "rm -f /database/hub-bck.db && sqlite3 /database/hub.db \"VACUUM main INTO '/database/hub-bck.db';\" \".timeout 10000\""
kubectl exec -ti $HUB_POD -n konveyor-tackle -- bash -c "base64 -w0 /database/hub-bck.db" | tee /tmp/backup/tmp.base64 > /dev/null
base64 -d /tmp/backup/tmp.base64 > /tmp/backup/${FILENAME_PREFIX}-hub.db
rm -f /tmp/backup/tmp.base64


if [ -s /tmp/backup/${FILENAME_PREFIX}-hub.db ]; then
    echo "check ${FILENAME_PREFIX}-hub.db"
    BCKOK=$(sqlite3 /tmp/backup/${FILENAME_PREFIX}-hub.db "PRAGMA integrity_check")
    if [ "${BCKOK}" = "ok" ]; then
        echo "upload to s3"
        aws s3 cp "/tmp/backup/${FILENAME_PREFIX}-hub.db" "s3://${BACKUP_BUCKET}/hub/${FILENAME_PREFIX}.db"
    else
        echo "${FILENAME_PREFIX} failed to create backup of sqllite" >> /opt/konveyor/bck-sqlite.log
    fi
fi
