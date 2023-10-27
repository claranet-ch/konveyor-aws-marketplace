#!/bin/sh

if [ ! -f /opt/konveyor/backup-bucket ]; then
    echo "backup bucket is not present"
    exit 1
fi

BACKUP_BUCKET=$(cat /opt/konveyor/backup-bucket)
mkdir -p "/tmp/restore/"
export AWS_DEFAULT_REGION=$(curl http://169.254.169.254/latest/meta-data/placement/region)

KEYCLOAK_SECRET=$(kubectl get secret -n konveyor-tackle tackle-keycloak-postgresql -o json | jq '.data')
KEYCLOAK_DBNAME=$(echo $KEYCLOAK_SECRET | jq -r '."database-name"' | base64 -d)
KEYCLOAK_DBUSER=$(echo $KEYCLOAK_SECRET | jq -r '."database-user"' | base64 -d)
KEYCLOAK_DBPASS=$(echo $KEYCLOAK_SECRET | jq -r '."database-password"' | base64 -d)
KEYCLOAK_POD_NAME=$(kubectl get po -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-keycloak-postgresql | grep postgresql | awk '{print $1}')

existing_backup=$(aws s3 ls "s3://$BACKUP_BUCKET/keycloak/" | awk '{print $4}' | sort -r | head -n 1)
if [ "" != "$existing_backup" ]; then
    aws s3 cp "s3://$BACKUP_BUCKET/keycloak/$existing_backup" "/tmp/restore/keycloak-${existing_backup}"
    kubectl scale deploy tackle-keycloak-sso -n konveyor-tackle --replicas=0
    kubectl exec $KEYCLOAK_POD_NAME -i -n konveyor-tackle -- /bin/bash -c "/usr/bin/dropdb ${KEYCLOAK_DBNAME}; /usr/bin/createdb -O ${KEYCLOAK_DBUSER} ${KEYCLOAK_DBNAME}"
    zcat "/tmp/restore/keycloak-${existing_backup}" | kubectl exec $KEYCLOAK_POD_NAME -i -n konveyor-tackle -- /bin/bash -c "/usr/bin/psql -U ${KEYCLOAK_DBUSER} ${KEYCLOAK_DBNAME}"
    rm -f "/tmp/restore/keycloak-${existing_backup}"
    kubectl scale deploy tackle-keycloak-sso -n konveyor-tackle --replicas=1
fi

PATHFINDER_SECRET=$(kubectl get secret -n konveyor-tackle tackle-pathfinder-postgresql -o json | jq '.data')
PATHFINDER_DBNAME=$(echo $PATHFINDER_SECRET | jq -r '."database-name"' | base64 -d)
PATHFINDER_DBUSER=$(echo $PATHFINDER_SECRET | jq -r '."database-user"' | base64 -d)
PATHFINDER_DBPASS=$(echo $PATHFINDER_SECRET | jq -r '."database-password"' | base64 -d)
PATHFINDER_POD_NAME=$(kubectl get po -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-pathfinder-postgresql | grep postgresql | awk '{print $1}')

existing_backup=$(aws s3 ls "s3://$BACKUP_BUCKET/pathfinder/" | awk '{print $4}' | sort -r | head -n 1)
if [ "" != "$existing_backup" ]; then
    aws s3 cp "s3://$BACKUP_BUCKET/pathfinder/$existing_backup" "/tmp/restore/pathfinder-${existing_backup}"
    kubectl scale deploy tackle-pathfinder -n konveyor-tackle --replicas=0
    kubectl exec $PATHFINDER_POD_NAME -i -n konveyor-tackle -- /bin/bash -c "/usr/bin/dropdb ${PATHFINDER_DBNAME}; /usr/bin/createdb -O ${PATHFINDER_DBUSER} ${PATHFINDER_DBNAME}"
    zcat "/tmp/restore/pathfinder-${existing_backup}" | kubectl exec $PATHFINDER_POD_NAME -i -n konveyor-tackle -- /bin/bash -c "/usr/bin/psql -U ${PATHFINDER_DBUSER} ${PATHFINDER_DBNAME}"
    rm -f "/tmp/restore/pathfinder-${existing_backup}"
    kubectl scale deploy tackle-pathfinder -n konveyor-tackle --replicas=1
fi

## wait for keycloak to restart

kubectl wait \
  --namespace konveyor-tackle \
  --for=condition=Available \
  --timeout=600s \
  deployments.apps tackle-keycloak-sso

# prepare Keycloak user
if [ -f /opt/konveyor/backup-user ] && [ -f /opt/konveyor/keycloak-admin ]; then
    backup_user_arn=$(cat /opt/konveyor/backup-user)
    backup_secret_value=$(aws secretsmanager get-secret-value --secret-id "$backup_user_arn" | jq -r ".SecretString")
    backup_username=$(echo ${backup_secret_value} | jq -r ".username")
    backup_password=$(echo ${backup_secret_value} | jq -r ".password")

    keycloak_admin_arn=$(cat /opt/konveyor/keycloak-admin)
    keycloak_secret_value=$(aws secretsmanager get-secret-value --secret-id "$keycloak_admin_arn" | jq -r ".SecretString")
    keycloak_password=$(echo ${keycloak_secret_value} | jq -r ".password")
    domain=$(cat /opt/konveyor/domain)
    if [ "null" = "$keycloak_password" ]; then
      # first startup detected. We can copy the Keycloak admin password from the k8s secret
      keycloak_password=$(kubectl get secret -n konveyor-tackle tackle-keycloak-sso -o json | jq -r '.data' | jq -r '.["admin-password"]' | base64 -d)
      aws secretsmanager put-secret-value --secret-id "$keycloak_admin_arn" --secret-string "{\"username\":\"admin\", \"password\": \"${keycloak_password}\"}"
    else
      kubectl create secret generic tackle-keycloak-sso -n konveyor-tackle --from-literal="admin-username=admin" --from-literal="admin-password=${keycloak_password}" --dry-run=client -o yaml | kubectl apply -f -
    fi

    access_token=$(curl -X POST --location "https://$domain/auth/realms/master/protocol/openid-connect/token" \
                           -H "Content-Type: application/x-www-form-urlencoded" \
                           -d "username=admin&password=$keycloak_password&grant_type=password&client_id=admin-cli" | jq -r ".access_token")

    tackle_backup_user_id=$(curl -X GET --location "https://$domain/auth/admin/realms/tackle/users?username=$backup_username" \
                                      -H "Authorization: Bearer ${access_token}" | jq -r ".[0].id")


    if [ "null" = "$tackle_backup_user_id" ]; then
      # create dedicated user for export / import
      curl -X POST --location "https://$domain/auth/admin/realms/tackle/users" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${access_token}" \
          -d "{
                \"username\": \"${backup_username}\",
                \"enabled\": true,
                \"credentials\": [
                  {
                    \"type\": \"password\",
                    \"value\": \"${backup_password}\",
                    \"temporary\": false
                  }
                ]
              }"

      # get admin role
      tackle_admin_role_json=$(curl -X GET --location "https://$domain/auth/admin/realms/tackle/roles?search=tackle-admin" \
                                   -H "Authorization: Bearer ${access_token}" | jq -r ".[0]")
      tackle_admin_role_id=$(echo ${tackle_admin_role_json} | jq -r ".id" )
      tackle_admin_role_container=$(echo ${tackle_admin_role_json} | jq -r ".containerId" )
      tackle_backup_user_id=$(curl -X GET --location "https://$domain/auth/admin/realms/tackle/users?username=$backup_username" \
                                        -H "Authorization: Bearer ${access_token}" | jq -r ".[0].id")


      curl -X POST --location "https://$domain/auth/admin/realms/tackle/users/${tackle_backup_user_id}/role-mappings/realm" \
          -H "Authorization: Bearer ${access_token}" \
          -H "Content-Type: application/json" \
          -d "[
                {
                  \"id\":\"${tackle_admin_role_id}\",
                  \"name\":\"tackle-admin\",
                  \"composite\":false,
                  \"clientRole\":false,
                  \"containerId\":\"${tackle_admin_role_container}\"
                }
              ]"
    fi
fi

# restore Konveyor Hub database
existing_backup=$(aws s3 ls "s3://$BACKUP_BUCKET/hub/" | awk '{print $4}' | sort -r | head -n 1)
if [ "" != "$existing_backup" ]; then
    aws s3 cp "s3://$BACKUP_BUCKET/hub/$existing_backup" "/tmp/restore/hub-restore.db"

    # get the hub pod
    HUB_POD=$(kubectl get pods -n konveyor-tackle --selector=app.kubernetes.io/name=tackle-hub --output=jsonpath={.items..metadata.name})
    
    # then, we shut down tackle-hub temporarily
    kubectl scale deploy tackle-hub -n konveyor-tackle --replicas=0
    sleep 10

    # then, we launch our job to swap sqlite DB
    kubectl apply -f /opt/konveyor/descriptors/hub-db-swap.yaml
    # wait for the job to be complete
    kubectl wait --for=condition=complete -n konveyor-tackle job/hub-db-swap
    # restart tackle-hub
    kubectl scale deploy tackle-hub -n konveyor-tackle --replicas=1
    kubectl wait \
      --namespace konveyor-tackle \
      --for=condition=Available \
      --timeout=600s \
      deployments.apps tackle-hub

    # tackle hub doesn't have (yet) a readiness probe, so we have to try and wait until it's ready
    retries=30
    until [ $retries = 0 ]; do
      echo "checking tackle hub readiness..."
      ret_code=$(curl -o /dev/null -s -w "%{http_code}\n" "https://$domain/hub/applications")
      if [ "$ret_code" = "302" ]; then
        echo "tackle hub is ready!"
        break;
      else
        echo "tackle hub is NOT ready yet ($ret_code), waiting 15 seconds"
      fi
      sleep 15
      retries=$((retries - 1))
    done
fi
