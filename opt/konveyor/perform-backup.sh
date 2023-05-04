#!/usr/bin/env bash
if [ ! -f /opt/konveyor/backup-bucket ]; then
    echo "backup bucket is not present"
    exit 1
fi

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres-backup
  namespace: konveyor-tackle
spec:
  containers:
  - name: pgbackup
    image: public.ecr.aws/docker/library/postgres:latest
    command: ["/bin/sleep", "infinity"]
EOF

kubectl wait --for=condition=ready -n konveyor-tackle pod postgres-backup

BACKUP_BUCKET=$(cat /opt/konveyor/backup-bucket)
mkdir -p "/tmp/backup/"

FILENAME_PREFIX=$(date +"%Y-%m-%dT%H%M%SZ")
KEYCLOAK_SECRET=$(kubectl get secret -n konveyor-tackle tackle-keycloak-postgresql -o json | jq '.data')
KEYCLOAK_DBNAME=$(echo $KEYCLOAK_SECRET | jq -r '."database-name"' | base64 -d)
KEYCLOAK_DBUSER=$(echo $KEYCLOAK_SECRET | jq -r '."database-user"' | base64 -d)
KEYCLOAK_DBPASS=$(echo $KEYCLOAK_SECRET | jq -r '."database-password"' | base64 -d)
KEYCLOAK_DBHOST="tackle-keycloak-postgresql.konveyor-tackle.svc.cluster.local"

kubectl exec postgres-backup -n konveyor-tackle -- /bin/bash -c "echo '${KEYCLOAK_DBHOST}:5432:${KEYCLOAK_DBNAME}:${KEYCLOAK_DBUSER}:${KEYCLOAK_DBPASS}' > /root/.pgpass && chmod 600 /root/.pgpass && /usr/bin/pg_dump -C -h $KEYCLOAK_DBHOST -U $KEYCLOAK_DBUSER $KEYCLOAK_DBNAME" | cat | gzip > "/tmp/backup/${FILENAME_PREFIX}-keycloak.sql.gz"

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

kubectl exec postgres-backup -n konveyor-tackle -- /bin/bash -c "echo '${PATHFINDER_DBHOST}:5432:${PATHFINDER_DBNAME}:${PATHFINDER_DBUSER}:${PATHFINDER_DBPASS}' > /root/.pgpass && chmod 600 /root/.pgpass && /usr/bin/pg_dump -C -h $PATHFINDER_DBHOST -U $PATHFINDER_DBUSER $PATHFINDER_DBNAME" | cat | gzip > "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz"
filesize=$(stat -c%s "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz")

if (( filesize < 100 )); then
    echo "Pathfinder DB is not ready yet"
    exit 1
fi

aws s3 cp "/tmp/backup/${FILENAME_PREFIX}-pathfinder.sql.gz" "s3://${BACKUP_BUCKET}/pathfinder/${FILENAME_PREFIX}.sql.gz"